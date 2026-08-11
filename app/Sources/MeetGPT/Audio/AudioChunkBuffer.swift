import AVFoundation
import Foundation

/// Accumulates incoming PCM buffers, converts to mono 16 kHz Int16 PCM,
/// and emits fixed-duration chunks for transcription.
final class AudioChunkBuffer {
    typealias ChunkHandler = (_ wavData: Data, _ durationSeconds: Double) -> Void

    private let targetSampleRate: Double = 16_000
    private let chunkSeconds: Double
    /// How much of the previous window each new one repeats.
    ///
    /// Hard cuts split an utterance across two windows, and each half decodes
    /// without the other's context. A measured run turned "The vendor has not
    /// confirmed the delivery date for the hardware" into that fragment plus
    /// the orphans "Kubernetes," and "and", which the short-fragment filter
    /// then deleted as hallucinations — 124 spoken words arrived as 53.
    ///
    /// Overlapping means no word sits alone at a seam. The repeat is removed
    /// downstream by ChunkStitcher, which cuts INSIDE the line rather than
    /// dropping it, because the second window carries new speech as well.
    ///
    /// 1.5s is chosen to exceed a spoken word comfortably (a slow word is
    /// ~0.6s) without materially raising decode cost: at a 6s window it is a
    /// 25% overlap, so a minute of audio decodes 75s of samples.
    private let overlapSeconds: Double
    /// How far back the window may move to land on a pause. Zero cuts on the
    /// clock exactly, as before.
    private let boundarySlackSeconds: Double
    private var onChunk: ChunkHandler
    /// Diagnostic label ("mic"/"system") for the persisted heartbeat log.
    private let label: String
    /// Skip silent chunks (TRANSCRIPTION_VAD, default on).
    private let vadEnabled = Config.vadEnabled
    /// VAD gate — lowered for voice-processed sources (see VoiceActivity).
    /// Set right after capture starts; only read at chunk emission, so the
    /// first-6-seconds window before it lands is harmless.
    var vadThreshold: Float = VoiceActivity.defaultThreshold
    private var sampleAccumulator: [Int16] = []
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let lock = NSLock()

    // Heartbeat counters — the audio path used to fail in total silence
    // ("listening, no transcript" with nothing in the log store). Everything
    // here logs at .notice/.error, which macOS PERSISTS (unlike .info/.debug),
    // so field diagnosis works from a plain `log show`.
    private var buffersIn = 0
    private var chunksEmitted = 0
    private var chunksGated = 0
    private var convertFailures = 0
    /// Loudest chunk RMS (dBFS) seen so far — when everything gets VAD-gated,
    /// this says whether the source is truly silent or just under the gate.
    private var maxChunkDBFS: Double = -120
    private var lastHeartbeat = Date()
    private static let heartbeatInterval: TimeInterval = 30

    /// Optional tap receiving every converted mono-16k batch — used to record
    /// the full session for diarization without re-running the conversion.
    private var sampleHandler: (([Int16]) -> Void)?

