import Foundation

enum TranscriptionPerformanceRecommendation: Equatable, Sendable {
    /// Safe automatic adjustment: remains fully on-device and takes effect on
    /// the next recording so a model download never interrupts a meeting.
    case lighterLocalModel(current: String, recommended: String)
    /// Same downgrade, different trigger: the machine reports sustained
    /// thermal pressure (ProcessInfo.thermalState) even though inference is
    /// keeping up — a fast chip can hold realtime while cooking the chassis.
    case coolerLocalModel(current: String, recommended: String)
    /// Privacy-changing fallback: the UI must ask before selecting cloud audio.
    case offerDeepgram
}

protocol TranscriptionService: AnyObject {
    /// Transcribe a WAV chunk (mono 16 kHz PCM-16).
    /// Returns the recognized text, or empty string if nothing was heard.
    func transcribe(wav: Data) async throws -> String

    /// Live-source variant. Services that do not need per-source state use the
    /// default implementation; local Whisper uses it to keep language detection
    /// stable independently for the mic and system tracks.
    func transcribe(wav: Data, streamID: String?) async throws -> String

    /// Optionally pre-load (and, for the local engine, download) the model so
    /// the first audio chunk isn't blocked on an unbounded, silent setup.
    /// Cloud/streaming engines have nothing to warm — the default is a no-op.
    /// Throws if the model can't be prepared (e.g. the on-device download fails).
    func prewarm() async throws

    /// Release heavyweight model resources when the next recording selects a
    /// different engine/model.
    func shutdown() async

    /// Reject queued work from recording generations older than this value.
    /// The active decode may finish, but its caller will discard the result.
    func cancelPendingTranscriptions(beforeGeneration: Int) async

    /// One-shot load recommendation derived from sustained inference timing.
    func takePerformanceRecommendation() async -> TranscriptionPerformanceRecommendation?

}

extension TranscriptionService {
    func transcribe(wav: Data, streamID: String?) async throws -> String {
        try await transcribe(wav: wav)
    }
    func prewarm() async throws {}
    func shutdown() async {}
    func cancelPendingTranscriptions(beforeGeneration: Int) async {}
    func takePerformanceRecommendation() async -> TranscriptionPerformanceRecommendation? { nil }
}
