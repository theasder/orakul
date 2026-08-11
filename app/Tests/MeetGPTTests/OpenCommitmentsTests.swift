import Foundation
import Testing
@testable import MeetGPT

/// F2 (carry-over half): the commitments already on this Mac, read back.
///
/// Mined pains: "every meeting in my calendar will produce at least 2 follow up
/// items that I have no idea how I'll find the time for"; "19 of 31 flagged
/// action items completed". Nothing here asks a model anything — the follow-up
/// records saved with each session already say who promised what, and a
/// promise repeated across meetings is the strongest available evidence that
/// it never got done.
@Suite("Open commitments")
struct OpenCommitmentsTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("commitments-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(title: String, daysAgo: Double,
                         items: [(String, String?, String?)]) -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(
            id: UUID(), title: title, startedAt: started, savedAt: started, goal: "",
            entries: [], aiResponse: "", digest: "",
            followUp: SavedFollowUp(
                goalType: "planning", label: "Follow-up", efficiencyScore: 0.5,
                actionItems: items.map {
                    SavedActionItem(title: $0.0, owner: $0.1, due: $0.2, ask: nil,
                                    score: $0.1 == nil ? 0.3 : 0.8,
                                    missing: $0.1 == nil ? ["owner"] : [])
                }))
    }

    private let embedder = HashingSkillTextEmbedder()

    @Test("commitments are read back with the meeting that produced them")
    func commitmentsCarryProvenance() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 5,
                               items: [("Draft the pricing one-pager", "Priya", "Friday")]))
        let all = OpenCommitments.all(store: store)
        let first = try #require(all.first)
        #expect(first.title == "Draft the pricing one-pager")
        #expect(first.owner == "Priya")
        #expect(first.sessionTitle == "Pricing sync")
    }

    @Test("a promise repeated across meetings is reported with its count and first date")
    func repeatedPromisesDetected() throws {
        let store = try scratchStore()
        try store.save(session(title: "Sync week 1", daysAgo: 21,
                               items: [("Send the security questionnaire", "Sam", nil)]))
        try store.save(session(title: "Sync week 2", daysAgo: 14,
                               items: [("send the Security questionnaire.", "Sam", nil)]))
        try store.save(session(title: "Sync week 3", daysAgo: 7,
                               items: [("Send the security questionnaire", nil, nil),
                                       ("Book the venue", "Ana", "Monday")]))

        let repeats = OpenCommitments.repeatedPromises(store: store)
        let questionnaire = try #require(repeats.first)
        #expect(questionnaire.count == 3, "punctuation and casing must not split one promise into three")
        #expect(questionnaire.firstPromisedAt < questionnaire.lastPromisedAt)
        #expect(repeats.contains { $0.title.lowercased().contains("venue") } == false,
                "a commitment made once is not a broken promise")
    }

    @Test("repeats are ordered by how many times the promise was made")
    func repeatsOrderedByCount() throws {
        let store = try scratchStore()
        for day in [30.0, 20.0, 10.0] {
            try store.save(session(title: "Sync \(day)", daysAgo: day,
                                   items: [("Ship the migration plan", "Lee", nil)]))
        }
        for day in [25.0, 15.0] {
            try store.save(session(title: "Other \(day)", daysAgo: day,
                                   items: [("Renew the vendor contract", "Ana", nil)]))
        }
        let repeats = OpenCommitments.repeatedPromises(store: store)
        #expect(repeats.first?.title.lowercased().contains("migration") == true)
        #expect(repeats.count == 2)
    }

    @Test("a session without follow-up records contributes nothing, not a crash")
    func sessionsWithoutFollowUp() throws {
        let store = try scratchStore()
        try store.save(SavedSession(id: UUID(), title: "Chat", startedAt: Date(),
                                    savedAt: Date(), goal: "", entries: [],
                                    aiResponse: "", digest: "no follow-up here"))
        #expect(OpenCommitments.all(store: store).isEmpty)
        #expect(OpenCommitments.repeatedPromises(store: store).isEmpty)
    }

    // MARK: brief carry-over

    private func upcoming(title: String) -> UpcomingMeeting {
        UpcomingMeeting(id: "evt-2", title: title, start: Date().addingTimeInterval(1800))
    }

    @Test("the brief carries the open commitments from this meeting's own history")
    func briefCarryOverSources() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 7,
                               items: [("Draft the pricing one-pager", "Priya", "Friday"),
                                       ("Collect competitor pricing", nil, nil)]))
        try store.save(session(title: "Design review", daysAgo: 3,
                               items: [("Rework the empty state", "Ana", nil)]))

        let sources = BriefRecallSources.commitments(for: upcoming(title: "Pricing sync"),
                                                      store: store, embedder: embedder)
        let joined = sources.map(\.text).joined(separator: "\n")
        #expect(joined.contains("Draft the pricing one-pager"))
        #expect(joined.contains("Priya"))
        #expect(joined.contains("no owner"), "an ownerless carry-over must say so — that is the point")
        #expect(!joined.contains("Rework the empty state"),
                "another meeting's commitments must not leak into this brief")
    }

    @Test("title matching identifies a recurring thread without merging unrelated ones")
    func titleMatching() {
        #expect(OpenCommitments.titlesMatch("Pricing sync", "Pricing sync follow-up"))
        #expect(OpenCommitments.titlesMatch("Weekly product sync", "Product sync"))
        #expect(OpenCommitments.titlesMatch("Acme <> Cruxwing call", "Acme <> Cruxwing"))
        // Calendar filler alone must never make two meetings the same thread.
        #expect(!OpenCommitments.titlesMatch("Weekly sync", "Daily standup meeting"))
        #expect(!OpenCommitments.titlesMatch("Pricing sync", "Design review"))
        #expect(!OpenCommitments.titlesMatch("", "Pricing sync"))
    }

    @Test("a promise this thread keeps re-making leads the brief, with its count")
    func repeatedPromiseReachesBrief() throws {
        let store = try scratchStore()
        for day in [21.0, 14.0, 7.0] {
            try store.save(session(title: "Pricing sync", daysAgo: day,
                                   items: [("Send the pricing model to finance", "Sam", nil)]))
        }
        // A different thread's repeat must not follow the user into this room.
        for day in [20.0, 10.0] {
            try store.save(session(title: "Design review", daysAgo: day,
                                   items: [("Rework the empty state", "Ana", nil)]))
        }

        let sources = BriefRecallSources.repeatedPromises(for: upcoming(title: "Pricing sync"),
                                                          store: store)
        let joined = sources.map(\.text).joined(separator: "\n")
        #expect(joined.contains("STILL OPEN"))
        #expect(joined.contains("promised 3×"))
        #expect(joined.contains("Send the pricing model to finance"))
        #expect(!joined.contains("Rework the empty state"),
                "another thread's unfinished work would make the brief a nag list")
    }

    @Test("a first-time commitment never appears as still open")
    func singlePromiseIsNotOverdue() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 3,
                               items: [("Draft the pricing one-pager", "Priya", "Friday")]))
        #expect(BriefRecallSources.repeatedPromises(for: upcoming(title: "Pricing sync"),
                                                    store: store).isEmpty)
    }

    @Test("no matching history means no carry-over block at all")
    func briefCarryOverEmpty() throws {
        let store = try scratchStore()
        try store.save(session(title: "Hiring pipeline", daysAgo: 3,
                               items: [("Post the backend role", "Sam", nil)]))
        #expect(BriefRecallSources.commitments(for: upcoming(title: "Kubernetes ceremony"),
                                               store: store, embedder: embedder).isEmpty)
    }
}
