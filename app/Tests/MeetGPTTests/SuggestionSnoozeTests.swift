import Foundation
import Testing
@testable import MeetGPT

/// Per-call suggestion snooze ("Pause for this call") — deliberately NOT the
/// permanent Config switch: a new recording auto-resets it, so there is
/// nothing for the user to remember to turn back on.
@Suite("Suggestion snooze")
struct SuggestionSnoozeTests {
    @Test("snooze pauses, resume clears, and a new recording auto-resets")
    @MainActor
    func snoozeLifecycle() {
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        #expect(!state.suggestionsSnoozedThisCall)

        state.snoozeSuggestionsForCall()
        #expect(state.suggestionsSnoozedThisCall)

        state.resumeSuggestionsThisCall()
        #expect(!state.suggestionsSnoozedThisCall)

        // Auto-reset: snooze again, then simulate the fresh-call reset that
        // startRecording performs.
        state.snoozeSuggestionsForCall()
        state.resetForNewRecording()
        #expect(!state.suggestionsSnoozedThisCall)
    }

    @Test("snoozing keeps already-surfaced suggestion cards visible")
    @MainActor
    func snoozeKeepsCards() {
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        state.suggestions = [Suggestion(title: "Risk", detail: "Budget unraised", kind: .risk)]
        state.snoozeSuggestionsForCall()
        #expect(state.suggestions.count == 1)
    }

    @Test("Settings off-on preserves surfaced cards")
    @MainActor
    func settingsRestartKeepsCards() {
        let original = Config.brainstormEnabled
        defer { Config.brainstormEnabled = original }
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        state.status = .recording
        state.suggestions = [Suggestion(title: "Risk", detail: "Budget unraised", kind: .risk)]

        state.setBlindSpotsEnabled(false)
        state.setBlindSpotsEnabled(true)

        #expect(state.suggestions.map(\.title) == ["Risk"])
        state.setBlindSpotsEnabled(false)
    }

    @Test("dismissed cards do not regenerate until the next call")
    @MainActor
    func dismissedTitlesArePerCall() {
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        let dismissed = Suggestion(title: "Missing owner", detail: "No owner named", kind: .missingInfo)
        state.suggestions = [dismissed]

        state.dismissSuggestion(id: dismissed.id)
        state.mergeSuggestions([
            Suggestion(title: "Missing owner", detail: "Still no owner", kind: .missingInfo),
            Suggestion(title: "Pricing risk", detail: "Discount unresolved", kind: .risk),
        ])

        #expect(state.suggestions.map(\.title) == ["Pricing risk"])
        #expect(state.dismissedSuggestionTitles.contains("missing owner"))

        state.resetForNewRecording()
        state.mergeSuggestions([
            Suggestion(title: "Missing owner", detail: "Новый звонок", kind: .missingInfo),
        ])
        #expect(state.suggestions.map(\.title) == ["Missing owner"])
    }
}
