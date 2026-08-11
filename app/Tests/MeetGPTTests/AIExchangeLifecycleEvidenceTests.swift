import AppKit
import Foundation
import Testing
@testable import MeetGPT

private final class LifecycleSupersessionGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private let emitBeforeWait: Bool
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    var firstIsWaiting: Bool {
        lock.withLock { firstContinuation != nil }
    }

    init(emitBeforeWait: Bool = false) {
        self.emitBeforeWait = emitBeforeWait
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        if system == FollowUpService.systemPrompt { return "[]" }
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call == 1 {
            if emitBeforeWait { onDelta("obsolete partial") }
            await withCheckedContinuation { continuation in
                let releaseNow = lock.withLock { () -> Bool in
                    if releaseRequested { return true }
                    firstContinuation = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
            // Simulate a provider that ignores cancellation and returns late.
            if !emitBeforeWait { onDelta("obsolete partial") }
            return "obsolete partial"
        }
        onDelta("Finance approved the Falcon rollout guard.")
        return "Finance approved the Falcon rollout guard."
    }

    func releaseFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            releaseRequested = true
            defer { firstContinuation = nil }
            return firstContinuation
        }
        continuation?.resume()
    }
}

@MainActor
@Suite("Assistant exchange lifecycle evidence")
struct AIExchangeLifecycleEvidenceTests {
    private func prompt(_ id: String, _ text: String) -> QuickPrompt {
        .custom(id: id, icon: "✨", title: id, prompt: text)
    }

    private func settle(_ state: AppState) async {
        await state.aiTask?.value
        for _ in 0..<500 where state.aiStreaming {
            await Task.yield()
        }
    }

    @Test("superseded blank run is evidence, not a completed dialog answer")
    func supersededAttemptHasStableBoundaryAndTerminalStatus() async throws {
        let gateway = LifecycleSupersessionGateway()
        let state = AppState(llm: gateway)
        state.transcript = [TranscriptEntry(
            source: .system, text: "Finance approved the Falcon rollout guard.")]

        state.runPrompt(prompt("custom-first", "First model-backed request"))
        for _ in 0..<45_000 where !gateway.firstIsWaiting {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(gateway.firstIsWaiting)
        let firstID = try #require(state.aiResponseID)
        let firstPromptedAt = try #require(state.aiResponseStartedAt)
        #expect(state.aiResponseStatus == .inProgress)

        state.runPrompt(prompt("custom-second", "Second model-backed request"))
        let secondID = try #require(state.aiResponseID)
        let secondPromptedAt = try #require(state.aiResponseStartedAt)
        await settle(state)

        #expect(firstID != secondID)
        #expect(secondPromptedAt >= firstPromptedAt)
        let superseded = try #require(state.aiExchangeEvidence.first {
            $0.id == firstID
        })
        #expect(superseded.status == .superseded)
        #expect(superseded.completedAt == secondPromptedAt)
        #expect(superseded.promptID == "custom-first")
        #expect(!superseded.status.isSuccessful)
        #expect(state.aiHistory.isEmpty) // blank cancellation stays out of UI

