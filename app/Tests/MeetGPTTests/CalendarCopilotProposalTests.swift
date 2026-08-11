import Foundation
import Testing
@testable import MeetGPT

/// What the calendar sync loaded is shown as a STATUS LINE, not as a blind spot.
///
/// This suite previously asserted the opposite: that syncing inserted an `.advice`
/// Suggestion into the blind-spot list. That behaviour was the bug. The card
/// carried no transcript evidence, unlike every real suggestion, so it was the one
/// item that could not be grounded; it sat at index 0 and pushed actual blind
/// spots down; and on a call reopened from History it told the user to "set a goal
/// for live blind-spot checks" about a meeting that had already ended.
///
/// The tests now pin the property that was missing — the blind-spot list contains
/// only blind spots — and keep the two behaviours worth keeping: the fact is still
/// surfaced, and a re-sync updates rather than stacks.
@Suite("Calendar sync note")
struct CalendarCopilotProposalTests {
    // @MainActor because AppState's init is — a nonisolated helper made every
    // call site an implicitly-async one and failed to compile.
    @MainActor
    private func makeState() -> AppState {
        AppState(llm: MockLLMGateway(response: ""), credentialStore: InMemoryKeychain())
    }

    @Test("a synced event names itself and what it loaded")
    @MainActor
    func syncSetsTheNote() {
        let state = makeState()
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Weekly product sync",
            summary: "Event: Weekly product sync\nAgenda:\nRoadmap review",
            attendeeCount: 4))

        #expect(state.calendarSyncNote.contains("Weekly product sync"))
        #expect(state.calendarSyncNote.contains("4 attendees"))
        #expect(state.calendarSyncNote.contains("agenda"))
    }

    @Test("syncing adds NOTHING to the blind-spot list")
    @MainActor
    func syncAddsNoSuggestion() {
        // The regression. A calendar fact is not a finding, and the panel that
        // shows findings should stay empty until the co-pilot has one.
        let state = makeState()
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Weekly product sync",
            summary: "Event: Weekly product sync\nAgenda:\nRoadmap review",
            attendeeCount: 4))

        #expect(state.suggestions.isEmpty)
    }

    @Test("re-syncing replaces the note rather than accumulating")
    @MainActor
    func resyncUpdatesInPlace() {
        let state = makeState()
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Weekly product sync", summary: "Event: Weekly product sync", attendeeCount: 4))
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Weekly product sync", summary: "Event: Weekly product sync", attendeeCount: 5))

        #expect(state.calendarSyncNote.contains("5 attendees"))
        #expect(!state.calendarSyncNote.contains("4 attendees"))
        // A single string cannot stack, which is the point of using one.
        #expect(state.suggestions.isEmpty)
    }

    @Test("a placeholder calendar title produces no note at all")
    @MainActor
    func placeholderTitleSkipped() {
        // "Calendar event" is what an untitled invite reports. Naming it back to
        // the user is worse than saying nothing.
        let state = makeState()
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Calendar event", summary: "", attendeeCount: 0))

        #expect(state.calendarSyncNote.isEmpty)
        #expect(state.suggestions.isEmpty)
    }

    @Test("an event with no agenda and no attendees still names itself")
    @MainActor
    func bareEventStillNoted() {
        let state = makeState()
        state.applyCalendarAgenda(CalendarAgenda(
            title: "1:1 with Dana", summary: "Event: 1:1 with Dana", attendeeCount: 0))

        #expect(state.calendarSyncNote.contains("1:1 with Dana"))
        // No trailing "— in context" fragment when there is nothing to list.
        #expect(!state.calendarSyncNote.contains("—"))
    }
}
