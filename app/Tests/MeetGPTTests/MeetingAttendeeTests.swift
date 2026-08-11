import Foundation
import Testing
@testable import MeetGPT

/// Attendee email is the join key for every source a pre-call brief draws on:
/// without it there is no way to ask a CRM "what do we know about these people"
/// or to find our own prior transcript with the same room. The parser reads
/// `attendeeCount` today and discards the addresses themselves.
///
/// Google's `attendees[]` is messier than it looks — the organizer is in it, so
/// is the user themselves, so are resource rooms with no address at all — and
/// every one of those would poison a lookup keyed on "who am I meeting".
@Suite("Calendar attendee extraction")
struct MeetingAttendeeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func event(id: String, attendees: [[String: Any]]) -> [String: Any] {
        [
            "id": id,
            "summary": "Event \(id)",
            "start": ["dateTime": rfc3339(now.addingTimeInterval(600))],
            "end": ["dateTime": rfc3339(now.addingTimeInterval(3600))],
            "attendees": attendees,
        ]
    }

    private func parse(_ events: [[String: Any]]) -> [UpcomingMeeting] {
        let data = try! JSONSerialization.data(withJSONObject: ["items": events])
        return CalendarService.parseUpcoming(data, after: now)
    }

    @Test("keeps the other side's addresses")
    func keepsCounterparties() {
        let parsed = parse([event(id: "e1", attendees: [
            ["email": "buyer@acme.com"],
            ["email": "cfo@acme.com"],
        ])])
        #expect(parsed.first?.attendees == ["buyer@acme.com", "cfo@acme.com"])
    }

    @Test("drops the user themselves — self is not someone you are meeting")
    func dropsSelf() {
        // Google marks the authenticated user's own row with `self: true`. Left
        // in, every brief would look up the user in their own CRM.
        let parsed = parse([event(id: "e1", attendees: [
            ["email": "me@cruxwing.com", "self": true],
            ["email": "buyer@acme.com"],
        ])])
        #expect(parsed.first?.attendees == ["buyer@acme.com"])
    }

    @Test("drops resources and rows with no address")
    func dropsResources() {
        // Conference rooms appear as attendees with `resource: true`. A row can
        // also carry no email at all.
        let parsed = parse([event(id: "e1", attendees: [
            ["email": "room-4@resource.calendar.google.com", "resource": true],
            ["displayName": "No address"],
            ["email": "buyer@acme.com"],
        ])])
        #expect(parsed.first?.attendees == ["buyer@acme.com"])
    }

    @Test("drops anyone who declined — they will not be in the room")
    func dropsDeclined() {
        let parsed = parse([event(id: "e1", attendees: [
            ["email": "declined@acme.com", "responseStatus": "declined"],
            ["email": "buyer@acme.com", "responseStatus": "accepted"],
            ["email": "maybe@acme.com", "responseStatus": "needsAction"],
        ])])
        // `needsAction` is kept: no answer is not a no, and they usually show up.
        #expect(parsed.first?.attendees == ["buyer@acme.com", "maybe@acme.com"])
    }

    @Test("normalizes case and deduplicates")
    func normalizes() {
        // Addresses are case-insensitive; a duplicate would double-weight one
        // person in every downstream lookup.
        let parsed = parse([event(id: "e1", attendees: [
            ["email": "Buyer@Acme.com"],
            ["email": "buyer@acme.com "],
        ])])
        #expect(parsed.first?.attendees == ["buyer@acme.com"])
    }

    @Test("an event with no attendees parses to an empty list, not a failure")
    func noAttendees() {
        // A solo focus block is still a meeting worth surfacing; it just has no
        // counterparties. This must not drop the event.
        let parsed = parse([[
            "id": "solo",
            "summary": "Фокус",
            "start": ["dateTime": rfc3339(now.addingTimeInterval(600))],
        ]])
        #expect(parsed.count == 1)
        #expect(parsed.first?.attendees.isEmpty == true)
    }

    @Test("attendee list is bounded")
    func bounded() {
        // A 200-person all-hands must not produce a 200-key lookup fan-out. The
        // cap is on the parse so nothing downstream has to remember it.
        let many = (0..<200).map { ["email": "person\($0)@acme.com"] }
        let parsed = parse([event(id: "big", attendees: many)])
        #expect(parsed.first?.attendees.count == UpcomingMeeting.maxAttendees)
    }
}
