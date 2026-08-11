import Foundation
import Testing
@testable import MeetGPT

/// F1 from the RICE roadmap: cross-meeting decision recall. The mined pain:
/// "the part that kills me is the relitigating… nobody's sure what we landed
/// on" — answered by interrogating the sessions already on disk. Tests inject
/// the deterministic hashing embedder: recall must behave identically on a
/// machine with no NLEmbedding model, and tests must not depend on Apple's
/// embedding weights.
@Suite("Decision recall")
struct DecisionRecallTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(title: String, daysAgo: Double, digest: String,
                         transcript: [String] = [], goal: String = "") -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(
            id: UUID(), title: title, startedAt: started, savedAt: started,
            goal: goal,
            entries: transcript.map {
                TranscriptEntry(id: UUID(), source: .system, text: $0,
                                timestamp: started, speaker: nil)
            },
            aiResponse: "", digest: digest)
    }

    private let embedder = HashingSkillTextEmbedder()

    @Test("finds the meeting where a topic was decided, from the digest")
    func findsDecisionAcrossSessions() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 12,
                               digest: "Decided to move to usage-based pricing at two cents per credit. Rationale: aligns cost with heavy transcription users."))
        try store.save(session(title: "Hiring pipeline", daysAgo: 8,
                               digest: "Agreed to open two senior backend roles and pause the design hire."))
        try store.save(session(title: "Weekly standup", daysAgo: 2,
                               digest: "Status updates only, no decisions recorded."))

        let hits = DecisionRecallService.recall(query: "what did we decide about usage-based pricing",
                                                store: store, embedder: embedder)
        #expect(hits.first?.sessionTitle == "Pricing sync")
        #expect(hits.first?.excerpt.contains("usage-based pricing") == true)
    }

    @Test("every excerpt is a verbatim slice of the stored session")
    func excerptsAreVerbatim() throws {
        let store = try scratchStore()
        let digest = "Decided to sunset the legacy API in June after the enterprise migration completes."
        try store.save(session(title: "Platform review", daysAgo: 3, digest: digest))

        let hits = DecisionRecallService.recall(query: "sunset legacy API",
                                                store: store, embedder: embedder)
        let hit = try #require(hits.first)
        #expect(digest.contains(hit.excerpt) || hit.excerpt.contains("sunset the legacy API"),
                "an excerpt must be quotable back to the record, never a paraphrase")
    }

    @Test("transcript windows are searched when the digest is silent")
    func transcriptWindowsSearched() throws {
        let store = try scratchStore()
        try store.save(session(title: "Vendor call", daysAgo: 5,
                               digest: "General discussion.",
                               transcript: [
                                "So to confirm, we are renewing the Deepgram contract for twelve months.",
                                "Yes, and we revisit the on-device option at the next quarterly review.",
                               ]))

        let hits = DecisionRecallService.recall(query: "renewing the Deepgram contract",
                                                store: store, embedder: embedder)
        #expect(hits.contains { $0.excerpt.contains("renewing the Deepgram contract") })
    }

    @Test("identical relevance breaks toward the newer meeting")
    func recencyBreaksTies() throws {
        let store = try scratchStore()
        let digest = "Decided to cancel the Berlin offsite."
        try store.save(session(title: "Older", daysAgo: 30, digest: digest))
        try store.save(session(title: "Newer", daysAgo: 1, digest: digest))

        let hits = DecisionRecallService.recall(query: "cancel the Berlin offsite",
                                                store: store, embedder: embedder)
        #expect(hits.first?.sessionTitle == "Newer",
                "when the same words match equally, the later meeting is the living decision")
    }

    @Test("respects the result limit")
    func limitRespected() throws {
        let store = try scratchStore()
        for day in 1...8 {
            try store.save(session(title: "Sync \(day)", daysAgo: Double(day),
                                   digest: "Decided to cancel the Berlin offsite, option \(day)."))
        }
        let hits = DecisionRecallService.recall(query: "cancel the Berlin offsite",
                                                store: store, embedder: embedder, limit: 4)
        #expect(hits.count == 4)
    }

    @Test("an empty history returns no hits, not an error")
    func emptyStore() throws {
        let store = try scratchStore()
        let hits = DecisionRecallService.recall(query: "anything at all",
                                                store: store, embedder: embedder)
        #expect(hits.isEmpty)
    }

    @Test("an unrelated query stays silent instead of dredging noise")
    func unrelatedQueryFiltered() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let hits = DecisionRecallService.recall(query: "kubernetes ingress teardown ceremony",
                                                store: store, embedder: embedder)
        #expect(hits.isEmpty, "no shared vocabulary must mean no hits — a wrong answer here relitigates worse than none")
    }

    @Test("one long paragraph cannot smuggle a whole meeting into the prompt")
    func excerptsAreBounded() throws {
        // A digest written without blank lines is a single paragraph. Uncapped,
        // its excerpt would be quoted into every recall request — tens of
        // kilobytes of an old meeting, on the user's credits, invisibly.
        let store = try scratchStore()
        let huge = "We decided to sunset the legacy API in June. "
            + String(repeating: "Then somebody said something else about the migration. ", count: 400)
        try store.save(session(title: "Marathon", daysAgo: 2, digest: huge))

        let hit = try #require(DecisionRecallService.recall(
            query: "what did we decide about the legacy API",
            store: store, embedder: embedder).first)
        #expect(hit.excerpt.count <= DecisionRecallService.maxExcerptCharacters)
        #expect(huge.contains(hit.excerpt), "a truncated quote is still a quote — never a paraphrase")

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about the legacy API",
            store: store, embedder: embedder))
        #expect(block.count < 4 * DecisionRecallService.maxExcerptCharacters + 800,
                "the whole context block stays small enough to prepend to any request")
    }

    // MARK: ask-flow bridge

    @Test("recall intent is recognised in English and Russian, and only there")
    func intentGate() {
        for prompt in ["what did we decide about the API pricing?",
                       "did we agree on the launch date",
                       "what was decided last week about hiring",
                       "remind me what the previous meeting landed on",
                       "что мы решили про тарифы?",
                       "на прошлой встрече договорились про дедлайн?"] {
            #expect(DecisionRecallContext.matchesRecallIntent(prompt), "should match: \(prompt)")
        }
        for prompt in ["summarize this call",
                       "draft a follow-up email to the client",
                       "переведи этот текст на английский"] {
            #expect(!DecisionRecallContext.matchesRecallIntent(prompt), "should NOT match: \(prompt)")
        }
    }

    @Test("the context block quotes the record and names the meeting")
    func blockQuotesRecord() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about usage-based pricing",
            store: store, embedder: embedder))
        #expect(block.contains("Pricing sync"))
        #expect(block.contains("usage-based pricing at two cents per credit"))
        #expect(block.contains("PRIOR-MEETING RECORD"))
    }

    @Test("no block for a non-recall prompt or an empty record")
    func blockAbsentWhenNotApplicable() throws {
        let store = try scratchStore()
        #expect(DecisionRecallContext.block(for: "what did we decide about pricing",
                                            store: store, embedder: embedder) == nil,
                "empty history must add nothing to the request")
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing."))
        #expect(DecisionRecallContext.block(for: "summarize this call",
                                            store: store, embedder: embedder) == nil,
                "an ordinary prompt must not grow a recall preamble")
    }

    // MARK: discoverability

    @Test("the shipped chip actually triggers recall, rather than only naming it")
    func recallChipMatchesItsOwnGate() throws {
        // The button exists because recall was reachable only by guessing the
        // phrasing. That fix is worthless if the chip's own text misses the
        // gate — this is the test that keeps the two in step.
        let chip = try #require(QuickPrompts.all.first { $0.id == "recall" })
        #expect(DecisionRecallContext.matchesRecallIntent(chip.prompt),
                "the recall chip must match the recall intent gate it depends on")

        // And end to end: pressing it against a real store produces the record.
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 6,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let block = try #require(DecisionRecallContext.block(for: chip.prompt,
                                                             store: store, embedder: embedder))
        #expect(block.contains("Pricing sync"))
    }

    @Test("the chip refuses to invent history when the record is silent")
    func recallChipInstructsAgainstFabrication() throws {
        // The failure this feature exists to prevent is a confidently wrong
        // memory of a decision. The prompt has to say so, because the model
        // will otherwise happily reconstruct one from the live transcript.
        let chip = try #require(QuickPrompts.all.first { $0.id == "recall" })
        #expect(chip.prompt.contains("say plainly that nothing was found"))
        #expect(chip.prompt.contains("quote"))
    }

    // MARK: pre-meeting brief bridge (F8)

    private func upcoming(title: String) -> UpcomingMeeting {
        UpcomingMeeting(id: "evt-1", title: title,
                        start: Date().addingTimeInterval(1800))
    }

    @Test("a meeting's brief sources quote what prior sessions decided on its topic")
    func briefSourcesFromHistory() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 7,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        try store.save(session(title: "Design review", daysAgo: 3,
                               digest: "Agreed the onboarding redesign ships behind a flag."))

        let sources = BriefRecallSources.build(for: upcoming(title: "Pricing sync follow-up"),
                                               store: store, embedder: embedder)
        #expect(!sources.isEmpty && sources.count <= 3)
        let first = try #require(sources.first)
        #expect(first.server == BriefRecallSources.serverLabel)
        #expect(first.text.contains("Pricing sync"))
        #expect(first.text.contains("usage-based pricing"))
        #expect(first.readFor == "Pricing sync follow-up")
    }

    @Test("no history on the topic means no invented sources")
    func briefSourcesEmptyWhenIrrelevant() throws {
        let store = try scratchStore()
        try store.save(session(title: "Hiring pipeline", daysAgo: 3,
                               digest: "Agreed to open two senior backend roles."))
        let sources = BriefRecallSources.build(for: upcoming(title: "Quarterly kubernetes ceremony"),
                                               store: store, embedder: embedder)
        #expect(sources.isEmpty)
    }
}
