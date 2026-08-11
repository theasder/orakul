import AVFoundation
import Foundation

/// Push-to-talk dictation for the ask composer: hold the mic, say the question,
/// get it as text in the field.
///
/// Deliberately its own capture rather than a tap on the meeting recorder.
/// `MicrophoneCapture` configures the input node for a whole session, and a
/// dictation that reached into a live recording could restart the engine
/// mid-call — losing meeting audio to save a few keystrokes. When a recording is
/// running, dictation refuses instead. That is a real limit and the UI states it
/// rather than silently doing nothing.
@MainActor
final class PromptDictation: ObservableObject {

    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    /// Below this a press is a misclick, not speech — transcribing it wastes a
    /// call and returns noise.
    private static let minimumDuration: TimeInterval = 0.4
    /// Ceiling on one dictation. A composer prompt is a sentence or two; a mic
    /// left open by accident should not bill a ten-minute transcription.
    private static let maximumDuration: TimeInterval = 120

    @Published private(set) var state: State = .idle
    /// Live input level, so the button can show that it is actually hearing
    /// something. A dictation UI with no feedback is indistinguishable from a
    /// broken microphone.
    @Published private(set) var level: Float = 0

    var isListening: Bool { state == .listening }

    private let capture = MicrophoneCapture()
    private let transcriber: TranscriptionService
    private var samples: [Int16] = []
    private var startedAt: Date?
    private var converter: AVAudioConverter?
    private var autoStop: Task<Void, Never>?

    init(transcriber: TranscriptionService) {
        self.transcriber = transcriber
    }

    /// Begin capturing. Throws when the microphone is unavailable so the caller
    /// can surface a real reason rather than a button that does nothing.
    func start() throws {
        guard state != .listening else { return }
        samples.removeAll(keepingCapacity: true)
        startedAt = Date()
        state = .listening

        try capture.start { [weak self] buffer in
            guard let self else { return }
            let mono = PromptDictation.convertToMono16k(buffer)
            guard !mono.isEmpty else { return }
            Task { @MainActor in self.absorb(mono) }
        }

        autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await self?.stopAndTranscribe()
        }
    }

    /// Stop capturing and return the recognized text, or nil when there was
    /// nothing worth sending. Never throws: a failed dictation must leave the
    /// user typing, not handling an error.
    @discardableResult
    func stopAndTranscribe() async -> String? {
        autoStop?.cancel()
        autoStop = nil
        guard state == .listening else { return nil }
        capture.stop()
        level = 0

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        startedAt = nil

        guard duration >= Self.minimumDuration, !captured.isEmpty else {
            state = .idle
            return nil
        }

        state = .transcribing
        let wav = WAVEncoder.encode(samples: captured, sampleRate: 16_000)
        do {
            let text = try await transcriber.transcribe(wav: wav)
            state = .idle
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Abandon a dictation without transcribing it (the user changed their mind).
    func cancel() {
        autoStop?.cancel()
        autoStop = nil
        guard state == .listening else { return }
        capture.stop()
        samples.removeAll(keepingCapacity: false)
        startedAt = nil
        level = 0
        state = .idle
    }

    func clearError() {
        if case .failed = state { state = .idle }
    }

    // MARK: - Capture

    private func absorb(_ mono: [Int16]) {
        samples.append(contentsOf: mono)
        // Peak of the newest slice — cheap, and enough for a level meter.
        let peak = mono.reduce(Int16(0)) { max($0, abs($1 == Int16.min ? Int16.max : $1)) }
        level = Float(peak) / Float(Int16.max)
    }

    /// Down-mix and resample to the mono 16 kHz PCM-16 every engine expects.
    /// Static and self-contained so the conversion is testable and cannot pick
    /// up state from a previous dictation.
    private nonisolated static func convertToMono16k(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: buffer.format, to: target) else {
            return []
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
