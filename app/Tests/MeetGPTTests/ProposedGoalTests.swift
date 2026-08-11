import Foundation
import Testing
@testable import MeetGPT

/// The Co-pilot goal drives every blind spot, and an empty field meant the
/// co-pilot ran on the meeting name alone. Cruxwing now infers a goal from the
/// meeting name, the attached context and connected-app material, and the
/// opening transcript, and WRITES IT INTO the field rather than offering a chip
/// to accept — the inferred goal already steered the call through
/// `effectiveCallGoal`, so the chip asked for a click that changed nothing
/// except whether the user could see what was steering it.
///
/// The risk of writing into the field is trampling something the user typed, so
/// that is what most of these cover.
@MainActor
@Suite("Proposed call goal")
struct ProposedGoalTests {

    private func state() -> AppState {
        AppState(llm: MockLLMGateway(response: "unused"))
    }

    @Test("a proposal fills the empty field and is marked as proposed")
    func fillsEmptyField() {
        let state = state()
        state.applyProposedGoal("Raise qualified leads and landing conversion")

        #expect(state.callGoal == "Raise qualified leads and landing conversion")
        #expect(state.goalWasProposed)
        // It drives the co-pilot exactly like a typed goal does.
        #expect(state.effectiveCallGoal == "Raise qualified leads and landing conversion")
    }

    @Test("editing the field takes ownership away from the proposal")
    func userEditTakesOwnership() {
        let state = state()
        state.applyProposedGoal("Raise qualified leads")
        #expect(state.goalWasProposed)

        state.callGoal = "Agree the Q3 pricing change"

        // No longer a proposal — the user typed this.
        #expect(!state.goalWasProposed)
        #expect(state.callGoal == "Agree the Q3 pricing change")
    }

    @Test("clearing a proposal empties the field")
    func clearingProposalEmptiesField() {
        let state = state()
        state.applyProposedGoal("Raise qualified leads")

        state.clearProposedGoal()

        #expect(state.callGoal.isEmpty)
        #expect(!state.goalWasProposed)
    }

    @Test("clearing NEVER wipes a goal the user typed")
    func clearingDoesNotTouchUserText() {
        // The clear button only exists while a proposal is showing, but a stale
        // tap must not be able to delete the user's own words.
        let state = state()
        state.callGoal = "Close the renewal with Acme"
        #expect(!state.goalWasProposed)

        state.clearProposedGoal()

        #expect(state.callGoal == "Close the renewal with Acme")
    }

    @Test("a proposal that replaced itself stays a proposal")
    func reproposingStaysProposed() {
        let state = state()
        state.applyProposedGoal("First guess")
        state.applyProposedGoal("Better guess from more context")

        #expect(state.callGoal == "Better guess from more context")
        #expect(state.goalWasProposed)
    }

    @Test("the inferred goal is sanitised before it can reach the field")
    func sanitisesModelOutput() {
        // Whatever the model returns passes through GoalSuggestion first: the
        // NONE sentinel and rambling prose must never be written into the field.
        #expect(GoalSuggestion.sanitizeModelGoal("NONE") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal("") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal(String(repeating: "x", count: 200)) == nil)
        #expect(GoalSuggestion.sanitizeModelGoal("\"Raise qualified leads\"")
                == "Raise qualified leads")
    }
}
