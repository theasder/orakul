import Foundation
import Testing
@testable import MeetGPT

/// The critics decide what the eval harness reports, so they are pinned on
/// fixtures rather than trusted against live history: a critic that quietly
/// stops firing turns into "quality improved".
@Suite("Reflection critics")
struct ReflectionCriticsTests {

    private let transcript = """
    [system] We should confirm the budget before committing to the July date.
    [mic] I think Priya owns the budget, but nobody has said so out loud.
    [system] Let's park pricing until legal signs off on the contract.
    """

    private func suggestion(_ title: String,
                            kind: SuggestionKind = .risk,
                            evidence: String? = nil,
                            detail: String = "detail") -> Suggestion {
        Suggestion(id: UUID(), title: title, detail: detail, kind: kind, evidence: evidence)
    }

    // MARK: - Blind spots

    @Test("a quote that appears in the transcript passes")
    func groundedEvidencePasses() {
        let tally = ReflectionCritics.judgeBlindSpots(
            [suggestion("Budget unconfirmed", evidence: "confirm the budget before committing")],
            transcript: transcript)

        #expect(tally.judged[.blindSpot] == 1)
        #expect(tally.findings.isEmpty)
    }

    @Test("a quote nobody said is reported as ungrounded")
    func inventedEvidenceIsCaught() {
        let tally = ReflectionCritics.judgeBlindSpots(
            [suggestion("Budget approved", evidence: "the budget was approved last Tuesday")],
            transcript: transcript)

        #expect(tally.findings.map(\.rule) == ["blindSpot.evidenceUngrounded"])
    }

    @Test("a card with no quote at all is reported")
    func missingEvidenceIsCaught() {
        let tally = ReflectionCritics.judgeBlindSpots(
            [suggestion("Someone should own this")], transcript: transcript)

        #expect(tally.findings.map(\.rule) == ["blindSpot.evidenceMissing"])
    }

    @Test("a hunch is exempt — it claims what the call has NOT said")
    func hypothesisNeedsNoEvidence() {
        // The one kind that is not an observation. Requiring a quote would make
        // every hunch a violation, which would drown the real signal.
        let tally = ReflectionCritics.judgeBlindSpots(
            [suggestion("They may be price-shopping", kind: .hypothesis)],
            transcript: transcript)

        #expect(tally.findings.isEmpty)
        #expect(ReflectionCritics.requiresEvidence(.hypothesis) == false)
        #expect(ReflectionCritics.requiresEvidence(.risk))
    }

    @Test("the same card reworded is caught where exact-title dedup misses it")
    func nearDuplicateIsCaught() {
        // Production dedupes on an exact lowercased title, so these two ship
        // together today. This rule measures that gap.
        let tally = ReflectionCritics.judgeBlindSpots([
            suggestion("Budget owner is unnamed", evidence: "nobody has said so out loud"),
            suggestion("Owner unnamed for budget", evidence: "nobody has said so out loud")
        ], transcript: transcript)

        #expect(tally.findings.map(\.rule) == ["blindSpot.nearDuplicate"])
        #expect(tally.judged[.blindSpot] == 2)
    }

    @Test("different cards are not collapsed into duplicates")
    func distinctCardsSurvive() {
        let tally = ReflectionCritics.judgeBlindSpots([
            suggestion("Budget owner is unnamed", evidence: "nobody has said so out loud"),
            suggestion("Pricing parked until legal signs off", evidence: "park pricing until legal signs off")
        ], transcript: transcript)

        #expect(tally.findings.isEmpty)
    }

