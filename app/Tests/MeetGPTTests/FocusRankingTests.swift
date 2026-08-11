import Foundation
import Testing
@testable import MeetGPT

/// What the Focus panel shows, and in what order.
///
/// Existing suites cover the in-progress case and dismissal. These layer the
/// dimensions underneath that: which meetings qualify at all, how they order
/// against each other, how many survive the cap, and how the time until one is
/// phrased.
///
/// It matters because Focus is the panel a user glances at once. Showing a
/// meeting three hours out is noise; showing them in the wrong order buries the
/// one starting in five minutes under one starting in ninety.
@Suite("Focus ranking")
struct FocusRankingTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(_ id: String, inMinutes: Double,
                         title: String? = nil, lasting: Double = 30) -> UpcomingMeeting {
        let start = now.addingTimeInterval(inMinutes * 60)
        return UpcomingMeeting(id: id, title: title ?? "Meeting \(id)",
                               start: start, end: start.addingTimeInterval(lasting * 60))
    }

    private func rank(_ meetings: [UpcomingMeeting], alert: String? = nil) -> [FocusItem] {
        FocusRanking.rank(meetings: meetings, alert: alert, now: now)
    }

    // MARK: - Base

    @Test("an upcoming meeting inside the horizon becomes a Focus row")
    func surfacesAnUpcomingMeeting() {
        let items = rank([meeting("a", inMinutes: 15)])
        #expect(items.count == 1)
        #expect(items[0].meetingID == "a")
        #expect(items[0].kind == .reminder)
        #expect(items[0].detail == "in 15 min")
    }

    // MARK: - Layer: which meetings qualify

    @Test("a meeting beyond the horizon is not focus material")
    func excludesDistantMeetings() {
        // Two hours is the line. A meeting later today is a calendar's job,
        // not a panel the user glances at now.
        #expect(rank([meeting("far", inMinutes: FocusRanking.meetingHorizonMinutes + 1)]).isEmpty)
        #expect(rank([meeting("edge", inMinutes: FocusRanking.meetingHorizonMinutes)]).count == 1)
    }

    @Test("a finished meeting is not surfaced")
    func excludesPastMeetings() {
        // Started an hour ago and already over: neither upcoming nor underway.
        let over = UpcomingMeeting(id: "old", title: "Earlier standup",
                                   start: now.addingTimeInterval(-3_600),
                                   end: now.addingTimeInterval(-1_800))
        #expect(rank([over]).isEmpty)
    }

    @Test("an event with no timed end is never treated as underway")
    func untimedEventsAreNotInProgress() {
        // An all-day or open-ended event that has "started" would otherwise
        // sit at the top of Focus forever.
        let openEnded = UpcomingMeeting(id: "allday", title: "Focus block",
                                        start: now.addingTimeInterval(-600), end: nil)
        #expect(rank([openEnded]).isEmpty)
    }

    // MARK: - Layer: ordering

    @Test("the sooner meeting outranks the later one")
    func soonerRanksHigher() {
        let items = rank([meeting("later", inMinutes: 90), meeting("soon", inMinutes: 5)])
        #expect(items.map(\.meetingID) == ["soon", "later"])
        #expect(items[0].score > items[1].score)
    }

    @Test("an alert outranks every meeting, however imminent")
    func alertsComeFirst() {
        let items = rank([meeting("imminent", inMinutes: 1)], alert: "Microphone permission denied")
        #expect(items.first?.kind == .alert)
        #expect(items.first?.detail == "Microphone permission denied")
    }

    @Test("a blank alert is not an alert")
    func blankAlertsAreIgnored() {
        // An empty string reaching this from cleared error state must not
        // occupy the top row with nothing in it.
        for alert in ["", "   ", "\n"] {
            #expect(rank([meeting("a", inMinutes: 10)], alert: alert).allSatisfy { $0.kind != .alert },
                    "blank alert \(alert.debugDescription) produced a row")
        }
    }

    @Test("an underway meeting outranks upcoming ones but not an alert")
    func inProgressSitsBetween() {
        let underway = UpcomingMeeting(id: "now", title: "Live call",
                                       start: now.addingTimeInterval(-300),
                                       end: now.addingTimeInterval(1_800))
        let items = rank([meeting("soon", inMinutes: 2), underway], alert: "Something broke")
        #expect(items.map(\.kind) == [.alert, .reminder, .reminder])
        #expect(items[1].meetingID == "now")
    }

    // MARK: - Layer: the cap

    @Test("the panel never shows more than its cap, keeping the highest ranked")
    func capsTheList() {
        // Ten meetings in the next two hours is a real calendar. The panel must
        // stay glanceable and keep the most imminent.
        let many = (1...10).map { meeting("m\($0)", inMinutes: Double($0) * 5) }
        let items = rank(many, alert: "Attention")
        #expect(items.count == FocusRanking.maxItems)
        #expect(items[0].kind == .alert)
        // Of the meetings that survived, the earliest ones are kept.
        #expect(items.dropFirst().map(\.meetingID) == ["m1", "m2", "m3", "m4"])
    }

    // MARK: - Layer: how the time is phrased

    @Test("relative start reads naturally across every branch")
    func relativeStartFormatting() {
        #expect(FocusRanking.relativeStart(minutes: 0) == "starting now")
        #expect(FocusRanking.relativeStart(minutes: -5) == "starting now")
        #expect(FocusRanking.relativeStart(minutes: 1) == "in 1 min")
        #expect(FocusRanking.relativeStart(minutes: 59) == "in 59 min")
        #expect(FocusRanking.relativeStart(minutes: 60) == "in 1 hr")
        #expect(FocusRanking.relativeStart(minutes: 90) == "in 1 hr 30 min")
        #expect(FocusRanking.relativeStart(minutes: 120) == "in 2 hr")
    }

    @Test("fractional minutes round rather than truncate toward zero")
    func relativeStartRounds() {
        // 29.6 minutes away is "in 30 min", not "in 29 min" — truncating makes
        // every row read a minute optimistic.
        #expect(FocusRanking.relativeStart(minutes: 29.6) == "in 30 min")
        #expect(FocusRanking.relativeStart(minutes: 0.4) == "starting now")
    }

    @Test("an underway meeting says how long ago it started")
    func inProgressPhrasing() {
        let justStarted = UpcomingMeeting(id: "a", title: "Call",
                                          start: now.addingTimeInterval(-30),
                                          end: now.addingTimeInterval(1_800))
        #expect(rank([justStarted])[0].detail == "in progress — just started")

        let older = UpcomingMeeting(id: "b", title: "Call",
                                    start: now.addingTimeInterval(-12 * 60),
                                    end: now.addingTimeInterval(1_800))
        #expect(rank([older])[0].detail == "in progress — started 12 min ago")
    }

    // MARK: - Layer: rows carry what the UI needs to act

    @Test("a reminder is actionable only once it knows which meeting it is")
    func actionability() throws {
        // The rule is "reminders are informational; everything else can be
        // acted on" — an alert row IS tappable, it takes you to the problem.
        // A reminder is different: acting on it loads that event's title,
        // agenda and attendees into the call context, which needs the id.
        let items = rank([meeting("a", inMinutes: 10)], alert: "Something broke")
        let alert = try #require(items.first { $0.kind == .alert })
        let reminder = try #require(items.first { $0.kind == .reminder })
        #expect(alert.isActionable, "an alert must be tappable — it leads somewhere")
        #expect(reminder.isActionable)
        #expect(reminder.meetingID == "a")

        // The case that keeps the rule honest: a reminder with nothing behind
        // it must not offer an action that cannot do anything.
        let anonymous = FocusItem(id: "x", kind: .reminder, title: "A meeting",
                                  detail: "in 10 min", score: 1, suggestionID: nil)
        #expect(!anonymous.isActionable)
    }

    @Test("ranking is stable: the same input yields the same order every time")
    func rankingIsDeterministic() {
        // Two meetings at the same moment must not swap between refreshes —
        // the panel would visibly flicker.
        let pair = [meeting("a", inMinutes: 10), meeting("b", inMinutes: 10)]
        let first = rank(pair).map(\.id)
        for _ in 0..<5 { #expect(rank(pair).map(\.id) == first) }
    }

    @Test("no meetings and no alert is an empty panel, not a placeholder row")
    func emptyInputIsEmpty() {
        #expect(rank([]).isEmpty)
        #expect(rank([], alert: nil).isEmpty)
    }
}
