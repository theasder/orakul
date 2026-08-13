import Foundation
import Testing
@testable import MeetGPT

/// F4 from the RICE roadmap: consequence-ranked minutes. The mined pain, in a
/// reviewer's words: "'We're changing the entire architecture' sits next to
/// 'Bob will be OOO Friday.' Both bullet points. Both look equally important.
/// They're not." The ranker is deterministic on purpose — it runs on every
/// artifact, offline, for free, and its verdicts are testable without a model.
@Suite("Consequence ranking")
struct ConsequenceRankerTests {

    // MARK: scoring

    @Test("an irreversible-scope line outranks housekeeping")
    func architectureBeatsOOO() {
        let big = ConsequenceRanker.score("We're migrating the entire architecture to event sourcing")
        let small = ConsequenceRanker.score("Bob will be OOO Friday")
        #expect(big > small)
    }

    @Test("money and dates raise the stakes")
    func moneyAndDatesScore() {
        let priced = ConsequenceRanker.score("Raise the enterprise plan to $499 from March 1")
        let vague = ConsequenceRanker.score("We should think about pricing at some point")
        #expect(priced > vague)
    }

    @Test("scheduling chatter and deferral phrases are demoted below default")
    func housekeepingDemoted() {
        for line in ["Let's circle back next week",
                     "Reschedule the sync to Tuesday",
                     "Alice is on PTO Thursday and Friday"] {
            #expect(ConsequenceRanker.score(line) < ConsequenceRanker.baselineScore,
                    "\(line) must rank below an ordinary point")
        }
    }

    @Test("hiring, cancellation and security decisions rank high")
    func highStakesVocabulary() {
        for line in ["Decided to cancel the Q3 self-serve launch",
                     "We will hire two senior backend engineers",
                     "Rotate every credential after the vendor breach"] {
            #expect(ConsequenceRanker.score(line) >= ConsequenceRanker.highStakesScore,
                    "\(line) must reach the high-stakes tier")
        }
    }

    @Test("scoring is deterministic and case-insensitive")
    func deterministicCaseInsensitive() {
        let a = ConsequenceRanker.score("CANCEL the migration")
        let b = ConsequenceRanker.score("cancel the migration")
        #expect(a == b)
    }

    // MARK: minutes reordering

    private func minutes(decisions: [String], actions: [MinutesArtifact.ActionItem] = [],
                         discussion: [MinutesArtifact.Topic]? = nil) -> MinutesArtifact {
        MinutesArtifact(title: "Weekly product sync", date: nil, attendees: nil, summary: nil,
                        decisions: decisions, discussion: discussion,
                        actionItems: actions, nextSteps: nil)
    }

    @Test("decisions are reordered by consequence, stably")
    func decisionsReordered() {
        let ranked = minutes(decisions: [
            "Team lunch moves to Thursdays",
            "We are sunsetting the legacy API in June",
            "Standup shortens to 10 minutes",
        ]).ranked()
        #expect(ranked.decisions?.first == "We are sunsetting the legacy API in June")
        // Ties keep their spoken order — the transcript's order is meaningful.
        #expect(ranked.decisions?.dropFirst().first == "Team lunch moves to Thursdays")
    }

    @Test("an owned, dated action item precedes an ownerless one of equal text weight")
    func ownedActionsFirst() {
        let owned = MinutesArtifact.ActionItem(task: "Draft the migration plan", owner: "Priya", due: "Friday")
        let orphan = MinutesArtifact.ActionItem(task: "Draft the rollout plan", owner: nil, due: nil)
        let ranked = minutes(decisions: [], actions: [orphan, owned]).ranked()
        #expect(ranked.actionItems?.first == owned,
                "an action item without an owner is a wish — it must not lead the list")
    }

    @Test("highlights collect the top consequences, at most three")
    func highlightsCapAtThree() {
        let ranked = minutes(decisions: [
            "Sunset the legacy API in June",
            "Move to usage-based pricing at $0.02 per credit",
            "Cancel the Berlin offsite",
            "Rename the #general channel",
        ], actions: [
            .init(task: "Rotate the leaked signing key", owner: "Sam", due: "today"),
        ]).ranked()
        let highlights = ranked.highlights ?? []
        #expect(highlights.count == 3)
        #expect(!highlights.contains("Rename the #general channel"))
    }

    @Test("a small meeting produces no highlights block")
    func smallMeetingNoHighlights() {
        let ranked = minutes(decisions: ["Sunset the legacy API in June"]).ranked()
        #expect((ranked.highlights ?? []).isEmpty,
                "two bullets do not need a table of contents")
    }

    @Test("markdown opens with What matters when highlights exist, and omits it otherwise")
    func markdownRendersHighlights() {
        let big = minutes(decisions: [
            "Sunset the legacy API in June",
            "Move to usage-based pricing at $0.02 per credit",
            "Cancel the Berlin offsite",
            "Team lunch moves to Thursdays",
            "Standup shortens to 10 minutes",
        ], actions: [
            .init(task: "Rotate the leaked signing key", owner: "Sam", due: "today"),
        ]).ranked()
        #expect(big.markdown.contains("## Главное"))
        // The block must come before the full Decisions section, not after.
        #expect(big.markdown.range(of: "## Главное")!.lowerBound
                < big.markdown.range(of: "## Решения")!.lowerBound)

        let small = minutes(decisions: ["Sunset the legacy API in June"]).ranked()
        #expect(!small.markdown.contains("## Главное"))
    }

    @Test("ownerless commitments are called out by name, owned ones are not")
    func ownerlessCallout() {
        let mixed = minutes(decisions: [], actions: [
            .init(task: "Draft the migration plan", owner: "Priya", due: "Friday"),
            .init(task: "Collect pricing feedback", owner: nil, due: nil),
            .init(task: "Book the security review", owner: "", due: nil),
        ])
        let md = mixed.markdown
        #expect(md.contains("### Нужен владелец"))
        let callout = String(md[md.range(of: "### Нужен владелец")!.upperBound...])
        #expect(callout.contains("Collect pricing feedback"))
        #expect(callout.contains("Book the security review"))
        #expect(!callout.contains("Draft the migration plan"))

        let allOwned = minutes(decisions: [], actions: [
            .init(task: "Draft the migration plan", owner: "Priya", due: "Friday"),
        ])
        #expect(!allOwned.markdown.contains("Нужен владелец"))
    }

    @Test("a paragraph-long decision is clipped in the highlights, not in the record")
    func highlightsStayGlanceable() {
        let essay = "We are sunsetting the legacy API in June "
            + String(repeating: "and there was a great deal more discussion about it ", count: 20)
        let ranked = minutes(decisions: [
            essay,
            "Cancel the Berlin offsite",
            "Move to usage-based pricing at $0.02 per credit",
            "Rename the #general channel",
            "Team lunch moves to Thursdays",
        ]).ranked()

        let highlight = try? #require(ranked.highlights?.first)
        #expect((highlight?.count ?? 0) <= MinutesArtifact.maxHighlightCharacters + 1)
        #expect(highlight?.hasSuffix("…") == true, "a clipped glance line says it was clipped")
        // The full sentence survives where the record lives.
        #expect(ranked.decisions?.contains(essay) == true,
                "clipping the glance must never edit the minutes themselves")
    }

    @Test("a flood of unverified figures is summarised, not dumped")
    func flaggedFiguresAreCapped() {
        let manyFigures = (1...30).map { "Line \($0) costs $\($0 * 111)" }
        let audited = minutes(decisions: manyFigures).auditingNumbers(against: "no numbers were said")
        let footer = String(audited.markdown[audited.markdown.range(of: "Проверьте эти цифры")!.upperBound...])
        #expect(footer.contains("and "), "the footer counts what it did not list")
        // A warning listing forty numbers is one nobody checks.
        #expect(footer.count < 400)
    }

    @Test("ranking never drops or invents content")
    func rankingIsAPermutation() {
        let source = minutes(decisions: [
            "Sunset the legacy API in June",
            "Team lunch moves to Thursdays",
            "Cancel the Berlin offsite",
        ], actions: [
            .init(task: "Draft the migration plan", owner: "Priya", due: "Friday"),
            .init(task: "Collect pricing feedback", owner: nil, due: nil),
        ])
        let ranked = source.ranked()
        #expect(Set(ranked.decisions ?? []) == Set(source.decisions ?? []))
        #expect(Set((ranked.actionItems ?? []).map(\.task)) == Set((source.actionItems ?? []).map(\.task)))
    }
}
