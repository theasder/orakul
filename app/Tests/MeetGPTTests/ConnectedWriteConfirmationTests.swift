import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
@Suite("Connected-app external write confirmation")
struct ConnectedWriteConfirmationTests {
    private func pending(serverID: String = "gmail",
                         tool: String = "create_draft") -> AppState.PendingAnswerAction {
        let action = AnswerActionPlanner.Action(
            id: "\(serverID):\(tool)", serverID: serverID,
            serverName: serverID == "gmail" ? "Gmail" : "Notion",
            toolName: tool, title: "Create draft in Gmail",
            systemImage: "envelope", rationale: "The user requested a follow-up.")
        return AppState.PendingAnswerAction(
            id: action.id, action: action,
            fields: ["subject": "Falcon follow-up", "body": "Ship Friday."],
            fieldOrder: ["subject", "body"], items: [])
    }

    @Test("a connected write renders destination, tool, editable payload, cancel and confirm")
    func completePreviewContract() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        let staged = pending()
        state.pendingAnswerAction = staged
        let view = AnswerActionConfirmSheet(pending: staged)
            .environmentObject(state)
        let inspected = try view.inspect()

        #expect(throws: Never.self) { try inspected.find(text: "Writes to Gmail · create_draft") }
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityIdentifier: "connected-write.field.subject")
        }
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityIdentifier: "connected-write.field.body")
        }
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityIdentifier: "connected-write.cancel")
        }
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityIdentifier: "connected-write.confirm")
        }
        #expect(state.pendingAnswerAction == staged, "rendering a confirmation must perform no write")
    }

    @Test("cancel dismisses the staged payload without needing a connector")
    func cancelIsNonMutating() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        let staged = pending()
        state.pendingAnswerAction = staged
        let inspected = try AnswerActionConfirmSheet(pending: staged)
            .environmentObject(state).inspect()
        try inspected.find(button: "Отмена").tap()
        #expect(state.pendingAnswerAction == nil)
        #expect(state.runningAnswerAction == nil)
        #expect(state.answerActionResult == nil)
    }
}
