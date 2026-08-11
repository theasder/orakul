import Foundation
import Testing
@testable import MeetGPT

/// F3: the weekly digest, assembled locally, per audience.
///
/// Mined pains: "I spend more time maintaining our PM tool than doing product
/// work"; "people still just ask what's blocked? in Slack"; and on the other
/// side, the leakage horror stories ("it automatically emailed me the
/// transcript") — which is why this produces TEXT and nothing else. There is
/// no send path here on purpose: the user copies it into whichever channel
/// they choose, and Cruxwing never mails anything on its own.
@Suite("Weekly digest")
struct WeeklyDigestTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(title: String, daysAgo: Double, digest: String,
                         items: [(String, String?, String?)] = []) -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(
            id: UUID(), title: title, startedAt: started, savedAt: started, goal: "",
            entries: [], aiResponse: "", digest: digest,
            followUp: items.isEmpty ? nil : SavedFollowUp(
                goalType: "planning", label: "Follow-up", efficiencyScore: 0.6,
                actionItems: items.map {
                    SavedActionItem(title: $0.0, owner: $0.1, due: $0.2, ask: nil,
                                    score: $0.1 == nil ? 0.3 : 0.9,
                                    missing: $0.1 == nil ? ["owner"] : [])
                }))
    }

    private func populated() throws -> SessionStore {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to sunset the legacy API in June.\n\nTeam lunch moves to Thursdays.",
                               items: [("Draft the migration plan", "Priya", "Friday"),
                                       ("Collect pricing feedback", nil, nil)]))
        try store.save(session(title: "Hiring pipeline", daysAgo: 4,
                               digest: "Agreed to hire two senior backend engineers this quarter.",
                               items: [("Post the backend role", "Sam", "Monday")]))
        // Outside the window — must not appear anywhere.
        try store.save(session(title: "Ancient history", daysAgo: 40,
                               digest: "Decided to cancel the Berlin offsite.",
                               items: [("Refund the deposits", "Ana", nil)]))
        return store
    }

    @Test("only meetings inside the window are summarised")
    func windowRespected() throws {
        let digest = WeeklyDigest.build(audience: .team, store: try populated(), now: Date())
        #expect(digest.contains("Pricing sync"))
        #expect(!digest.contains("Ancient history"))
        #expect(!digest.contains("Berlin offsite"))
    }

    @Test("the team digest names owners and shows the unowned work")
    func teamAudience() throws {
        let digest = WeeklyDigest.build(audience: .team, store: try populated(), now: Date())
        #expect(digest.contains("Draft the migration plan"))
        #expect(digest.contains("Priya"))
        #expect(digest.contains("Collect pricing feedback"))
        #expect(digest.contains("no owner"))
    }

    @Test("the stakeholder digest keeps only commitments someone actually owns")
    func stakeholderAudience() throws {
        let digest = WeeklyDigest.build(audience: .stakeholder, store: try populated(), now: Date())
        #expect(digest.contains("Draft the migration plan"))
        #expect(!digest.contains("Collect pricing feedback"),
                "an unowned, undated item is not a stakeholder commitment")
    }

    @Test("the investor digest carries only high-consequence decisions and no individual names")
    func investorAudience() throws {
        let digest = WeeklyDigest.build(audience: .investor, store: try populated(), now: Date())
        #expect(digest.contains("sunset the legacy API"))
        #expect(digest.contains("hire two senior backend engineers"))
        #expect(!digest.contains("Team lunch"), "housekeeping never reaches an investor update")
        #expect(!digest.contains("Priya") && !digest.contains("Sam"),
                "an investor update reports the company, not who owes what")
    }

    @Test("decisions are consequence-ordered, and housekeeping is dropped for every audience")
    func decisionsRanked() throws {
        let store = try populated()
        let digest = WeeklyDigest.build(audience: .team, store: store, now: Date())
        let sunset = try #require(digest.range(of: "sunset the legacy API"))
        let hiring = try #require(digest.range(of: "hire two senior backend engineers"))
        #expect(sunset.lowerBound < hiring.lowerBound,
                "an irreversible sunset outranks a hiring plan")
        // "Team lunch moves to Thursdays" is a real digest paragraph and still
        // must not be listed as a decision of the week — for anyone.
        for audience in WeeklyDigest.Audience.allCases {
            #expect(!WeeklyDigest.build(audience: audience, store: store, now: Date())
                        .contains("Team lunch"),
                    "\(audience.rawValue) digest must not carry housekeeping")
        }
    }

    @Test("a repeated promise is surfaced to the team, and only to the team")
    func repeatPromisesTeamOnly() throws {
        let store = try scratchStore()
        for day in [3.0, 10.0] {
            try store.save(session(title: "Sync \(day)", daysAgo: day,
                                   digest: "Status only.",
                                   items: [("Send the security questionnaire", "Sam", nil)]))
        }
        let team = WeeklyDigest.build(audience: .team, store: store, now: Date())
        #expect(team.contains("Promised") && team.contains("security questionnaire"))
        let investor = WeeklyDigest.build(audience: .investor, store: store, now: Date())
        #expect(!investor.contains("Promised"))
    }

    @Test("a heavy week stays readable and says what it left out")
    func heavyWeekIsBounded() throws {
        // The feature exists because nobody reads the wall of text. A digest
        // that reprints forty commitments and a full meeting summary per line
        // recreates exactly that artefact in a different window.
        let store = try scratchStore()
        let longParagraph = "Decided to sunset the legacy API in June. "
            + String(repeating: "Then somebody said more about the migration. ", count: 60)
        for day in 1...6 {
            try store.save(session(title: "Sync \(day)", daysAgo: Double(day),
                                   digest: longParagraph,
                                   items: (1...9).map { ("Commitment \(day)-\($0)", "Ana", "Friday") }))
        }

        let digest = WeeklyDigest.build(audience: .team, store: store, now: Date())
        for line in digest.split(separator: "\n") {
            #expect(line.count < 400, "a digest line ran to \(line.count) characters: \(line.prefix(80))…")
        }
        #expect(digest.contains("…and"), "a truncated list must admit it is truncated")
        #expect(digest.contains("…"), "a clipped line is marked, never left reading as a full sentence")
    }

    @Test("clipping never cuts mid-word")
    func clipsAtWordBoundary() throws {
        let store = try scratchStore()
        try store.save(session(title: "Sync", daysAgo: 1,
                               digest: "Decided to " + String(repeating: "migrate everything ", count: 40)))
        let digest = WeeklyDigest.build(audience: .team, store: store, now: Date())
        let decisionLine = try #require(digest.split(separator: "\n").first { $0.hasPrefix("- Decided") })
        #expect(decisionLine.hasSuffix("…") || decisionLine.contains("…"))
        #expect(!decisionLine.contains("migr…"), "clip at a space, not through a word")
    }

    @Test("an empty week produces an honest short note, not a fabricated summary")
    func emptyWeek() throws {
        let digest = WeeklyDigest.build(audience: .team, store: try scratchStore(), now: Date())
        #expect(digest.contains("No meetings"))
        #expect(!digest.contains("## Decisions"))
    }
}
