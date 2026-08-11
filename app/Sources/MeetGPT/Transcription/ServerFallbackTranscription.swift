import Foundation

/// Cruxwing Whisper with a safety net: chunks are served by the managed
/// large-v3 gateway until the plan cap / an outage / a sign-out bites, then
/// the session DEGRADES TO ON-DEVICE instead of erroring every six seconds
/// (a Free plan's credits can run out mid-meeting — the transcript must keep
/// flowing). Degradation is per-session: the next recording tries the server
/// again. `onFallback` fires exactly once with a user-facing reason.
final class ServerFallbackTranscription: TranscriptionService {
    private let primary: ServerWhisperTranscription
    private let fallback: TranscriptionService
    private let lock = NSLock()
    private var degraded = false
    /// Set by AppState after init (the factory can't reach the UI).
    var onFallback: ((String) -> Void)?

    init(primary: ServerWhisperTranscription, fallback: TranscriptionService) {
        self.primary = primary
        self.fallback = fallback
    }

    var isDegraded: Bool {
        lock.lock(); defer { lock.unlock() }
        return degraded
    }

    func languageSnapshot() -> String { primary.languageSnapshot() }

    func transcribe(wav: Data) async throws -> String {
        try await transcribe(wav: wav, streamID: nil)
    }

    func transcribe(wav: Data, streamID: String?) async throws -> String {
        if isDegraded {
            return try await fallback.transcribe(wav: wav, streamID: streamID)
        }
        do {
            return try await primary.transcribe(wav: wav)
        } catch {
            guard Self.shouldFallback(on: error) else { throw error }
            let firstDegrade: Bool = {
                lock.lock(); defer { lock.unlock() }
                let first = !degraded
                degraded = true
                return first
            }()
            if firstDegrade { onFallback?(Self.reason(for: error)) }
            return try await fallback.transcribe(wav: wav, streamID: streamID)
        }
    }

    /// Cap (429), auth (401 — signed out mid-call), server trouble (>=500 /
    /// 503-not-configured / bad URL), or network loss → degrade. Client-side
    /// input errors (4xx like 400/413) rethrow: on-device wouldn't fare better.
    static func shouldFallback(on error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        guard ns.domain == "CruxwingWhisper" else { return false }
        return ns.code == 429 || ns.code == 401 || ns.code >= 500 || ns.code == -1
    }

    static func reason(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "CruxwingWhisper", ns.code == 429 {
            return "Plan limit reached — switched to on-device transcription for this session."
        }
        if ns.domain == "CruxwingWhisper", ns.code == 401 {
            return "Signed out — switched to on-device transcription for this session."
        }
        return "Cruxwing Whisper is unreachable — switched to on-device transcription for this session."
    }

    // MARK: forwarded lifecycle (the heavy resources live in the fallback)

    func prewarm() async throws {
        // Deliberately NOT prewarming the on-device fallback here: that can
        // trigger a multi-GB model download most sessions never need. It warms
        // lazily on first degraded chunk.
        try await primary.prewarm()
    }

    func shutdown() async {
        await primary.shutdown()
        await fallback.shutdown()
    }

    func cancelPendingTranscriptions(beforeGeneration generation: Int) async {
        await primary.cancelPendingTranscriptions(beforeGeneration: generation)
        await fallback.cancelPendingTranscriptions(beforeGeneration: generation)
    }

    func takePerformanceRecommendation() async -> TranscriptionPerformanceRecommendation? {
        await fallback.takePerformanceRecommendation()
    }
}
