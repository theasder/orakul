import Testing
import Foundation
@testable import MeetGPT

/// A6 — the deterministic quality gates behind the structured buttons. These
/// are the checks that make "no fabrication" enforceable instead of hoped-for.
@Suite("Artifact validator")
struct ArtifactValidatorTests {
    private let transcript = """
    [10:01:02][mic] Sam: I think we should move the pricing page to usage-based tiers.
    [10:01:40][system] Dana: Agreed — let's ship it before the Acme renewal on August 1st.
    [10:02:10][mic] Sam: I'll draft the new pricing page this week.
    """

    // MARK: Quote verification

    @Test("verbatim quotes match despite case, curly quotes, and re-wrapping")
    func quoteNormalization() {
        #expect(ArtifactValidator.quoteAppears("move the pricing page to usage-based tiers", in: transcript))
        #expect(ArtifactValidator.quoteAppears("“Let's ship it before the Acme renewal”", in: transcript))
        #expect(ArtifactValidator.quoteAppears("MOVE THE   PRICING PAGE", in: transcript))
        #expect(!ArtifactValidator.quoteAppears("we agreed to double the marketing budget", in: transcript))
    }

    @Test("owners are grounded when mentioned or flagged, not when invented")
    func ownerGrounding() {
        #expect(ArtifactValidator.ownerIsGrounded("Sam", transcript: transcript))
        #expect(ArtifactValidator.ownerIsGrounded("Dana", transcript: transcript))
        #expect(ArtifactValidator.ownerIsGrounded("[OWNER?]", transcript: transcript))
        #expect(ArtifactValidator.ownerIsGrounded(nil, transcript: transcript))
        #expect(!ArtifactValidator.ownerIsGrounded("Viktor", transcript: transcript))
    }

    // MARK: Summary gates

    @Test("summary validation catches fabricated quotes and invented owners")
    func summaryValidation() {
        let summary = SummaryArtifact(
            tldr: ["Pricing model decided", "Acme deadline set"],
            decisions: [
                .init(text: "Usage-based pricing", quote: "move the pricing page to usage-based tiers", speaker: "Sam", timestamp: nil),
                .init(text: "Fabricated one", quote: "we hired three contractors yesterday", speaker: "Dana", timestamp: nil)
            ],
            actions: [
                .init(task: "Draft pricing page", owner: "Sam", due: "this week", tracked: false),
                .init(task: "Invented owner task", owner: "Viktor", due: nil, tracked: false)
            ],
            openQuestions: nil,
            risks: nil,
            continuity: [.init(commitment: "Ship blog post", status: "abandoned")],
            parkingLot: nil, nextMeeting: nil)

        let violations = ArtifactValidator.validate(summary: summary, transcript: transcript)
        #expect(violations.count == 3)
        #expect(violations.contains { $0.field == "decisions[1].quote" })
        #expect(violations.contains { $0.field == "actions[1].owner" })
        #expect(violations.contains { $0.field == "continuity[0].status" })

        // Downgrade: quote dropped, owner cleared to OPEN, bad continuity removed.
        let fixed = ArtifactValidator.downgrade(summary: summary, transcript: transcript)
        #expect(fixed.decisions?[1].quote == nil)
        #expect(fixed.decisions?[0].quote != nil)          // verified quote kept
        #expect(fixed.actions?[1].owner == nil)
        #expect(fixed.actions?[0].owner == "Sam")
        #expect(fixed.continuity?.isEmpty == true)
        #expect(ArtifactValidator.validate(summary: fixed, transcript: transcript).isEmpty)
    }

    @Test("TL;DR contract: required, at most 3 bullets, downgrade truncates")
    func tldrGate() {
        let bloated = SummaryArtifact(tldr: ["a", "b", "c", "d"], decisions: nil, actions: nil,
                                      openQuestions: nil, risks: nil, continuity: nil,
                                      parkingLot: nil, nextMeeting: nil)
        #expect(ArtifactValidator.validate(summary: bloated, transcript: transcript)
            .contains { $0.field == "tldr" })
        #expect(ArtifactValidator.downgrade(summary: bloated, transcript: transcript).tldr.count == 3)
    }

    // MARK: Tasks gates

    @Test("tasks validation flags invented owners; downgrade flags them honestly")
    func tasksValidation() {
        let tasks = TasksArtifact(
            dacis: nil,
            items: [
                .init(task: "Draft pricing page", owner: "Sam", due: "this week",
                      doneCheck: nil, dependency: nil, sourceRef: nil, tracked: false),
                .init(task: "Update CRM", owner: "Viktor", due: "[DUE?]",
                      doneCheck: nil, dependency: nil, sourceRef: nil, tracked: false)
            ],
            slackSummary: nil)

        let violations = ArtifactValidator.validate(tasks: tasks, transcript: transcript)
        #expect(violations.count == 1)
        #expect(violations[0].field == "items[1].owner")

        let fixed = ArtifactValidator.downgrade(tasks: tasks, transcript: transcript)
        #expect(fixed.items[1].owner == "[OWNER?]")
        #expect(fixed.items[0].owner == "Sam")
        #expect(ArtifactValidator.validate(tasks: fixed, transcript: transcript).isEmpty)
    }

    // MARK: Renderers

    @Test("artifacts render markdown and CSV with flags intact")
    func renderers() {
        let tasks = TasksArtifact(
            dacis: [.init(decision: "Usage pricing", driver: "Sam", approver: "Dana", contributors: nil, informed: nil)],
            items: [.init(task: "Draft, the page", owner: nil, due: nil,
                          doneCheck: "Given draft When reviewed Then published",
                          dependency: nil, sourceRef: "10:02:10", tracked: true)],
            slackSummary: "Pricing decided; Sam drafts.")
        let markdown = tasks.markdown
        #expect(markdown.contains("## Решения (DACI)"))
        #expect(markdown.contains("[OWNER?]"))
        #expect(markdown.contains("TRACKED"))
        #expect(markdown.contains("сводка для чата"))
        let csv = tasks.csv
        #expect(csv.hasPrefix("Задача,Владелец,Срок"))
        #expect(csv.contains("\"Draft, the page\""))   // comma-escaped

        let summary = SummaryArtifact(
            tldr: ["one"], decisions: [.init(text: "d", quote: "q-longer-quote", speaker: "Sam", timestamp: "10:01")],
            actions: [.init(task: "t", owner: nil, due: nil, tracked: nil)],
            openQuestions: nil, risks: nil,
            continuity: [.init(commitment: "c", status: "kept")], parkingLot: nil, nextMeeting: nil)
        #expect(summary.markdown.contains("## TL;DR"))
        #expect(summary.markdown.contains("НЕ УКАЗАНО"))
        #expect(summary.markdown.contains("[kept] c"))
        #expect(StructuredArtifact.tasks(tasks).csv != nil)
        #expect(StructuredArtifact.summary(summary).csv == nil)
    }
}
