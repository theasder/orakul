import Foundation
import Testing
@testable import MeetGPT

/// The managed-Whisper safety net: a plan cap / outage / sign-out mid-call
/// degrades the SESSION to on-device instead of erroring every six seconds.
@Suite("Server transcription fallback")
struct ServerFallbackTranscriptionTests {
    /// Local stand-in that counts calls and returns marked text.
    private final class CountingTranscriber: TranscriptionService {
        var calls = 0
        func transcribe(wav: Data) async throws -> String {
            try await transcribe(wav: wav, streamID: nil)
        }
        func transcribe(wav: Data, streamID: String?) async throws -> String {
            calls += 1
            return "fallback-text"
        }
        func prewarm() async throws {}
        func shutdown() async {}
        func cancelPendingTranscriptions(beforeGeneration: Int) async {}
        func takePerformanceRecommendation() async -> TranscriptionPerformanceRecommendation? { nil }
    }

    private func capError(_ code: Int) -> NSError {
        NSError(domain: "OrakulWhisper", code: code,
                userInfo: [NSLocalizedDescriptionKey: "err \(code)"])
    }

    @Test("classifies which failures degrade the session")
    func classification() {
        // Cap, sign-out, server trouble, config, network → degrade.
        #expect(ServerFallbackTranscription.shouldFallback(on: capError(429)))
        #expect(ServerFallbackTranscription.shouldFallback(on: capError(401)))
        #expect(ServerFallbackTranscription.shouldFallback(on: capError(503)))
        #expect(ServerFallbackTranscription.shouldFallback(on: capError(500)))
        #expect(ServerFallbackTranscription.shouldFallback(on: capError(-1)))
        #expect(ServerFallbackTranscription.shouldFallback(
            on: URLError(.notConnectedToInternet)))
        // Client-side input errors rethrow — on-device wouldn't fare better.
        #expect(!ServerFallbackTranscription.shouldFallback(on: capError(400)))
        #expect(!ServerFallbackTranscription.shouldFallback(on: capError(413)))
    }

    @Test("причина отказа названа своими словами: ограничение, вход, недоступность")
    func reasons() {
        #expect(ServerFallbackTranscription.reason(for: capError(429)).contains("ограничению"))
        #expect(ServerFallbackTranscription.reason(for: capError(401)).contains("Вход не подтверждён"))
        #expect(ServerFallbackTranscription.reason(for: capError(503)).contains("недоступен"))
    }

    @Test("degraded state is per-instance and sticky, and notifies exactly once")
    func stickyDegrade() async throws {
        // Primary that always 429s (a Free plan out of credits).
        let primary = ServerWhisperTranscription(
            language: "en",
            tokenProvider: { nil })   // no session → its own 401 error
        let fallback = CountingTranscriber()
        let wrapper = ServerFallbackTranscription(primary: primary, fallback: fallback)
        var notices: [String] = []
        wrapper.onFallback = { notices.append($0) }

        // First chunk: primary fails (dev build has no backend → 503, and a
        // missing session would 401 the same way) → degrade → fallback.
        let first = try await wrapper.transcribe(wav: Data([0x52]))
        #expect(first == "fallback-text")
        #expect(wrapper.isDegraded)
        // Second chunk: straight to fallback, no second notice.
        _ = try await wrapper.transcribe(wav: Data([0x52]))
        #expect(fallback.calls == 2)
        #expect(notices.count == 1)
        #expect(notices[0].contains("на вашем компьютере"))
    }
}
