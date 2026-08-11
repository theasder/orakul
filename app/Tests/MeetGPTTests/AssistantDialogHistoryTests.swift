import Foundation
import Testing
@testable import MeetGPT

/// The assistant dialog used to hold exactly ONE exchange: `aiResponsePrompt` +
/// `aiResponse`. Pressing a second prompt overwrote both in place, so the first
/// question and its answer were gone — mid-meeting, with no way back to them.
/// These tests pin the archive that keeps the thread.
@MainActor
@Suite("Assistant dialog history")
struct AssistantDialogHistoryTests {

    private func settle(_ state: AppState) async {
        await state.aiTask?.value
        for _ in 0..<200 {
            if !state.aiStreaming && !state.aiResponse.isEmpty { break }
            await Task.yield()
        }
    }

    private func prompt(_ text: String) -> QuickPrompt {
        .custom(id: "custom-test", icon: "✨", title: "Test", prompt: text)
    }

    private func state(answering response: String) -> AppState {
        let state = AppState(llm: MockLLMGateway(response: response))
        state.transcript = [TranscriptEntry(source: .mic, text: "we talked about the roadmap")]
        return state
    }

    @Test("the first prompt archives nothing — there is no earlier turn")
    func firstPromptArchivesNothing() async {
        let state = state(answering: "First answer.")
        state.runPrompt(prompt("First question"))
        await settle(state)

        #expect(state.aiHistory.isEmpty)
        #expect(state.aiResponse.contains("First answer."))
    }

    @Test("a second prompt keeps the first question and answer")
    func secondPromptArchivesTheFirst() async {
        let state = state(answering: "First answer.")
        state.runPrompt(prompt("First question"))
        await settle(state)

        state.runPrompt(prompt("Second question"))
        await settle(state)

        #expect(state.aiHistory.count == 1)
        let archived = try? #require(state.aiHistory.first)
        #expect(archived?.prompt == "First question")
        #expect(archived?.answer.contains("First answer.") == true)
        // ...and the live turn is the new one, not the old.
        #expect(state.aiResponsePrompt == "Second question")
    }

    @Test("a second prompt archives the first answer's follow-up buttons")
    func secondPromptKeepsEarlierFollowUps() async throws {
        let state = state(answering: "First answer.")
        state.runPrompt(prompt("First question"))
        await settle(state)
        let followUp = QuickPrompt.custom(
            id: "custom-follow-up", icon: "➡️", title: "Pressure-test it",
            prompt: "Pressure-test the recommendation.")
        state.followUpPrompts = [followUp]

        state.runPrompt(prompt("Second question"))

        let archived = try #require(state.aiHistory.first)
        #expect(archived.followUpPrompts == [followUp])
        // The live row clears, and that is correct: the archived exchange
        // above keeps its own chips and renders them itself, so every answer
        // shows the buttons that belong to IT. Carrying them into the next
        // answer was tried and made two consecutive answers display an
        // identical row.
        #expect(state.followUpPrompts.isEmpty)
    }

    @Test("only a nonblank successful answer is archived")
    func onlySuccessfulAnswerIsArchived() {
        #expect(AIExchange(prompt: "Q", answer: "").isArchivable == false)
        #expect(AIExchange(prompt: "Q", answer: "   \n ").isArchivable == false)
        #expect(AIExchange(prompt: "Q", answer: "A").isArchivable == true)
        for status in [AIExchangeStatus.inProgress, .failed, .cancelled, .superseded] {
            let partial = AIExchange(
                prompt: "Q", answer: "A convincing but incomplete fragment",
                status: status)
            #expect(!partial.isArchivable, "\(status.rawValue)")
        }
    }

    @Test("history is bounded so a long meeting cannot grow without limit")
    func historyIsCapped() async {
        let state = state(answering: "Answer.")
        for index in 0...(AppState.maxArchivedExchanges + 3) {
            state.runPrompt(prompt("Question \(index)"))
            await settle(state)
        }

        #expect(state.aiHistory.count == AppState.maxArchivedExchanges)
        // The OLDEST turns drop; the most recent archived turn must survive.
        #expect(state.aiHistory.first?.prompt != "Question 0")
        #expect(state.aiHistory.last?.prompt
                == "Question \(AppState.maxArchivedExchanges + 2)")
    }

    @Test("clearAll drops the whole thread — it is a full session reset")
    func clearAllDropsHistory() async {
        let state = state(answering: "Answer.")
        state.runPrompt(prompt("First question"))
        await settle(state)
        state.runPrompt(prompt("Second question"))
        await settle(state)
        #expect(!state.aiHistory.isEmpty)

        state.clearAll()

        #expect(state.aiHistory.isEmpty)
        #expect(state.aiResponse.isEmpty)
        #expect(state.aiResponsePrompt.isEmpty)
    }

    @Test("restoring a session brings its thread back")
    func restoreCarriesHistory() {
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        let history = [AIExchange(prompt: "Earlier question", answer: "Earlier answer")]
        state.restoreSession(SavedSession(
            id: UUID(), title: "Roadmap", startedAt: Date(), savedAt: Date(),
            goal: "", entries: [], aiResponse: "Latest answer",
            aiResponsePrompt: "Latest question", aiHistory: history, digest: ""
        ))

        #expect(state.aiHistory.count == 1)
        #expect(state.aiHistory.first?.prompt == "Earlier question")
        #expect(state.aiResponse == "Latest answer")
    }

    @Test("sessions saved before the dialog had a history still decode")
    func oldSessionsDecode() throws {
        // Backward compatibility is the real regression risk of adding a field
        // to a persisted type: every session on disk predates aiHistory.
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","startedAt":0,"savedAt":0,
         "goal":"","entries":[],"aiResponse":"answer","digest":""}
        """
        let decoded = try JSONDecoder().decode(SavedSession.self, from: Data(json.utf8))
        #expect(decoded.aiHistory == nil)
        #expect(decoded.aiResponse == "answer")
    }

    @Test("exchange follow-up buttons round-trip and old exchanges default empty")
    func exchangeFollowUpsAreBackwardCompatible() throws {
        let followUp = QuickPrompt.custom(
            id: "custom-next", icon: "➡️", title: "Next", prompt: "Go deeper")
        let original = AIExchange(
            prompt: "Question", answer: "Answer", followUpPrompts: [followUp])
        let decoded = try JSONDecoder().decode(
            AIExchange.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)

        let legacy = """
        {"id":"\(UUID().uuidString)","prompt":"Q","answer":"A","at":0}
        """
        let old = try JSONDecoder().decode(AIExchange.self, from: Data(legacy.utf8))
        #expect(old.followUpPrompts.isEmpty)
    }
}
