import Foundation
import Testing
@testable import MeetGPT

/// Launching the app AFTER a calendar event started must still recognize the
/// event as the current call: the parser keeps in-progress events, and the
/// Focus panel ranks them above everything except an active alert.
@Suite("In-progress meeting recognition")
struct InProgressMeetingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func eventsJSON(_ events: [(id: String, start: Date, end: Date?)]) -> Data {
        let items = events.map { event -> [String: Any] in
            var dict: [String: Any] = [
                "id": event.id,
                "summary": "Event \(event.id)",
                "start": ["dateTime": rfc3339(event.start)],
            ]
            if let end = event.end {
                dict["end"] = ["dateTime": rfc3339(end)]
            }
            return dict
        }
        return try! JSONSerialization.data(withJSONObject: ["items": items])
    }

    @Test("parser keeps in-progress and future events, drops finished ones")
    func parserKeepsInProgress() {
        let data = eventsJSON([
            ("finished", now.addingTimeInterval(-3600), now.addingTimeInterval(-600)),
            ("current", now.addingTimeInterval(-600), now.addingTimeInterval(3000)),
            ("future", now.addingTimeInterval(1800), now.addingTimeInterval(5400)),
        ])
        let meetings = CalendarService.parseUpcoming(data, after: now)
        #expect(meetings.map(\.id) == ["current", "future"])
        #expect(meetings[0].isInProgress(at: now))
        #expect(!meetings[1].isInProgress(at: now))
        #expect(meetings[0].end == now.addingTimeInterval(3000))
    }

    @Test("a started event with no timed end is never 'in progress'")
    func endlessEventIsNotInProgress() {
        let started = UpcomingMeeting(id: "x", title: "X",
                                      start: now.addingTimeInterval(-300))
        #expect(!started.isInProgress(at: now))
        // and the parser drops a started event without an end (can't verify
        // it is still underway)
        let data = eventsJSON([("started-endless", now.addingTimeInterval(-300), nil)])
        #expect(CalendarService.parseUpcoming(data, after: now).isEmpty)
    }

    @Test("Focus ranks the in-progress call above upcoming meetings, below alerts")
    func focusRanksCurrentCallFirst() {
        let current = UpcomingMeeting(id: "cur", title: "Weekly sync",
                                      start: now.addingTimeInterval(-720),
                                      end: now.addingTimeInterval(1800))
        let soon = UpcomingMeeting(id: "soon", title: "Next call",
                                   start: now.addingTimeInterval(300),
                                   end: now.addingTimeInterval(3900))

        let items = FocusRanking.rank(meetings: [soon, current], alert: nil, now: now)
        #expect(items.first?.id == "meeting-cur")
        #expect(items.first?.detail.contains("in progress") == true)
        #expect(items.first?.detail.contains("12 min ago") == true)

        let withAlert = FocusRanking.rank(meetings: [current], alert: "Mic denied", now: now)
        #expect(withAlert.first?.kind == .alert)
        #expect(withAlert.dropFirst().first?.id == "meeting-cur")
    }
}

/// Picking a meeting in Focus loads THAT event's context (title, agenda,
/// attendees) rather than whatever the calendar thinks is nearest in time.
/// Before this, meeting rows were `kind: .reminder` with no payload, so
/// `isActionable` was false and the tap did nothing.
@Suite("Focus meeting rows are actionable")
struct FocusMeetingActionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meetings() -> [UpcomingMeeting] {
        [
            UpcomingMeeting(id: "evt-live", title: "Pricing review",
                            start: now.addingTimeInterval(-300),
                            end: now.addingTimeInterval(1500)),
            UpcomingMeeting(id: "evt-soon", title: "Board prep",
                            start: now.addingTimeInterval(900),
                            end: now.addingTimeInterval(3300)),
        ]
    }

    @Test("a meeting row carries its event id and is actionable")
    func meetingRowsCarryEventID() {
        let items = FocusRanking.rank(meetings: meetings(), alert: nil, now: now)
        let rows = items.filter { $0.kind == .reminder }
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.meetingID != nil, "\(row.title) has nothing to act on")
            #expect(row.isActionable)
        }
        #expect(rows.contains { $0.meetingID == "evt-live" })
        #expect(rows.contains { $0.meetingID == "evt-soon" })
    }

    @Test("a reminder without an event id stays informational")
    func reminderWithoutIDIsInert() {
        let bare = FocusItem(id: "x", kind: .reminder, title: "Something",
                             detail: "", score: 1, suggestionID: nil)
        #expect(bare.meetingID == nil)
        #expect(!bare.isActionable)
    }

    /// The single-event endpoint returns the event object directly — no `items`
    /// wrapper — so it needs its own parse path.
    @Test("parseEvent reads title, agenda and attendees from one event")
    func parseSingleEvent() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "evt-live",
            "summary": "Pricing review",
            "description": "Decide tier names\nAgree the discount ladder",
            "attendees": [["email": "a@example.com"], ["email": "b@example.com"]],
        ])
        let agenda = try CalendarService.parseEvent(json)
        #expect(agenda.title == "Pricing review")
        #expect(agenda.attendeeCount == 2)
        #expect(agenda.summary.contains("Decide tier names"))
        #expect(agenda.summary.contains("a@example.com"))
    }

    @Test("parseEvent rejects a payload that is not an event")
    func parseSingleEventRejectsGarbage() {
        let json = try! JSONSerialization.data(withJSONObject: ["error": "not found"])
        #expect(throws: (any Error).self) { try CalendarService.parseEvent(json) }
    }
}
