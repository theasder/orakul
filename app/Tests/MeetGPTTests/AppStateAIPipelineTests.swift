import Foundation
import Combine
import Testing
@testable import MeetGPT

/// A stub LLM seam: returns a canned completion, streams it through onDelta, and
/// records every call so tests can assert on the assembled system + user prompt.
/// Thread-safe because the AI pipeline may call it again for the follow-up pass.
final class MockLLMGateway: LLMGateway, @unchecked Sendable {
    struct Call { let system: String; let user: String; let model: String }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let response: String

    init(response: String) { self.response = response }

    var calls: [Call] { lock.withLock { _calls } }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        lock.withLock {
            _calls.append(Call(system: system, user: user, model: model.id))
        }
        onDelta(response)
        return response
    }
}

/// Emits a completion one character at a time to model a high-frequency SSE
/// stream without sleeping between tokens.
final class BurstMockLLMGateway: LLMGateway, @unchecked Sendable {
    let response: String

    init(response: String) { self.response = response }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        for character in response { onDelta(String(character)) }
        return response
    }
}

/// Its first request deliberately ignores cancellation until the test releases
/// it, exercising the stale-provider-callback guard between prompt runs.
final class SupersededLLMGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var firstReturned = false

    var callCount: Int { lock.withLock { calls } }
    var firstIsWaiting: Bool { lock.withLock { firstContinuation != nil } }
    var firstDidReturn: Bool { lock.withLock { firstReturned } }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
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

/// Routes the export-title request separately from the visible-answer and
/// silent follow-up calls, while counting only the potentially billable title.
final class AnswerExportLLMGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var _titleCallCount = 0

    var titleCallCount: Int {
        lock.withLock { _titleCallCount }
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        if system == AssistantAnswerTitle.systemPrompt {
            lock.withLock { _titleCallCount += 1 }
            return "\"Roadmap Delivery Decisions\""
        }
        if system.contains("follow-up") || system.contains("Follow-up") {
            return "[]"
        }
        let answer = "## Decision\n- Ship the desktop build Friday."
        onDelta(answer)
        return answer
    }
}

@MainActor
@Suite("AppState AI pipeline")
struct AppStateAIPipelineTests {
    /// Await the fire-and-forget AI task, then let the main-actor delta hops that
    /// accumulate `aiResponse` drain before asserting.
    private func settle(_ state: AppState) async {
        await state.aiTask?.value
        for _ in 0..<200 {
            if !state.aiStreaming && !state.aiResponse.isEmpty { break }
            await Task.yield()
        }
    }

    private func customPrompt(_ text: String) -> QuickPrompt {
        .custom(id: "custom-test", icon: "✨", title: "Test", prompt: text)
    }

    @Test("a custom prompt streams the model's answer into aiResponse")
    func streamsAnswer() async {
        let llm = MockLLMGateway(response: "Here is the crux of it.")
        let state = AppState(llm: llm)
        state.transcript = [TranscriptEntry(source: .mic, text: "we talked about the roadmap")]

        state.runPrompt(customPrompt("Summarize the roadmap discussion."))
        await settle(state)

        #expect(state.aiResponse == "Here is the crux of it.")
        #expect(state.aiResponsePrompt == "Summarize the roadmap discussion.")
        #expect(state.aiStreaming == false)
        let compose = state.workflowSteps.first { $0.label == "Compose the answer" }
        #expect(compose?.app?.kind == .ai)
        #expect(compose?.status == .succeeded)
    }

    @Test("the assembled prompt carries the base instructions, the transcript, and the request")
    func assemblesPrompt() async {
        let llm = MockLLMGateway(response: "ok")
        let state = AppState(llm: llm)
        state.transcript = [TranscriptEntry(source: .system, text: "the budget is forty thousand dollars")]

        state.runPrompt(customPrompt("What number was quoted?"))
        await settle(state)

        let first = llm.calls.first
        #expect(first != nil)
        // Base system instructions are always present (SystemInstructions.base).
        #expect(first?.system.contains("live recording transcript") == true)
        // The user message includes the transcript text and the request.
        #expect(first?.user.contains("forty thousand dollars") == true)
        #expect(first?.user.contains("What number was quoted?") == true)
    }

    @Test("an empty transcript still runs and marks the request in the prompt")
    func emptyTranscript() async {
        let llm = MockLLMGateway(response: "Nothing recorded yet.")
        let state = AppState(llm: llm)

        state.runPrompt(customPrompt("Anything to flag?"))
        await settle(state)

        #expect(state.aiResponse == "Nothing recorded yet.")
        #expect(llm.calls.first?.user.contains("empty") == true)
    }

