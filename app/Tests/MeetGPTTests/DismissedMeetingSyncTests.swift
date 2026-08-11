import Foundation
import Testing
@testable import MeetGPT

/// Hiding a meeting in Focus means "not this one" — everywhere.
///
/// Dismissal used to hide a row and nothing else: the meeting still named the
/// call at the next Start Recording, its agenda still sat in context as
/// `Calendar · …`, and its attendee count still stood. These tests pin the two
/// halves of the fix — the fetch skips hidden events, and hiding evicts what an
/// earlier sync already wrote.
@Suite("Dismissed meetings stay out of the call")
struct DismissedMeetingSyncTests {
    @MainActor
    private func makeState() -> AppState {
        AppState(llm: MockLLMGateway(response: ""), credentialStore: InMemoryKeychain())
    }

    @MainActor
    private func syncedState(eventID: String, title: String) -> AppState {
        let state = makeState()
        state.contextFiles.append(ImportedContextFile(
            name: "Calendar · \(title)", text: "Event: \(title)"))
        state.applyCalendarAgenda(CalendarAgenda(
            title: title, summary: "Event: \(title)", attendeeCount: 4, id: eventID))
        return state
    }

    @Test("hiding the meeting that named the call takes the name back")
    @MainActor
    func dismissEvictsTheSync() {
        let state = syncedState(eventID: "evt-1", title: "Weekly product sync")
        #expect(state.meetingTitle == "Weekly product sync")

        state.dismissMeeting(id: "evt-1")

        #expect(state.meetingTitle.isEmpty)          // back to Untitled meeting
        #expect(state.contextFiles.isEmpty)          // the agenda goes with it
        #expect(state.calendarSyncNote.isEmpty)      // and the "4 attendees" line
        state.restoreAllMeetings()
    }

    @Test("a name the user typed is theirs, not the calendar's")
    @MainActor
    func dismissKeepsAUserTitle() {
        let state = syncedState(eventID: "evt-2", title: "Weekly product sync")
        state.meetingTitle = "Pricing decision"

        state.dismissMeeting(id: "evt-2")

        #expect(state.meetingTitle == "Pricing decision")
        state.restoreAllMeetings()
    }

    @Test("hiding another meeting leaves this call alone")
    @MainActor
    func dismissingAnUnrelatedMeetingChangesNothing() {
        let state = syncedState(eventID: "evt-3", title: "Weekly product sync")

        state.dismissMeeting(id: "some-other-event")

        #expect(state.meetingTitle == "Weekly product sync")
        #expect(state.contextFiles.count == 1)
        state.restoreAllMeetings()
    }

    @Test("an agenda fetched before the dismissal never lands")
    @MainActor
    func dismissedEventCannotBeAppliedLate() {
        // The request goes out at Start Recording; the user hides the meeting
        // while it is in flight. The answer must not arrive anyway.
        let state = makeState()
        state.dismissMeeting(id: "evt-4")

        state.applyCalendarAgenda(CalendarAgenda(
            title: "Weekly product sync", summary: "Event: Weekly product sync",
            attendeeCount: 4, id: "evt-4"))

        #expect(state.meetingTitle.isEmpty)
        #expect(state.calendarSyncNote.isEmpty)
        state.restoreAllMeetings()
    }

    // MARK: - The fetch itself

    private func eventsPayload() -> Data {
        Data("""
        {"items":[
          {"id":"evt-hidden","summary":"Standup","attendees":[{"email":"a@x.com"}]},
          {"id":"evt-next","summary":"Pricing decision","attendees":[{"email":"b@x.com"}]}
        ]}
        """.utf8)
    }

    @Test("the current agenda skips a hidden event and takes the next one")
    func parseSkipsExcluded() throws {
        let agenda = try CalendarService.parse(eventsPayload(), excluding: ["evt-hidden"])
        #expect(agenda.title == "Pricing decision")
        #expect(agenda.id == "evt-next")
    }

    @Test("every candidate hidden means no event, not the newest one")
    func parseThrowsWhenAllExcluded() {
        #expect(throws: CalendarError.self) {
            try CalendarService.parse(eventsPayload(), excluding: ["evt-hidden", "evt-next"])
        }
    }

    @Test("the agenda carries the event id it came from")
    func agendaCarriesID() throws {
        let agenda = try CalendarService.parse(eventsPayload())
        #expect(agenda.id == "evt-hidden")
    }
}
