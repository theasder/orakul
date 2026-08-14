import Foundation
import Testing
@testable import MeetGPT

/// A provider that models two legal-but-different streaming contracts. The
/// normal case returns the same aggregate it emitted; the regression case emits
/// a complete SSE answer but accidentally returns an empty aggregate.
private final class AdviceResponseGateway: LLMGateway, @unchecked Sendable {
    enum Mode {
        case aggregateAndStream
        case streamOnly
        case empty
        case failure
    }

    private let mode: Mode
    private let answer: String

    init(mode: Mode, answer: String = "## Top 3\n- Ship the rollback guard first.") {
        self.mode = mode
        self.answer = answer
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        // Follow-up generation is outside the visible answer and should remain
        // silent in these response-state tests.
        if system == FollowUpService.systemPrompt { return "[]" }

        switch mode {
        case .aggregateAndStream:
            onDelta(answer)
            return answer
        case .streamOnly:
            let split = answer.index(answer.startIndex, offsetBy: answer.count / 2)
            onDelta(String(answer[..<split]))
            onDelta(String(answer[split...]))
            return " \n "
        case .empty:
            return " \n "
        case .failure:
            throw LLMError.http("Test provider", 503, "temporarily unavailable")
        }
    }
}

/// The first call deliberately ignores task cancellation, emits a stale delta,
/// and returns only after the test releases it. `firstDidReturn` makes the
/// generation-guard assertion non-vacuous: the obsolete provider really did
/// attempt to publish before the UI is checked.
private final class SupersededAdviceGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var firstReturned = false

    var firstIsWaiting: Bool {
        lock.withLock { firstContinuation != nil }
    }

    var firstDidReturn: Bool {
        lock.withLock { firstReturned }
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let call = lock.withLock {
            calls += 1
            return calls
        }

        if call == 1 {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if releaseRequested { return true }
                    firstContinuation = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
            onDelta("stale suffix")
            lock.withLock { firstReturned = true }
            return "stale suffix"
        }

        onDelta("current answer")
        return "current answer"
    }

    func releaseFirst() {
        let continuation = lock.withLock {
            releaseRequested = true
            let value = firstContinuation
            firstContinuation = nil
            return value
        }
        continuation?.resume()
    }
}

@MainActor
@Suite("Quick-prompt response regression")
struct QuickPromptResponseRegressionTests {
    private func advicePrompt() throws -> QuickPrompt {
        try #require(QuickPrompts.all.first { $0.id == "advice" })
    }

    private func settle(_ state: AppState) async {
        await state.aiTask?.value
        for _ in 0..<200 where state.aiStreaming {
            await Task.yield()
        }
    }

    private func makeState(gateway: LLMGateway) -> AppState {
        let state = AppState(llm: gateway)
        state.transcript = [
            TranscriptEntry(
                source: .system,
                text: "The rollout needs a rollback guard before Friday."),
        ]
        return state
    }

    @Test("Give Advice writes one renderable terminal answer and archives it on the next turn")
    func adviceSuccessAndHistory() async throws {
        let answer = "## Top 3\n- Ship the rollback guard first."
        let state = makeState(gateway: AdviceResponseGateway(
            mode: .aggregateAndStream, answer: answer))
        let advice = try advicePrompt()
        #expect(advice.id == "advice")
        #expect(advice.title == "Дать совет")

        // This is the exact state action invoked by the Give Advice PromptChip.
        state.runPrompt(advice)
        await settle(state)

        #expect(state.aiResponse == answer) // streamed + returned must not duplicate
        #expect(state.aiResponsePrompt == advice.prompt)
        #expect(state.aiStreaming == false)
        #expect(state.hasContent)
        #expect(state.canExportAssistantAnswer)
        #expect(state.dialogClipboardText.contains(advice.prompt))
        #expect(state.dialogClipboardText.contains(answer))
        #expect(state.aiHistory.isEmpty)
        let compose = state.workflowSteps.first { $0.label == "Compose the answer" }
        #expect(compose?.status == .succeeded)
        #expect(compose?.app?.kind == .ai)

        state.runPrompt(.custom(
            id: "custom-after-advice", icon: "✨", title: "Next",
            prompt: "What should happen next?"))
        await settle(state)

        let archivedAdvice = try #require(state.aiHistory.last)
        #expect(archivedAdvice.prompt == advice.prompt)
        #expect(archivedAdvice.answer == answer)
        #expect(archivedAdvice.isArchivable)
        #expect(state.aiResponse == answer)
    }

    @Test("Give Advice preserves emitted SSE text when the provider aggregate is empty")
    func adviceStreamOnlyCompletion() async throws {
        let answer = "## Recommendation\nUse a staged rollout with an explicit abort threshold."
        let state = makeState(gateway: AdviceResponseGateway(
            mode: .streamOnly, answer: answer))

        state.runPrompt(try advicePrompt())
        await settle(state)

        #expect(state.aiResponse == answer)
        #expect(state.hasContent)
        #expect(state.canExportAssistantAnswer)
        #expect(state.workflowSteps.first { $0.label == "Compose the answer" }?.status == .succeeded)
    }

    @Test("an empty successful provider response becomes a visible terminal error")
    func emptyProviderResponseIsVisible() async throws {
        let state = makeState(gateway: AdviceResponseGateway(mode: .empty))

        state.runPrompt(try advicePrompt())
        await settle(state)

        #expect(state.aiStreaming == false)
        #expect(AnswerFailure.looksLikeFailure(state.aiResponse))
        #expect(state.aiResponse.contains("invalid response"))
        #expect(state.hasContent)
        #expect(!state.canExportAssistantAnswer)
        #expect(state.dialogClipboardText.contains(state.aiResponse))
        #expect(state.workflowSteps.first { $0.label == "Compose the answer" }?.status == .failed)
    }

    @Test("a provider failure writes an error and marks composition failed")
    func providerFailureIsVisible() async throws {
        let state = makeState(gateway: AdviceResponseGateway(mode: .failure))

        state.runPrompt(try advicePrompt())
        await settle(state)

        #expect(state.aiResponse.contains("Test provider API error (503)"))
        #expect(state.hasContent)
        #expect(!state.canExportAssistantAnswer)
        #expect(state.workflowSteps.first { $0.label == "Compose the answer" }?.status == .failed)
    }

    @Test("a superseded Give Advice run cannot erase the next prompt's answer")
    func supersededAdviceCannotPublish() async throws {
        let gateway = SupersededAdviceGateway()
        let state = makeState(gateway: gateway)

        let advice = try advicePrompt()
        #expect(advice.id == "advice")
        state.runPrompt(advice)
        // Built-in prompts first resolve their bundled skill on a serialized
        // worker, so wait for the provider seam rather than assuming a fixed
        // number of scheduler yields is enough under parallel test load.
        for _ in 0..<45_000 where !gateway.firstIsWaiting {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(gateway.firstIsWaiting)

        state.runPrompt(.custom(
            id: "custom-current", icon: "✨", title: "Current",
            prompt: "Give the current answer."))
        await settle(state)
        #expect(state.aiResponse == "current answer")
        #expect(state.aiResponsePrompt == "Give the current answer.")

        gateway.releaseFirst()
        for _ in 0..<2_000 where !gateway.firstDidReturn {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(gateway.firstDidReturn)

        #expect(state.aiResponse == "current answer")
        #expect(state.aiHistory.isEmpty) // the canceled blank Advice turn is not a dialog turn
    }
}
