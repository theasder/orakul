import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// View-logic tests for the sidebar's account affordance: signed out shows a
/// sign-in control, signed in shows the account menu with the email. The
/// backend can be disabled per build, so availability is explicit in these tests.
@MainActor
@Suite("Sidebar account affordance")
struct SidebarViewTests {
    private func state(connected: Bool, email: String? = nil) -> AppState {
        let s = AppState(llm: MockLLMGateway(response: ""))
        s.wheesprConnected = connected
        s.wheesprEmail = email
        return s
    }

    @Test("signed out: offers a Sign in control, no account menu")
    func signedOut() throws {
        let view = SidebarFooter(accountAvailable: true).environmentObject(state(connected: false))
        #expect(throws: Never.self) { try view.inspect().find(viewWithAccessibilityLabel: "Sign in") }
        #expect(throws: (any Error).self) {
            try view.inspect().find(viewWithAccessibilityLabel: "Account: nobody@example.com")
        }
    }

    @Test("signed in: shows the account menu labeled with the email")
    func signedIn() throws {
        let view = SidebarFooter(accountAvailable: true)
            .environmentObject(state(connected: true, email: "artem@example.com"))
        #expect(throws: Never.self) {
            try view.inspect().find(viewWithAccessibilityLabel: "Account: artem@example.com")
        }
        // The sign-in control is gone once connected.
        #expect(throws: (any Error).self) { try view.inspect().find(viewWithAccessibilityLabel: "Sign in") }
    }

    @Test("backend unavailable: hides account controls")
    func unavailable() throws {
        let view = SidebarFooter(accountAvailable: false)
            .environmentObject(state(connected: true, email: "artem@example.com"))
        #expect(throws: (any Error).self) {
            try view.inspect().find(viewWithAccessibilityLabel: "Account: artem@example.com")
        }
        #expect(throws: (any Error).self) {
            try view.inspect().find(viewWithAccessibilityLabel: "Sign in")
        }
    }

    @Test("Focus does not duplicate recommendations owned by Co-pilot")
    func focusExcludesCopilotSuggestions() {
        let state = state(connected: false)
        state.suggestions = [
            Suggestion(title: "Уточнить бюджет",
                       detail: "Какая сумма уже согласована?",
                       kind: .question)
        ]

        #expect(state.focusItems.isEmpty)
    }
}