        #expect(state.aiResponseID == secondID)
        #expect(state.aiResponsePromptID == "custom-second")
        #expect(state.aiResponseStatus == .succeeded)
        #expect(state.aiResponseCompletedAt != nil)
        let completed = try #require(state.aiExchangeEvidence.first {
            $0.id == secondID
        })
        #expect(completed.status == .succeeded)
        #expect(completed.completedAt == state.aiResponseCompletedAt)

        // A cancellation-insensitive old provider really returns; generation
        // guards must not mutate either lifecycle record afterward.
        gateway.releaseFirst()
        for _ in 0..<2_000 {
            await Task.yield()
        }
        #expect(state.aiResponseID == secondID)
        #expect(state.aiResponseStatus == .succeeded)
        #expect(state.aiResponse == "Finance approved the Falcon rollout guard.")
    }

    @Test("superseded partial prose remains evidence-only, never dialog history")
    func supersededPartialIsNotArchivable() async throws {
        let gateway = LifecycleSupersessionGateway(emitBeforeWait: true)
        let state = AppState(llm: gateway)
        state.transcript = [TranscriptEntry(
            source: .system, text: "Finance approved the Falcon rollout guard.")]

        state.runPrompt(prompt("partial-first", "First request"))
        for _ in 0..<45_000
        where !gateway.firstIsWaiting || state.aiResponse != "obsolete partial" {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(gateway.firstIsWaiting)
        #expect(state.aiResponse == "obsolete partial")
        let firstID = try #require(state.aiResponseID)

        state.runPrompt(prompt("completed-second", "Replacement request"))
        await settle(state)

        let superseded = try #require(state.aiExchangeEvidence.first {
            $0.id == firstID
        })
        #expect(superseded.status == .superseded)
        #expect(superseded.answer == "obsolete partial")
        #expect(!superseded.isArchivable)
        #expect(state.aiHistory.isEmpty)
        #expect(state.aiResponseStatus == .succeeded)

        gateway.releaseFirst()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(state.aiHistory.isEmpty)
        #expect(state.aiResponse == "Finance approved the Falcon rollout guard.")
    }

    @Test("dev cancellation is exchange-scoped and terminal before another prompt")
    func liveHookCancellationRejectsStaleExchangeIDs() async throws {
        let gateway = LifecycleSupersessionGateway()
        let state = AppState(llm: gateway)
        state.transcript = [TranscriptEntry(
            source: .system, text: "Finance approved the Falcon rollout guard.")]

        state.runPrompt(prompt("snapshot", "Capture the active model snapshot"))
        for _ in 0..<45_000 where !gateway.firstIsWaiting {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(gateway.firstIsWaiting)
        let exchangeID = try #require(state.aiResponseID).uuidString

        #expect(!state.debugCancelAssistantPrompt(exchangeID: UUID().uuidString))
        #expect(state.aiResponseStatus == .inProgress)
        #expect(state.debugCancelAssistantPrompt(exchangeID: exchangeID))
        #expect(state.aiResponseStatus == .cancelled)
        #expect(state.aiStreaming == false)
        #expect(state.aiExchangeEvidence.last?.id.uuidString == exchangeID)
        #expect(state.aiExchangeEvidence.last?.status == .cancelled)

        gateway.releaseFirst()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(state.aiResponseStatus == .cancelled)
    }

    @Test("dev snapshot exposes stable current and terminal evidence fields")
    func liveHookSnapshotIncludesLifecycle() async throws {
        _ = NSApplication.shared
        let state = AppState(llm: MockLLMGateway(
            response: "Finance approved the Falcon rollout guard."))
        state.transcript = [TranscriptEntry(
            source: .system, text: "Finance approved the Falcon rollout guard.")]
        state.runPrompt(prompt("custom-evidence", "Give rollout advice"))
        await settle(state)

        let data = LiveTestHooks.snapshotJSON(
            of: state, requestID: "lifecycle-test", appliedAt: 123)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["aiResponseID"] as? String == state.aiResponseID?.uuidString)
        #expect(root["aiResponsePromptID"] as? String == "custom-evidence")
        #expect(root["aiResponseStatus"] as? String == "succeeded")
        #expect(root["aiResponseStartedAt"] is Double)
        #expect(root["aiResponseCompletedAt"] is Double)
        let evidence = try #require(root["aiExchangeEvidenceFull"] as? [[String: Any]])
        let row = try #require(evidence.first)
        #expect(row["id"] as? String == state.aiResponseID?.uuidString)
        #expect(row["promptID"] as? String == "custom-evidence")
        #expect(row["status"] as? String == "succeeded")
        #expect(row["promptedAt"] is Double)
        #expect(row["completedAt"] is Double)
    }

    @Test("AIExchange decodes pre-lifecycle saved sessions and round-trips metadata")
    func codableBackwardCompatibility() throws {
        let exchange = AIExchange(
            prompt: "Summarize", answer: "Falcon approved.",
            promptedAt: Date(timeIntervalSince1970: 10), promptID: "summary",
            completedAt: Date(timeIntervalSince1970: 12), status: .succeeded)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTrip = try decoder.decode(
            AIExchange.self, from: encoder.encode(exchange))
        #expect(roundTrip == exchange)

        var legacy = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(exchange)) as? [String: Any])
        for key in ["promptedAt", "promptID", "completedAt", "status"] {
            legacy.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try decoder.decode(AIExchange.self, from: legacyData)
        #expect(decodedLegacy.id == exchange.id)
        #expect(decodedLegacy.status == .succeeded)
        #expect(decodedLegacy.promptedAt == nil)
        #expect(decodedLegacy.completedAt == nil)

        legacy["answer"] = "Error: old provider failed"
        let failedLegacy = try decoder.decode(
            AIExchange.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(failedLegacy.status == .failed)
    }
}