    var onSamples: (([Int16]) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return sampleHandler
        }
        set {
            lock.lock(); defer { lock.unlock() }
            sampleHandler = newValue
        }
    }

    init(chunkSeconds: Double,
         label: String = "audio",
         overlapSeconds: Double = Config.transcriptionChunkOverlapSeconds,
         boundarySlackSeconds: Double = Config.transcriptionBoundarySlackSeconds,
         onChunk: @escaping ChunkHandler) {
        self.chunkSeconds = chunkSeconds
        self.label = label
        // Never let the overlap reach the window length: at parity the buffer
        // would advance by zero samples and emit the same audio forever.
        self.overlapSeconds = max(0, min(overlapSeconds, chunkSeconds / 2))
        // Never let the search shorten a window past half, or the effective
        // window length becomes unpredictable.
        self.boundarySlackSeconds = max(0, min(boundarySlackSeconds, chunkSeconds / 3))
        self.onChunk = onChunk
    }

    /// Atomically redirect an already-running capture to another transcription
    /// backend. The capture callbacks retain this buffer for the whole call, so
    /// replacing the `AudioChunkBuffer` stored by AppState would not affect the
    /// live tap. During an engine handoff the partial accumulator can be emitted
    /// once to the previous handler before the new handler becomes visible.
    /// That preserves pre-switch speech without replaying it through the new
    /// backend or mixing it with future samples.
    func reconfigure(onChunk: @escaping ChunkHandler,
                     onSamples: (([Int16]) -> Void)?,
                     discardBufferedSamples: Bool = true,
                     flushBufferedSamplesToPreviousHandler: Bool = false) {
        var trailingChunk: (handler: ChunkHandler, wav: Data, duration: Double)?
        lock.lock()
        if flushBufferedSamplesToPreviousHandler, !sampleAccumulator.isEmpty {
            let samples = sampleAccumulator
            sampleAccumulator.removeAll(keepingCapacity: true)
            let duration = Double(samples.count) / targetSampleRate
            trackLevel(of: samples)
            if !vadEnabled || VoiceActivity.isVoiced(samples, threshold: vadThreshold) {
                chunksEmitted += 1
                trailingChunk = (
                    self.onChunk,
                    WAVEncoder.encode(samples: samples, sampleRate: Int(targetSampleRate)),
                    duration)
            } else {
                chunksGated += 1
            }
        }
        self.onChunk = onChunk
        sampleHandler = onSamples
        if discardBufferedSamples && !flushBufferedSamplesToPreviousHandler {
            sampleAccumulator.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        // Invoke outside the buffer lock. The old handler registers its route
        // lease synchronously, while future capture is already guaranteed to
        // observe only the new handler.
        if let trailingChunk {
            trailingChunk.handler(trailingChunk.wav, trailingChunk.duration)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }

        buffersIn += 1
        heartbeatIfDue()

        guard let mono16k = convertToMono16k(buffer) else { return }
        let frameLength = Int(mono16k.frameLength)
        guard let channelData = mono16k.int16ChannelData?[0], frameLength > 0 else { return }

        let pointer = UnsafeBufferPointer(start: channelData, count: frameLength)
        sampleAccumulator.append(contentsOf: pointer)
        if let sampleHandler { sampleHandler(Array(pointer)) }

        let samplesPerChunk = Int(targetSampleRate * chunkSeconds)
        let overlapSamples = min(Int(targetSampleRate * overlapSeconds), samplesPerChunk - 1)
        while sampleAccumulator.count >= samplesPerChunk {
            // Prefer to end the window at a PAUSE rather than on the clock.
            //
            // A fixed boundary cuts wherever it lands, which for a fast talker
            // is mid-word; that word then decodes as half a word twice. Looking
            // back a little for the quietest moment adapts to how the person is
            // actually speaking — someone pausing often gives a clean seam near
            // the target, someone racing gives none and the clock still applies.
            //
            // Searched BACKWARD only, so the window never waits for more audio
            // and first-caption latency is unchanged.
            let cut = Self.quietestBoundary(in: sampleAccumulator,
                                            target: samplesPerChunk,
                                            slack: Int(targetSampleRate * boundarySlackSeconds),
                                            vadThreshold: vadThreshold)
            let slice = Array(sampleAccumulator.prefix(cut))
            let advance = max(1, cut - overlapSamples)
            sampleAccumulator.removeFirst(advance)
            trackLevel(of: slice)
            // VAD gate: silent chunks never reach the transcription engine.
            // (The onSamples diarization tap above already saw every sample.)
            guard !vadEnabled || VoiceActivity.isVoiced(slice, threshold: vadThreshold) else {
                chunksGated += 1
                continue
            }
            chunksEmitted += 1
            let wav = WAVEncoder.encode(samples: slice, sampleRate: Int(targetSampleRate))
            onChunk(wav, chunkSeconds)
        }
    }

    /// Index at which to end a window: the quietest short frame within `slack`
    /// samples before `target`, or `target` when nothing is quieter.
    ///
    /// Pure and static so the choice can be tested without an audio session.
    static func quietestBoundary(in samples: [Int16], target: Int, slack: Int,
                                 vadThreshold: Float = VoiceActivity.defaultThreshold) -> Int {
        guard slack > 0, target <= samples.count else { return min(target, samples.count) }
        // Must be at least VoiceActivity.frameSize. A shorter slice trips the
        // `count >= frameSize` guard inside isVoiced, which returns TRUE for a
        // short non-empty buffer — so every frame read as speech, bestIndex
        // never moved, and this search silently returned the clock boundary on
        // every call. It was masked because the shipped slack is 0, which skips
        // the search entirely.
        let frame = VoiceActivity.frameSize
        let earliest = max(frame, target - slack)
        guard earliest < target else { return target }

        // A pause is defined exactly as the rest of the app defines it — below
        // this source's VAD gate. An absolute constant was wrong twice over:
        // taking the quietest frame unconditionally shortened EVERY window even
        // when nobody paused, and a fixed -40 dBFS bar called voice-processed
        // speech silence, since VP output runs 10-30 dB quieter than raw.
        var bestIndex = target
        var index = earliest
        while index <= target {
            let frameSamples = Array(samples[(index - frame)..<index])
            // Latest qualifying pause wins, keeping the window as long as
            // possible while still ending on silence.
            if !VoiceActivity.isVoiced(frameSamples, threshold: vadThreshold) {
                bestIndex = index
            }
            index += frame
        }
        return bestIndex
    }

    private func trackLevel(of slice: [Int16]) {
        guard !slice.isEmpty else { return }
        var energy: Double = 0
        for sample in slice {
            let v = Double(sample) / 32_768.0
            energy += v * v
        }
        let rms = (energy / Double(slice.count)).squareRoot()
        let dbfs = rms > 0 ? 20 * log10(rms) : -120
        maxChunkDBFS = max(maxChunkDBFS, dbfs)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        Log.audio.notice("chunker[\(self.label, privacy: .public)] final: in=\(self.buffersIn) emitted=\(self.chunksEmitted) vadGated=\(self.chunksGated) convertFail=\(self.convertFailures) maxChunk=\(Int(self.maxChunkDBFS))dBFS")
        guard !sampleAccumulator.isEmpty else { return }
        let duration = Double(sampleAccumulator.count) / targetSampleRate
        let samples = sampleAccumulator
        sampleAccumulator.removeAll(keepingCapacity: false)
        guard !vadEnabled || VoiceActivity.isVoiced(samples, threshold: vadThreshold) else { return }
        let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(targetSampleRate))
        onChunk(wav, duration)
    }

    private func heartbeatIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = now
        Log.audio.notice("chunker[\(self.label, privacy: .public)] in=\(self.buffersIn) emitted=\(self.chunksEmitted) vadGated=\(self.chunksGated) convertFail=\(self.convertFailures) gate=\(self.vadThreshold, privacy: .public) maxChunk=\(Int(self.maxChunkDBFS))dBFS")
    }

    private func convertToMono16k(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Apple voice processing silently inflates the mic to 3/7/9-channel
        // deinterleaved output where only channel 0 carries the processed
        // voice — the rest are near-silent echo-reference/aux channels
        // (Apple forums #710151, undocumented). Letting AVAudioConverter
        // downmix them dilutes real speech by 10–19 dB, which then dies at
        // the VAD gate. Anything beyond stereo: take channel 0 only.
        // True stereo (2ch) still downmixes both channels as before.
        let input = buffer.format.channelCount > 2 ? extractChannelZero(buffer) ?? buffer : buffer
        let inFormat = input.format

        if sourceFormat != inFormat {
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: targetSampleRate,
                                                   channels: 1,
                                                   interleaved: true),
                  let fresh = AVAudioConverter(from: inFormat, to: targetFormat) else {
                // Do NOT cache the format on failure — caching it here made a
                // one-off converter failure permanent (every later buffer saw
                // sourceFormat == inFormat, skipped the rebuild, and hit a nil
                // converter: 100% audio drop for the session, fully silent).
                convertFailures += 1
                Log.audio.error("chunker[\(self.label, privacy: .public)] converter unavailable for \(inFormat, privacy: .public)")
                return nil
            }
            sourceFormat = inFormat
            converter = fresh
        }

        guard let converter,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: true) else { return nil }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error {
            convertFailures += 1
            if convertFailures == 1 || convertFailures % 100 == 0 {
                Log.audio.error("chunker[\(self.label, privacy: .public)] convert failed (#\(self.convertFailures)): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
        return out
    }

    /// Copy channel 0 of a multi-channel Float32 buffer into a fresh mono
    /// buffer of the same sample rate (pre-resample, so the converter only
    /// handles rate + sample-format from here).
    private func extractChannelZero(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buffer.format
        guard src.commonFormat == .pcmFormatFloat32,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: src.sampleRate,
                                             channels: 1,
                                             interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                          frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return nil }

        let frames = Int(buffer.frameLength)
        if src.isInterleaved, let data = buffer.floatChannelData?[0] {
            let stride = Int(src.channelCount)
            for i in 0..<frames { dst[i] = data[i * stride] }
        } else if let ch0 = buffer.floatChannelData?[0] {
            dst.update(from: ch0, count: frames)
        } else {
            return nil
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}

/// Minimal PCM-16 WAV container writer.
enum WAVEncoder {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1))                         // PCM
        data.append(uint16LE(channels))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(dataSize))

        samples.withUnsafeBufferPointer { ptr in
            data.append(Data(buffer: ptr))
        }
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
}
