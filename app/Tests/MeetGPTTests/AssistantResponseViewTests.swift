import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
@Suite("Assistant response prompt")
struct AssistantResponseViewTests {
    @Test("the question that produced an answer is visible above it")
    func rendersQuestion() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        let now = Date()
        state.restoreSession(SavedSession(
            id: UUID(),
            title: "Design sync",
            startedAt: now,
            savedAt: now,
            goal: "",
            entries: [],
            aiResponse: "We agreed to ship Friday.",
            aiResponsePrompt: "What did we decide about launch?",
            digest: ""
        ))

        let view = ResponseView().environmentObject(state)
        #expect(throws: Never.self) {
            try view.inspect().find(text: "What did we decide about launch?")
        }
    }

    @Test("asking a co-pilot recommendation keeps the full question provenance")
    func sidebarAskCapturesQuestion() {
        let state = AppState(llm: MockLLMGateway(response: "Answer"))
        let suggestion = Suggestion(
            title: "Уточнить бюджет",
            detail: "Какая сумма уже согласована?",
            kind: .question
        )

        state.askSuggestion(suggestion)

        #expect(state.aiResponsePrompt == "Уточнить бюджет — Какая сумма уже согласована?")
        state.clearAll()
    }

    @Test("an archived answer keeps its follow-up button visible")
    func archivedFollowUpRemainsVisible() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        let followUp = QuickPrompt.custom(
            id: "custom-pressure-test", icon: "➡️",
            title: "Pressure-test it", prompt: "Pressure-test the recommendation.")
        let now = Date()
        state.restoreSession(SavedSession(
            id: UUID(), title: "Design sync", startedAt: now, savedAt: now,
            goal: "", entries: [], aiResponse: "Current answer",
            aiResponsePrompt: "Current question",
            aiHistory: [AIExchange(
                prompt: "Earlier question", answer: "Earlier answer",
                followUpPrompts: [followUp])], digest: ""))

        let view = ResponseView().environmentObject(state)
        #expect(throws: Never.self) {
            try view.inspect().find(text: "Pressure-test it")
        }
    }
}
