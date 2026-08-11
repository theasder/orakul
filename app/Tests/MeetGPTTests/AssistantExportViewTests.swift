import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
@Suite("Assistant DOCX export view")
struct AssistantExportViewTests {
    private func view(state: AppState) -> some View {
        AIStudioView()
            .environmentObject(state)
            .environmentObject(MCPConnectionManager(tokenStore: InMemoryKeychain()))
    }

    @Test("completed answers show a visible share action")
    func completedAnswerShowsShare() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.aiResponse = "A completed answer"

        // Copy and Export were separate controls gated on different conditions,
        // so an answer that failed the export check showed a lone copy icon and
        // no route to Word at all. They are now one share menu.
        #expect(throws: Never.self) {
            try view(state: state).inspect().find(
                viewWithAccessibilityLabel: "Share answer")
        }
    }

    @Test("nothing to share means no share control")
    func emptyStateHidesShare() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        #expect(throws: (any Error).self) {
            try view(state: state).inspect().find(
                viewWithAccessibilityLabel: "Share answer")
        }
    }

    @Test("streaming and failed answers are copyable but not exportable")
    func unfinishedStatesHideExportItems() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))

        // Copying a partial answer or an error message is legitimate — that is
        // what the old copy button allowed and the merge preserves it. What must
        // not appear is the offer to file either one as a document.
        state.aiResponse = "Partial answer"
        state.aiStreaming = true
        #expect(!state.canExportAssistantAnswer)
        #expect(throws: Never.self) {
            try view(state: state).inspect().find(
                viewWithAccessibilityLabel: "Share answer")
        }

        state.aiStreaming = false
        state.aiResponse = "Error: provider unavailable"
        #expect(!state.canExportAssistantAnswer)
        #expect(!state.canExportToGoogleDocs)
        #expect(!state.canExportToNotion)
    }
}