    @Test("a follow-up run replaces the previous answer")
    func secondRunReplaces() async {
        let llm = MockLLMGateway(response: "first answer")
        let state = AppState(llm: llm)
        state.transcript = [TranscriptEntry(source: .mic, text: "context")]

        state.runPrompt(customPrompt("First question"))
        await settle(state)
        #expect(state.aiResponse == "first answer")

        let llm2 = MockLLMGateway(response: "second answer")
        let state2 = AppState(llm: llm2)
        state2.transcript = state.transcript
        state2.runPrompt(customPrompt("Second question"))
        await settle(state2)
        #expect(state2.aiResponse == "second answer")
    }

    @Test("high-frequency model deltas are batched into bounded UI publications")
    func batchesStreamingDeltas() async {
        let response = String(repeating: "stream ", count: 100)
        let state = AppState(llm: BurstMockLLMGateway(response: response))
        state.transcript = [TranscriptEntry(source: .mic, text: "context")]
        var publications = 0
        let observation = state.$aiResponse.dropFirst().sink { _ in publications += 1 }

        state.runPrompt(customPrompt("Summarize."))
        await settle(state)

        #expect(state.aiResponse == response)
        #expect(publications < 20)
        _ = observation
    }

    @Test("late deltas from a canceled prompt cannot contaminate the next answer")
    func rejectsSupersededDeltas() async throws {
        let llm = SupersededLLMGateway()
        let state = AppState(llm: llm)
        state.transcript = [TranscriptEntry(source: .mic, text: "context")]

        state.runPrompt(customPrompt("First"))
        // Built-in skill resolution is process-wide and serialized. Under the
        // complete parallel suite it can be busy for tens of seconds, so wait
        // for the provider boundary instead of assuming 200 scheduler yields.
        for _ in 0..<45_000 where !llm.firstIsWaiting {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(llm.firstIsWaiting)

        state.runPrompt(customPrompt("Second"))
        await settle(state)
        #expect(state.aiResponse == "current answer")
        #expect(state.aiResponsePrompt == "Second")

        llm.releaseFirst()
        // Make the stale-callback assertion non-vacuous: the obsolete provider
        // must actually publish and return before we inspect the current answer.
        for _ in 0..<2_000 where !llm.firstDidReturn {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try #require(llm.firstDidReturn)
        #expect(state.aiResponse == "current answer")
    }

    @Test("DOCX export is named after the call, with no model call")
    func namesExportAfterTheCall() async throws {
        // The title used to be invented by the model on every export: it cost
        // credits and a round trip, and produced a different name each time for
        // the same dialog. It is now derived from the meeting.
        let llm = AnswerExportLLMGateway()
        let state = AppState(llm: llm)
        state.meetingTitle = "Roadmap sync"
        state.transcript = [TranscriptEntry(source: .mic, text: "Roadmap discussion")]
        state.runPrompt(customPrompt("What did we decide about delivery?"))
        await settle(state)

        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await state.prepareCurrentAnswerExport(exportedAt: exportedAt)
        let second = try await state.prepareCurrentAnswerExport(exportedAt: exportedAt)

        #expect(first.title == "Assistant chat · Roadmap sync")
        #expect(first.prompt == "What did we decide about delivery?")
        #expect(first.answer == state.aiResponse)
        #expect(first.exportedAt == exportedAt)
        // Stable across exports, and free.
        #expect(second.title == first.title)
        #expect(llm.titleCallCount == 0)
        #expect(state.aiResponseExportTitle == first.title)
    }

    @Test("an untitled call falls back to its date, never to an empty name")
    func namesUntitledExportByDate() async throws {
        let state = AppState(llm: AnswerExportLLMGateway())
        state.meetingTitle = "   "
        state.transcript = [TranscriptEntry(source: .mic, text: "Roadmap discussion")]
        state.runPrompt(customPrompt("What did we decide?"))
        await settle(state)

        let document = try await state.prepareCurrentAnswerExport()
        #expect(document.title.hasPrefix("Assistant chat · "))
        #expect(document.title.count > "Assistant chat · ".count)
    }

    @Test("only completed assistant answers expose DOCX export")
    func exportAvailability() {
        let state = AppState(llm: MockLLMGateway(response: ""))
        #expect(!state.canExportAssistantAnswer)

        state.aiResponse = "A useful answer"
        #expect(state.canExportAssistantAnswer)

        state.aiStreaming = true
        #expect(!state.canExportAssistantAnswer)

        state.aiStreaming = false
        state.aiResponse = "Error: provider unavailable"
        #expect(!state.canExportAssistantAnswer)
    }
}
