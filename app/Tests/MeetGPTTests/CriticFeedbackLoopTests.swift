import Foundation
import Testing
@testable import MeetGPT

// Closing the loop: the critics were built to MEASURE shipped output. Measuring
// is only half a use. Two of them are cheap enough to run before the user sees
// anything, which turns a reported rate into a defect that never ships.
//
//   * Near-duplicate cards. Production dedupes on an exact lowercased title, and
//     ReflectionCritics exists partly to measure what that gate lets through.
//     Running the same similarity check IN the gate closes it.
//   * Contract violations. A deterministic finding names precisely what is wrong
//     with an answer, which is what a revision pass needs — and it means a
//     revision is spent only when something is actually broken.

@Suite("Blind spots are deduped by meaning, not by exact title")
struct SuggestionSuppressionTests {
    private func card(_ title: String, kind: SuggestionKind = .question) -> Suggestion {
        Suggestion(title: title, detail: "detail", kind: kind, evidence: nil)
    }

    @Test("a card that repeats an earlier one is suppressed")
    func nearDuplicateIsSuppressed() {
        // A reordering, which is what models actually emit twice. Both survive
        // production's exact-title dedupe because not one character matches.
        //
        // NOTE: the pair named in ReflectionCritics' own doc comment ("Budget
        // owner is unnamed" / "No owner named for the budget") scores 0.5 and
        // does NOT trip the 0.6 threshold — the rule under-detects its own
        // motivating example. Left alone deliberately: the threshold is shared
        // with the offline metric, so moving it changes what every past report
        // measured.
        let existing = [card("No owner named for the budget")]
        #expect(SuggestionSuppression.isRedundant(
            card("The budget has no named owner"), against: existing))
    }

    @Test("a genuinely new card survives")
    func distinctCardSurvives() {
        let existing = [card("No owner named for the budget")]
        #expect(!SuggestionSuppression.isRedundant(
            card("Nobody has checked the offline sync path"), against: existing))
    }

    @Test("suppression filters a batch, keeping the first of each twin")
    func batchKeepsTheFirst() {
        let batch = [
            card("No owner named for the budget"),
            card("The budget has no named owner"),
            card("Nobody has checked the offline sync path"),
        ]
        let kept = SuggestionSuppression.filter(batch, against: [])
        #expect(kept.count == 2)
        // First, not best: the earlier card arrived while the topic was open.
        #expect(kept.first?.title == "No owner named for the budget")
    }

    @Test("the live gate and the offline critic use one threshold")
    func gateAndCriticAgree() {
        // If these ever diverge, the eval reports a leak the gate believes it
        // already closed — the measurement and the fix must not drift apart.
        #expect(SuggestionSuppression.overlapThreshold
                == ReflectionCritics.duplicateTitleOverlap)
    }

    @Test("an empty or whitespace title is never treated as a twin of everything")
    func emptyTitlesDoNotCollapse() {
        // Jaccard over two empty word sets is undefined; treating it as 1 would
        // silently swallow every card after a malformed one.
        #expect(!SuggestionSuppression.isRedundant(card("   "), against: [card("   ")]))
    }
}

@Suite("Revision is spent only on a named defect")
struct RevisionPolicyTests {
    private let contractFinding = ReflectionFinding(
        rule: "answer.contractIncomplete", subject: .answer,
        detail: "answer omits most of the requested register: owner, next step",
        excerpt: "The team discussed the release…")

    private let groundingFinding = ReflectionFinding(
        rule: "answer.quoteUngrounded", subject: .answer,
        detail: "quote does not appear in the transcript",
        excerpt: "we agreed to double the budget")

    @Test("a clean answer is never revised")
    func cleanAnswerIsLeftAlone() {
        // Reflection with nothing to point at drifts toward confident prose.
        // No finding, no second call.
        #expect(!RevisionPolicy.shouldRevise(findings: [], surface: .answer))
    }

    @Test("a fired critic earns exactly one revision")
    func firedCriticTriggersRevision() {
        #expect(RevisionPolicy.shouldRevise(findings: [contractFinding], surface: .answer))
        // One pass only: a second costs as much as the first, and the evidence
        // for repeated self-revision improving anything is thin.
        #expect(RevisionPolicy.maximumPasses == 1)
    }

    @Test("background watches never revise, whatever they find")
    func backgroundIsNeverRevised() {
        // One Pro hour already burns 204 of 250 monthly credits. A revision
        // inside a 90-second loop would halve the plan's usable minutes.
        #expect(!RevisionPolicy.shouldRevise(
            findings: [groundingFinding], surface: .backgroundWatch))
    }

    @Test("the revision prompt hands over the finding, not a vague request")
    func revisionPromptNamesTheDefect() {
        let instruction = RevisionPolicy.instruction(for: [contractFinding, groundingFinding])
        #expect(instruction.contains("owner, next step"))
        #expect(instruction.contains("we agreed to double the budget"))
        // "Review your work" is the version that does nothing.
        #expect(!instruction.lowercased().contains("review your work"))
        // And it must forbid the failure mode of self-revision: inventing
        // support for a claim rather than dropping it.
        #expect(instruction.lowercased().contains("remove"))
    }

    @Test("an empty instruction is never produced")
    func noFindingsNoInstruction() {
        #expect(RevisionPolicy.instruction(for: []).isEmpty)
    }
}
