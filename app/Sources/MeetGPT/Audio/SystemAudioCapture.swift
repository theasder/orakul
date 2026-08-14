import AVFoundation
import Foundation
import os
import ScreenCaptureKit

/// Captures audio from the entire system using ScreenCaptureKit.
/// Requires macOS 13+ and the user granting Screen Recording permission.
/// We subscribe only to the audio stream — no video frames are decoded.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "meetgpt.systemaudio.output")
    private var onBuffer: BufferHandler?
    /// Кого позвать, если macOS оборвала поток на середине записи.
    ///
    /// Раньше здесь не было ничего: делегат писал строку в лог и возвращался.
    /// Для этого продукта это худший из возможных отказов — запись
    /// продолжается, индикатор горит, микрофон пишется, а половина разговора не
    /// пишется вовсе. Узнать об этом можно было, только открыв расшифровку
    /// после звонка, когда переписывать уже нечего.
    ///
    /// Поток обрывается не только от сбоя: разрешение можно отозвать в
    /// «Системных настройках» прямо во время звонка, дисплей — отключить.
    private var onStopped: (@Sendable (Error) -> Void)?
    // Capture-layer diagnostics — only touched on outputQueue (serial).
    private var diagCount = 0
    private var diagMaxRMS: CGFloat = 0
    private var copyFailures = 0
    var sourceLayoutLogged = false

    func start(onBuffer: @escaping BufferHandler,
               onStopped: (@Sendable (Error) -> Void)? = nil) async throws {
        self.onBuffer = onBuffer
        self.onStopped = onStopped
        // Fresh diagnostics per session (no buffers can be in flight yet).
        diagCount = 0
        diagMaxRMS = 0
        copyFailures = 0
        sourceLayoutLogged = false

        let shareable = try await SCShareableContent.excludingDesktopWindows(false,
                                                                             onScreenWindowsOnly: true)
        guard let display = shareable.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Не нашёл экрана, с которого писать звук. Такое бывает, если все дисплеи отключены."])
        }

        // Display-scoped by design: a meeting can play through ANY app (Zoom,
        // Teams, a browser tab, a messenger), so we capture the display's audio
        // rather than a single app — our own playback is dropped via the config's
        // excludesCurrentProcessAudio. (A future refinement could scope to the
        // CallDetector-detected app, with a whole-display fallback.)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = Self.makeStreamConfiguration()

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// The minimal, audio-only capture surface (M8b — narrow the capture under
    /// the App Sandbox): audio on, our own playback excluded, and video kept to
    /// the 2×2 minimum with no cursor since we never add a screen output and
    /// decode no frames. Pure + property-readable so the narrowing is testable.
    static func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // no feedback from our own audio
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by SCStream, but we only add an .audio output — no
        // frames are ever delivered. Keep it to the 2×2 minimum, cursor off.
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        return config
    }

    /// Что делать, когда поток оборвался. Отдельно от делегата, потому что
    /// делегату нужен настоящий `SCStream`, а его в тесте не создать без
    /// разрешения на запись экрана. Здесь же — сама связь: раньше делегат
    /// писал в лог и возвращался, и именно этой строки не хватало.
    ///
    /// Своя остановка сюда не доходит: `stop()` снимает `onStopped` до того,
    /// как ScreenCaptureKit позовёт делегата.
    func handleStreamStopped(_ error: Error) {
        Log.audio.error("capture stopped: \(String(describing: error))")
        // Сообщить наверх, а не только в лог: лог читает разработчик после
        // жалобы, а знать нужно тому, кто прямо сейчас на звонке и думает, что
        // пишутся оба голоса.
        onStopped?(error)
    }

#if DEBUG
    /// Поставить обработчик обрыва без похода в ScreenCaptureKit. Только для
    /// тестов: `start()` требует разрешения на запись экрана, которого в
    /// прогоне нет, а проверить нужно именно проводку.
    func setStoppedHandlerForTesting(_ handler: @escaping @Sendable (Error) -> Void) {
        onStopped = handler
    }
#endif

    func stop() async {
        // Снимается ПЕРВЫМ и до всякой проверки на поток: ScreenCaptureKit
        // зовёт делегата и на обычном завершении, и без этой строки каждая
        // нормальная остановка записи приходила бы наверх как «связь
        // оборвалась». Предупреждение, которое показывают после каждого
        // звонка, перестают читать за день.
        //
        // Раньше строка стояла после `guard let stream`, то есть снятие
        // зависело от того, дошёл ли `start()` до создания потока, — и в
        // тесте её нельзя было проверить вовсе.
        onStopped = nil
        guard let stream else {
            onBuffer = nil
            return
        }
        try? await stream.stopCapture()
        self.stream = nil
        self.onBuffer = nil
    }
}

