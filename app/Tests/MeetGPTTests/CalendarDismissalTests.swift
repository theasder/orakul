import Foundation
import Testing
@testable import MeetGPT

/// Hiding a calendar row, putting it back, and surviving a misclick.
///
/// The rule underneath all of it: the calendar belongs to the user and often to
/// other attendees, so nothing here touches Google. A dismissed meeting is
/// hidden locally and can always be restored.
@MainActor
@Suite("Calendar event dismissal")
struct CalendarDismissalTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(_ id: String, _ title: String, inMinutes: Double) -> UpcomingMeeting {
        UpcomingMeeting(id: id, title: title,
                        start: now.addingTimeInterval(inMinutes * 60),
                        end: now.addingTimeInterval((inMinutes + 30) * 60),
                        attendees: [])
    }

    /// `focusItems` ranks against the real clock, so state-level fixtures must
    /// be anchored to now — a meeting fixed in 2023 falls outside the 120-minute
    /// horizon and never appears at all.
    private func liveMeeting(_ id: String, _ title: String, inMinutes: Double) -> UpcomingMeeting {
        let now = Date()
        return UpcomingMeeting(id: id, title: title,
                               start: now.addingTimeInterval(inMinutes * 60),
                               end: now.addingTimeInterval((inMinutes + 30) * 60),
                               attendees: [])
    }

    private func state() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        state.upcomingMeetings = [
            liveMeeting("evt-1", "Pricing review", inMinutes: 10),
            liveMeeting("evt-2", "Hiring sync", inMinutes: 40)
        ]
        state.restoreAllMeetings()
        return state
    }

    // MARK: - Ranking

    @Test("a dismissed meeting drops out of Focus")
    func dismissedIsFiltered() {
        let items = FocusRanking.rank(
            meetings: [meeting("evt-1", "Pricing review", inMinutes: 10),
                       meeting("evt-2", "Hiring sync", inMinutes: 40)],
            alert: nil, now: now, dismissedMeetingIDs: ["evt-1"])

        let titles = items.map(\.title)
        #expect(!titles.contains { $0.contains("Pricing review") })
        #expect(titles.contains { $0.contains("Hiring sync") })
    }

    @Test("dismissing nothing changes nothing")
    func emptyDismissalIsInert() {
        let meetings = [meeting("evt-1", "Pricing review", inMinutes: 10)]
        let with = FocusRanking.rank(meetings: meetings, alert: nil, now: now, dismissedMeetingIDs: [])
        let without = FocusRanking.rank(meetings: meetings, alert: nil, now: now)
        #expect(with.map(\.id) == without.map(\.id))
    }

    @Test("an alert still shows even with every meeting hidden")
    func alertSurvivesDismissal() {
        let items = FocusRanking.rank(
            meetings: [meeting("evt-1", "Pricing review", inMinutes: 10)],
            alert: "Recording permission missing", now: now,
            dismissedMeetingIDs: ["evt-1"])
        #expect(items.contains { $0.kind == .alert })
    }

    // MARK: - Dismiss / restore

    @Test("dismiss hides it and restore brings it back")
    func dismissAndRestore() {
        let state = state()
        #expect(state.focusItems.contains { $0.meetingID == "evt-1" })

        state.dismissMeeting(id: "evt-1")
        #expect(!state.focusItems.contains { $0.meetingID == "evt-1" })
        #expect(state.dismissedMeetings.map(\.id) == ["evt-1"])

        state.restoreMeeting(id: "evt-1")
        #expect(state.focusItems.contains { $0.meetingID == "evt-1" })
        #expect(state.dismissedMeetings.isEmpty)
    }

    @Test("dismissal never removes the event from the calendar")
    func calendarIsUntouched() {
        let state = state()
        state.dismissMeeting(id: "evt-1")
        // Hidden from Focus, still present in the calendar the app holds — the
        // only thing that makes restoring possible, and the only correct
        // behaviour for events other people are also attending.
        #expect(state.upcomingMeetings.contains { $0.id == "evt-1" })
    }

    @Test("show-all restores everything at once")
    func restoreAll() {
        let state = state()
        state.dismissMeeting(id: "evt-1")
        state.dismissMeeting(id: "evt-2")
        #expect(state.dismissedMeetings.count == 2)

        state.restoreAllMeetings()
        #expect(state.dismissedMeetings.isEmpty)
        #expect(state.focusItems.filter { $0.meetingID != nil }.count == 2)
    }

    @Test("dismissal survives a relaunch")
    func dismissalPersists() {
        let state = state()
        state.dismissMeeting(id: "evt-1")

        // The calendar is polled constantly; a dismissal that did not persist
        // would reappear on the next refresh.
        let relaunched = AppState(llm: MockLLMGateway(response: "unused"))
        relaunched.upcomingMeetings = state.upcomingMeetings
        relaunched.loadDismissedMeetings()
        #expect(relaunched.dismissedMeetingIDs.contains("evt-1"))

        relaunched.restoreAllMeetings()
    }

    @Test("an empty id is ignored rather than hiding an unnamed row")
    func ignoresEmptyID() {
        let state = state()
        state.dismissMeeting(id: "")
        #expect(state.dismissedMeetingIDs.isEmpty)
    }

    // MARK: - Undoing a misclick

    /// Stands in for what applyMeetingContext writes, without a network call.
    private func applyContext(to state: AppState, id: String, title: String) {
        state.beginAppliedMeetingContextForTesting(
            meetingID: id, contextFileName: "Calendar · \(title)")
        state.contextFiles.append(ImportedContextFile(name: "Calendar · \(title)", text: "agenda"))
        state.meetingTitle = title
    }

    @Test("undo restores every field the tap rewrote")
    func undoRestoresWorkspace() {
        let state = state()
        state.meetingTitle = "My own title"
        state.callGoal = "Close the renewal"

        applyContext(to: state, id: "evt-1", title: "Pricing review")
        #expect(state.meetingTitle == "Pricing review")
        #expect(state.contextFiles.contains { $0.name == "Calendar · Pricing review" })

        state.undoMeetingContext()

        // Not just the context file — the title, goal and attendee count too.
        #expect(state.meetingTitle == "My own title")
        #expect(state.callGoal == "Close the renewal")
        #expect(!state.contextFiles.contains { $0.name == "Calendar · Pricing review" })
        #expect(state.appliedMeetingContext == nil)
    }

    @Test("undo also hides the meeting — a misclick means 'not this one'")
    func undoDismisses() {
        let state = state()
        applyContext(to: state, id: "evt-1", title: "Pricing review")
        state.undoMeetingContext()
        #expect(state.dismissedMeetingIDs.contains("evt-1"))
        state.restoreAllMeetings()
    }

    @Test("undo can leave the meeting visible when asked")
    func undoWithoutDismissing() {
        let state = state()
        applyContext(to: state, id: "evt-1", title: "Pricing review")
        state.undoMeetingContext(dismissing: false)
        #expect(!state.dismissedMeetingIDs.contains("evt-1"))
    }

    @Test("keeping the context retires the banner without reverting")
    func keepDoesNotRevert() {
        let state = state()
        applyContext(to: state, id: "evt-1", title: "Pricing review")
        state.forgetAppliedMeetingContext()

        #expect(state.appliedMeetingContext == nil)
        #expect(state.meetingTitle == "Pricing review")
        #expect(state.contextFiles.contains { $0.name == "Calendar · Pricing review" })
    }

    @Test("undo with nothing applied is harmless")
    func undoWithoutApply() {
        let state = state()
        state.meetingTitle = "Untouched"
        state.undoMeetingContext()
        #expect(state.meetingTitle == "Untouched")
    }
}