    @Test("overlap is measured on meaning-carrying words, not stop words")
    func stopWordsDoNotCreateDuplicates() {
        #expect(!ReflectionCritics.nearDuplicate("The risk is in the plan",
                                                 "There is a gap in the contract"))
        #expect(ReflectionCritics.significantWords("The budget is not confirmed")
            == ["budget", "confirmed"])
    }

    // MARK: - Answers

    @Test("an answer quoting the transcript passes")
    func groundedAnswerQuotePasses() {
        let answer = "You agreed to “park pricing until legal signs off on the contract” — that is the blocker."
        let tally = ReflectionCritics.judgeAnswer(answer, transcript: transcript)

        #expect(tally.judged[.answer] == 1)
        #expect(tally.findings.isEmpty)
    }

    @Test("an answer inventing a quote is reported")
    func hallucinatedAnswerQuoteIsCaught() {
        // The one failure a meeting assistant cannot be allowed: attributing a
        // sentence to the call that nobody said.
        let answer = "Priya said “we have already signed the contract with legal last week”."
        let tally = ReflectionCritics.judgeAnswer(answer, transcript: transcript)

        #expect(tally.findings.map(\.rule) == ["answer.quoteUngrounded"])
    }

    @Test("short quoted fragments are not treated as attributions")
    func shortQuotesAreIgnored() {
        let tally = ReflectionCritics.judgeAnswer("They said “ok” and moved on.", transcript: transcript)

        #expect(tally.judged[.answer] == nil)
        #expect(tally.findings.isEmpty)
    }

    @Test("quoted error text and identifiers are not attributions")
    func nonSpeechQuotesAreIgnored() {
        // The first harness run against real history reported 4/8 ungrounded
        // quotes; every one was a fragment of a Gemini quota error the answer
        // was explaining, not a claim about what anybody said. A critic that
        // cannot tell those apart buries the hallucination it exists to find.
        let answer = """
        The request failed with “generativelanguage.googleapis.com/generate_content_free_tier_requests”.
        See “https://ai.google.dev/gemini-api/docs/rate-limits” for the quota table, under
        “GenerateRequestsPerDayPerProjectPerModel-FreeTier”.
        """
        let tally = ReflectionCritics.judgeAnswer(answer, transcript: transcript)

        #expect(tally.judged[.answer] == nil)
        #expect(tally.findings.isEmpty)
    }

    @Test("a quote with no attribution cue is left unmeasured, not flagged")
    func unattributedQuotesAreNotJudged() {
        // Precision over recall: the reported rate is a floor. A quote nobody
        // is claiming was spoken is not evidence of a hallucination.
        let answer = "The docs describe it as “a hard monthly ceiling on free requests per project”."
        let tally = ReflectionCritics.judgeAnswer(answer, transcript: transcript)

        #expect(tally.judged[.answer] == nil)
        #expect(ReflectionCritics.looksLikeSpeech("a hard monthly ceiling on free requests"))
        #expect(!ReflectionCritics.looksLikeSpeech("GenerateRequestsPerDay-FreeTier"))
    }

    // MARK: - Digest

    @Test("a long call with no digest is a silent failure worth reporting")
    func emptyDigestOnLongCall() {
        let long = String(repeating: "we talked about the roadmap. ", count: 100)
        let tally = ReflectionCritics.judgeDigest("", transcript: long)

        #expect(tally.findings.map(\.rule) == ["digest.emptyOnLongCall"])
    }

    @Test("a short call with no digest is not judged at all")
    func shortCallIsNotJudged() {
        let tally = ReflectionCritics.judgeDigest("", transcript: "hello")

        #expect(tally.judged[.digest] == nil)
        #expect(tally.findings.isEmpty)
    }

    // MARK: - Fact-check verdicts

    @Test("a verdict with nothing cited is reported")
    func verifiedWithoutSourceIsCaught() {
        let tally = ReflectionCritics.judgeFactClaims([
            FactClaim(text: "Legal already signed", status: .verified,
                      explanation: "seems right", source: nil)
        ], transcript: transcript)

        #expect(tally.judged[.factClaim] == 1)
        #expect(tally.findings.map(\.rule) == ["factClaim.verdictWithoutSource"])
    }

    @Test("needs-source and not-checkable verdicts are honest, not violations")
    func honestVerdictsPass() {
        let tally = ReflectionCritics.judgeFactClaims([
            FactClaim(text: "This will close in Q3", status: .unverifiable,
                      explanation: "a prediction", source: nil),
            FactClaim(text: "The contract allows it", status: .needsContext,
                      explanation: "no contract attached", source: nil)
        ], transcript: transcript)

        #expect(tally.judged[.factClaim] == 2)
        #expect(tally.findings.isEmpty)
    }

    @Test("a self-contradiction verdict must quote a line the call contains")
    func inconsistentSourceMustBeGrounded() {
        let grounded = ReflectionCritics.judgeFactClaims([
            FactClaim(text: "Two dates given", status: .inconsistent,
                      explanation: "conflicts", source: "park pricing until legal signs off")
        ], transcript: transcript)
        #expect(grounded.findings.isEmpty)

        let invented = ReflectionCritics.judgeFactClaims([
            FactClaim(text: "Two dates given", status: .inconsistent,
                      explanation: "conflicts", source: "we agreed on the June date twice")
        ], transcript: transcript)
        #expect(invented.findings.map(\.rule) == ["factClaim.inconsistentSourceUngrounded"])
    }

    // MARK: - Action items

    @Test("an unassigned, undated action item is reported on both counts")
    func weakActionItemIsCaught() {
        let followUp = SavedFollowUp(
            goalType: "run_the_retro", label: "Run the retro", efficiencyScore: 0.3,
            actionItems: [SavedActionItem(title: "Circle back on pricing", owner: nil, due: nil,
                                          ask: nil, score: 0.2, missing: ["owner", "due"])])

        let tally = ReflectionCritics.judgeActionItems(followUp)

        #expect(tally.judged[.actionItem] == 1)
        #expect(Set(tally.findings.map(\.rule)) == ["actionItem.noOwner", "actionItem.noDue"])
    }

    @Test("a low score that names nothing missing cannot be acted on")
    func scoreWithoutReasonIsCaught() {
        let followUp = SavedFollowUp(
            goalType: "make_the_hire", label: "Make the hire", efficiencyScore: 0.4,
            actionItems: [SavedActionItem(title: "Follow up", owner: "Sam", due: "Friday",
                                          ask: "call them", score: 0.2, missing: [])])

        let tally = ReflectionCritics.judgeActionItems(followUp)

        #expect(tally.findings.map(\.rule) == ["actionItem.scoreWithoutReason"])
    }

    @Test("a complete action item passes")
    func strongActionItemPasses() {
        let followUp = SavedFollowUp(
            goalType: "close_the_deal", label: "Close the deal", efficiencyScore: 0.9,
            actionItems: [SavedActionItem(title: "Send the redlines", owner: "Priya",
                                          due: "2026-08-14", ask: "send redlines to legal",
                                          score: 0.95, missing: [])])

        #expect(ReflectionCritics.judgeActionItems(followUp).findings.isEmpty)
    }

    @Test("no follow-up means nothing judged, not a clean sheet")
    func absentFollowUpIsNotJudged() {
        let tally = ReflectionCritics.judgeActionItems(nil)

        #expect(tally.judged[.actionItem] == nil)
        #expect(tally.findings.isEmpty)
    }

    // MARK: - Report

    @Test("rates carry their denominator, and an unmeasured rule reads as zero")
    func summaryReportsRates() {
        var tally = ReflectionTally()
        tally.judge(.blindSpot, count: 4)
        tally.record(ReflectionFinding(rule: "blindSpot.evidenceUngrounded",
                                       subject: .blindSpot, detail: "x", excerpt: "y"))
        let score = ReflectionEval.SessionScore(
            id: UUID(), title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 0), tally: tally)

        let summary = ReflectionEval.summarize([score])

        #expect(summary.sessions == 1)
        #expect(summary.judged[.blindSpot] == 4)
        #expect(summary.rules.count == 1)
        #expect(summary.rules[0].hits == 1)
        #expect(summary.rules[0].judged == 4)
        #expect(abs(summary.rules[0].rate - 0.25) < 0.0001)
        #expect(ReflectionEval.render(summary).contains("25.0%"))
    }

    @Test("an empty corpus says so instead of reporting a perfect score")
    func emptyCorpusIsHonest() {
        let rendered = ReflectionEval.render(ReflectionEval.summarize([]))

        #expect(rendered.contains("No sessions"))
        #expect(!rendered.contains("0.0%"))
    }
}