@available(macOS 13.0, *)
extension SystemAudioCapture: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let onBuffer = self.onBuffer,
              let pcm = pcmBuffer(from: sampleBuffer) else { return }
        trackDiagnostics(pcm)
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(error)
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }

        var mutableASBD = asbd
        guard let avFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frames) else {
            return nil
        }

        // Set frameLength BEFORE the copy. AVAudioPCMBuffer derives each ABL
        // buffer's mDataByteSize from frameLength, which is 0 on a fresh
        // allocation — so the copy saw a zero-capacity destination and failed
        // with -12731 (RequiredParameterMissing), then the ignored failure
        // shipped the zero-filled buffer downstream as fabricated silence
        // (the entire system-audio track read -120 dBFS). Sizing it first is
        // the fix; the ABL fallback below stays as a belt for odd formats.
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        if status == noErr {
            return buffer
        }

        // The copy's status used to be IGNORED — on failure the zero-filled
        // allocation shipped downstream as fabricated silence and the whole
        // system-audio track went quiet with nothing in the logs (live test
        // measured -120 dBFS across an entire session). Log it and try the
        // retained-ABL path, which tolerates non-contiguous sample buffers.
        copyFailures += 1
        if copyFailures == 1 || copyFailures % 1_000 == 0 {
            Log.audio.error("sysaudio: PCM copy failed (status \(status), #\(self.copyFailures)) — using ABL fallback")
        }
        return ablFallbackBuffer(from: sampleBuffer, format: avFormat, frames: frames)
    }

    /// Fallback conversion via the audio-buffer-list accessor (handles buffers
    /// the direct PCM copy rejects). Returns nil — never silence — on failure.
    private func ablFallbackBuffer(from sampleBuffer: CMSampleBuffer,
                                   format: AVAudioFormat,
                                   frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var copiedBytes = 0
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                logSourceLayoutOnce(list, dstCount: dst.count)
                // A layout mismatch must fail LOUDLY (nil), not ship the
                // zero-filled allocation as fake silence — that was the
                // original bug in the primary path.
                guard list.count == dst.count else { return }
                for i in 0..<list.count {
                    guard let src = list[i].mData, let dstData = dst[i].mData else { continue }
                    let bytes = min(list[i].mDataByteSize, dst[i].mDataByteSize)
                    memcpy(dstData, src, Int(bytes))
                    copiedBytes += Int(bytes)
                }
            }
        } catch {
            if copyFailures % 1_000 == 1 {
                Log.audio.error("sysaudio: ABL fallback threw: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        guard copiedBytes > 0 else { return nil }
        buffer.frameLength = frames
        return buffer
    }

    /// One persisted line describing what SCK ACTUALLY hands us — source
    /// channel layout, byte sizes, and the raw peak sample. Distinguishes
    /// "macOS delivers zeros" (permission problem) from "we misread the bytes"
    /// (format problem) without a debugger.
    private func logSourceLayoutOnce(_ list: UnsafeMutableAudioBufferListPointer, dstCount: Int) {
        guard !sourceLayoutLogged else { return }
        sourceLayoutLogged = true
        var peak: Float = 0
        var bytes: [UInt32] = []
        for i in 0..<list.count {
            bytes.append(list[i].mDataByteSize)
            if let data = list[i].mData {
                let count = Int(list[i].mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for j in stride(from: 0, to: count, by: 7) {
                    peak = max(peak, abs(samples[j]))
                }
            }
        }
        Log.audio.notice("sysaudio source: \(list.count) ABL buffers (dst \(dstCount)), bytes \(String(describing: bytes), privacy: .public), raw peak \(peak, privacy: .public)")
    }

    /// Persisted ground truth at the CAPTURE layer (before chunking): what SCK
    /// actually delivers. One line at start, then every ~30 s of buffers.
    private func trackDiagnostics(_ buffer: AVAudioPCMBuffer) {
        diagCount += 1
        diagMaxRMS = max(diagMaxRMS, AudioLevel.rms(buffer))
        guard diagCount == 1 || diagCount % 1_500 == 0 else { return }
        let dbfs = diagMaxRMS > 0 ? Int(20 * log10(Double(diagMaxRMS))) : -120
        Log.audio.notice("sysaudio: \(self.diagCount) buffers, peak \(dbfs)dBFS, copyFail=\(self.copyFailures), \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount)ch interleaved=\(buffer.format.isInterleaved)")
        diagMaxRMS = 0
    }
}
