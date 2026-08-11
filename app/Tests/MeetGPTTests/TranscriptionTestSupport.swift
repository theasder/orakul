import AVFoundation
import Foundation
@testable import MeetGPT

// MARK: - Audio fixtures

enum AudioFixtures {
    /// A non-interleaved float PCM buffer of `frames` at `sampleRate`, each
    /// channel filled by `sample(index)`.
    static func floatBuffer(sampleRate: Double,
                            frames: AVAudioFrameCount,
                            channels: AVAudioChannelCount = 1,
                            sample: (_ index: Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: channels,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { ptr[i] = sample(i) }
        }
        return buffer
    }

    /// A voiced sine buffer (amplitude well above the VAD threshold).
    static func voicedBuffer(sampleRate: Double,
                             seconds: Double,
                             channels: AVAudioChannelCount = 1,
                             frequency: Float = 440,
                             amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let sr = Float(sampleRate)
        return floatBuffer(sampleRate: sampleRate, frames: frames, channels: channels) { i in
            amplitude * sinf(2 * .pi * frequency * Float(i) / sr)
        }
    }

    static func silentBuffer(sampleRate: Double,
                             seconds: Double,
                             channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        return floatBuffer(sampleRate: sampleRate, frames: frames, channels: channels) { _ in 0 }
    }

    /// The shape Apple voice processing actually emits on macOS: multi-channel
    /// deinterleaved where ONLY channel 0 carries the processed voice and the
    /// rest are near-silent echo-reference/aux channels (forums #710151).
    static func voiceProcessedShapedBuffer(sampleRate: Double,
                                           seconds: Double,
                                           channels: AVAudioChannelCount,
                                           amplitude: Float = 0.05) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let sr = Float(sampleRate)
        // >2 channels need an explicit layout — the channel-count convenience
        // initializer returns nil. Discrete-in-order matches VP's aux streams.
        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   interleaved: false,
                                   channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                ptr[i] = ch == 0 ? amplitude * sinf(2 * .pi * 440 * Float(i) / sr) : 0
            }
        }
        return buffer
    }

    /// Voiced Int16 samples for VAD / WAV tests.
    static func voicedInt16(count: Int,
                            frequency: Float = 440,
                            sampleRate: Float = 16_000,
                            amplitude: Float = 0.3) -> [Int16] {
        (0..<count).map { i in
            let v = amplitude * sinf(2 * .pi * frequency * Float(i) / sampleRate)
            return Int16(max(-1, min(1, v)) * 32_767)
        }
    }

    static func silentInt16(count: Int) -> [Int16] { [Int16](repeating: 0, count: count) }

    /// A small, valid voiced WAV chunk.
    static func wav(seconds: Double = 0.5) -> Data {
        WAVEncoder.encode(samples: voicedInt16(count: Int(16_000 * seconds)), sampleRate: 16_000)
    }
}

// MARK: - Mock transcription engine

/// Deterministic stand-in for the real (WhisperKit / API) engine, so the
/// pipeline can be exercised without downloading a model or hitting the network.
actor MockTranscriptionService: TranscriptionService {
    var nextText: String
    var transcribeError: Error?
    var prewarmError: Error?
    var pauseTranscribe = false

    private(set) var prewarmCount = 0
    private(set) var transcribeCount = 0
    private(set) var receivedWAVs: [Data] = []
    private var gate: CheckedContinuation<Void, Never>?

    init(text: String = "hello world", transcribeError: Error? = nil, prewarmError: Error? = nil) {
        self.nextText = text
        self.transcribeError = transcribeError
        self.prewarmError = prewarmError
    }

    func prewarm() async throws {
        prewarmCount += 1
        if let prewarmError { throw prewarmError }
    }

    func transcribe(wav: Data) async throws -> String {
        transcribeCount += 1
        receivedWAVs.append(wav)
        if pauseTranscribe { await withCheckedContinuation { gate = $0 } }
        if let transcribeError { throw transcribeError }
        return nextText
    }

    // Test controls
    func setText(_ text: String) { nextText = text }
    func setTranscribeError(_ error: Error?) { transcribeError = error }
    func setPrewarmError(_ error: Error?) { prewarmError = error }
    func setPause(_ paused: Bool) { pauseTranscribe = paused }
    func releaseGate() { gate?.resume(); gate = nil }
}

// MARK: - Async polling helper

/// Poll `condition` (on the main actor) until it's true or the timeout elapses.
/// The code under test finishes on unstructured Tasks, so tests wait on the
/// observable result rather than a fixed sleep.
func waitUntil(timeoutMs: Int = 3000, _ condition: @escaping @MainActor @Sendable () -> Bool) async {
    var waited = 0
    while waited < timeoutMs {
        if await MainActor.run(body: condition) { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
        waited += 10
    }
}

/// A labelled error for tests simulating an engine/model failure.
func testError(_ message: String, code: Int = 1) -> NSError {
    NSError(domain: "MeetGPTTests", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}
