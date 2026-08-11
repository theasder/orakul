import Foundation
import Testing
@testable import MeetGPT

/// The brief arrives from `POST /api/brief`, which deliberately never fails: out
/// of credits, past the daily cap, or with the model down it still returns 200
/// carrying the free ledger half and a `degraded` reason. So the client has to
/// render a partial brief as a normal outcome rather than an error state — a
/// panel that shows nothing because `degraded` was set would throw away the one
/// thing that was always going to work.
@Suite("Meeting brief decoding and rendering")
struct MeetingBriefTests {
    private func decode(_ json: String) throws -> BriefResponse {
        try JSONDecoder().decode(BriefResponse.self, from: Data(json.utf8))
    }

    @Test("decodes a full brief")
    func decodesFull() throws {
        let decoded = try decode("""
        {"brief":{"headline":"Renewal call",
                  "points":[{"text":"Close date slipped","source":"hubspot","readFor":"an unacknowledged slip"}],
                  "openFromLastTime":[{"text":"You owed them the SOC 2 letter","overdue":true,"via":"participant"}],
                  "suggestedGoal":{"goalType":"close_deal","confidence":0.7}},
         "cached":false,"generatedAt":"2026-07-31T10:00:00Z"}
        """)
        #expect(decoded.brief.headline == "Renewal call")
        #expect(decoded.brief.points.count == 1)
        #expect(decoded.brief.points.first?.readFor == "an unacknowledged slip")
        #expect(decoded.brief.openFromLastTime.first?.overdue == true)
        #expect(decoded.brief.suggestedGoal?.goalType == "close_deal")
        #expect(decoded.degraded == nil)
    }

    @Test("decodes the degraded ledger-only brief the server sends when credits run out")
    func decodesDegraded() throws {
        // The server's contract: 200, free half present, reason attached. Missing
        // keys are the norm here, not an error.
        let decoded = try decode("""
        {"brief":{"headline":"Still open from last time","points":[],
                  "openFromLastTime":[{"text":"Send the quote","overdue":false,"via":"company"}],
                  "suggestedGoal":null},
         "cached":false,"degraded":"credits","upgrade":true}
        """)
        #expect(decoded.degraded == "credits")
        #expect(decoded.upgrade == true)
        #expect(decoded.brief.points.isEmpty)
        #expect(decoded.brief.openFromLastTime.count == 1)
    }

    @Test("survives a brief with every optional field absent")
    func decodesMinimal() throws {
        // A Swift struct whose non-optional properties carry defaults still needs
        // those keys unless decoding fills them — the exact shape that has broken
        // persisted decoding in this app before.
        let decoded = try decode(#"{"brief":{"headline":"Nothing outstanding"},"cached":true}"#)
        #expect(decoded.brief.points.isEmpty)
        #expect(decoded.brief.openFromLastTime.isEmpty)
        #expect(decoded.brief.suggestedGoal == nil)
        #expect(decoded.cached == true)
    }

    @Test("renders overdue commitments before points, and marks them")
    func rendersOverdueFirst() {
        // An overdue commitment is the only line that is a problem rather than
        // context. It leads regardless of what the model produced.
        let brief = MeetingBrief(
            headline: "Renewal call",
            points: [.init(text: "Pricing came up twice", source: "hubspot", readFor: nil)],
            openFromLastTime: [.init(text: "Send the SOC 2 letter", overdue: true, via: "participant")],
            suggestedGoal: nil)
        let lines = brief.focusLines
        #expect(lines.first?.text == "Send the SOC 2 letter")
        #expect(lines.first?.isOverdue == true)
        #expect(lines.last?.text == "Pricing came up twice")
    }

    @Test("a brief with no content renders no lines rather than an empty shell")
    func rendersNothingWhenEmpty() {
        // The panel must not grow a blank disclosure for a meeting we know
        // nothing about.
        let brief = MeetingBrief(headline: "Nothing outstanding", points: [],
                                 openFromLastTime: [], suggestedGoal: nil)
        #expect(brief.focusLines.isEmpty)
        #expect(brief.hasContent == false)
    }

    @Test("line count is bounded")
    func bounded() {
        // Three points plus two commitments is already at the edge of what
        // someone reads in the ten minutes before a call.
        let brief = MeetingBrief(
            headline: "x",
            points: (0..<8).map { .init(text: "p\($0)", source: "s", readFor: nil) },
            openFromLastTime: (0..<8).map { .init(text: "o\($0)", overdue: false, via: "company") },
            suggestedGoal: nil)
        #expect(brief.focusLines.count == MeetingBrief.maxFocusLines)
    }

    @Test("attributes each line to where it came from")
    func attributes() {
        // A line with no provenance reads as an assertion by the app. "hubspot"
        // and "your last call" are different kinds of claim.
        let brief = MeetingBrief(
            headline: "x",
            points: [.init(text: "Deal stage moved", source: "hubspot", readFor: nil)],
            openFromLastTime: [.init(text: "Owed letter", overdue: false, via: "participant")],
            suggestedGoal: nil)
        let lines = brief.focusLines
        #expect(lines.first?.source == "your last call")
        #expect(lines.last?.source == "hubspot")
    }
}

@Suite("Which meeting gets a brief")
struct BriefTargetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, minutes: Double) -> UpcomingMeeting {
        UpcomingMeeting(id: id, title: id, start: now.addingTimeInterval(minutes * 60),
                        end: now.addingTimeInterval((minutes + 30) * 60),
                        attendees: ["buyer@acme.com"])
    }

    @Test("picks the soonest meeting inside the lead window")
    func picksSoonest() {
        let target = BriefTarget.next(in: [meeting("later", minutes: 25),
                                           meeting("soon", minutes: 8)],
                                      now: now, briefed: [])
        #expect(target?.id == "soon")
    }

    @Test("ignores meetings further out than the lead window")
    func ignoresDistant() {
        // Briefing a meeting three hours out wastes a call on facts that will
        // have changed, and burns one of the day's capped briefs.
        #expect(BriefTarget.next(in: [meeting("far", minutes: 180)], now: now, briefed: []) == nil)
    }

    @Test("does not re-request a meeting already briefed")
    func skipsBriefed() {
        // The server caches within its TTL and would answer free, but the round
        // trip is still latency on a panel that is already showing the answer.
        #expect(BriefTarget.next(in: [meeting("soon", minutes: 8)],
                                 now: now, briefed: ["soon"]) == nil)
    }

    @Test("skips a meeting with no attendees — there is nobody to look up")
    func skipsSolo() {
        let solo = UpcomingMeeting(id: "focus", title: "Focus block",
                                   start: now.addingTimeInterval(600), end: nil,
                                   attendees: [])
        #expect(BriefTarget.next(in: [solo], now: now, briefed: []) == nil)
    }

    @Test("still briefs a meeting already underway")
    func briefsInProgress() {
        // Launching the app mid-call is exactly when the user has least context.
        let started = UpcomingMeeting(id: "now", title: "Now",
                                      start: now.addingTimeInterval(-300),
                                      end: now.addingTimeInterval(1500),
                                      attendees: ["buyer@acme.com"])
        #expect(BriefTarget.next(in: [started], now: now, briefed: [])?.id == "now")
    }
}
