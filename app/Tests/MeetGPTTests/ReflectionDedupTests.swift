import Foundation
import Testing
@testable import MeetGPT

/// Keeping the post-call reflection from restating the summary.
///
/// The acceptance criterion was blunt: the artefact must NEVER duplicate a
/// summary bullet. Reflection exists to say what the transcript does not
/// contain; one that repeats the summary is indistinguishable from the thing it
/// was built to differ from, and the user concludes the feature has nothing to
/// add.
///
/// The asymmetry these tests encode: under-removing is right. A blunt
/// word-overlap score misses paraphrases that share no vocabulary, so some
/// near-duplicates survive — and that is the correct failure, because dropping
/// a real insight because it rhymes with a bullet costs far more.
@Suite("Reflection dedup")
struct ReflectionDedupTests {

    // MARK: - The criterion

    @Test("removes a point that restates a summary bullet")
    func removesRestatement() {
        let summary = ["Maria will send the client contract by Friday."]
        let points = [
            "Maria will send the client contract by Friday.",
            "No one owns the vendor decision, and it was not raised again.",
        ]

        let kept = ReflectionDedup.removingSummaryRestatements(points, summary: summary)
        #expect(kept == ["No one owns the vendor decision, and it was not raised again."])
    }

    @Test("removes a reworded restatement, not only an identical one")
    func removesRewording() {
        // A summary bullet and a reflection point rarely match byte for byte;
        // if only exact matches were removed the feature would restate the
        // summary in slightly different words every time.
        let summary = ["The launch moves to September after the Postgres backfill."]
        let points = ["The launch moves to September after the Postgres backfill completes."]

        #expect(ReflectionDedup.removingSummaryRestatements(points, summary: summary).isEmpty)
    }

    @Test("keeps a point about the same subject that says something new")
    func keepsNewClaimOnSameSubject() {
        // The hard case. Same nouns, different claim: the summary records the
        // decision, the reflection says nobody owns it. Removing this would
        // gut the feature.
        let summary = ["The launch moves to September."]
        let points = ["Nobody was named to own the September launch, and the room moved on."]

        let kept = ReflectionDedup.removingSummaryRestatements(points, summary: summary)
        #expect(kept.count == 1, "a new claim about a summarised subject must survive")
    }

    // MARK: - Summary parsing

    @Test("strips list markers so a bullet and a bare line are one claim")
    func stripsListMarkers() {
        let lines = ReflectionDedup.summaryLines(from: """
        - Maria will send the contract by Friday
        * The launch moves to September
        1. Legal has not signed the DPA
        """)
        #expect(lines.contains("Maria will send the contract by Friday"))
        #expect(lines.contains("The launch moves to September"))
        #expect(lines.contains("Legal has not signed the DPA"))
    }

    @Test("drops headings and fragments that carry no claim")
    func dropsNonClaims() {
        let lines = ReflectionDedup.summaryLines(from: """
        # Summary
        ## Decisions
        Ok
        ---
        The vendor delivery date remains an open risk
        """)
        #expect(lines == ["The vendor delivery date remains an open risk"])
    }

    @Test("compares per line, so a long summary cannot swallow everything")
    func comparesPerLine() {
        // Against one concatenated blob, a long summary accumulates enough
        // vocabulary to overlap almost any point, and the reflection would
        // always come back empty.
        let summary = ReflectionDedup.summaryLines(from: """
        - Finance approved a forty thousand budget for project Falcon
        - Maria will send the client contract by Friday
        - The launch moves to September after the Postgres backfill
        - The vendor delivery date remains an open risk
        """)
        let points = ["The budget was approved without anyone asking what it excludes."]

        #expect(!ReflectionDedup.removingSummaryRestatements(points, summary: summary).isEmpty)
    }

    // MARK: - Degenerate input

    @Test("an empty summary removes nothing")
    func emptySummaryKeepsEverything() {
        // A call whose summary failed must not silently empty the reflection.
        let points = ["Nobody owns the vendor decision."]
        #expect(ReflectionDedup.removingSummaryRestatements(points, summary: []) == points)
    }

    @Test("no reflection points is not an error")
    func emptyPoints() {
        #expect(ReflectionDedup.removingSummaryRestatements([], summary: ["anything"]).isEmpty)
    }

    @Test("blank strings never count as a restatement")
    func blankNeverMatches() {
        // Two empty strings are trivially similar; treating that as a match
        // would drop points whenever a blank line reached the comparison.
        #expect(!ReflectionDedup.restates("", of: "Maria owns the contract"))
        #expect(!ReflectionDedup.restates("Maria owns the contract", of: "   "))
    }

    @Test("a summary of only headings removes nothing")
    func headingOnlySummary() {
        let summary = ReflectionDedup.summaryLines(from: "# Summary\n## Decisions\n")
        #expect(summary.isEmpty)
        let points = ["Nobody owns the vendor decision."]
        #expect(ReflectionDedup.removingSummaryRestatements(points, summary: summary) == points)
    }

    // MARK: - The threshold

    @Test("the summary bar is looser than the blind-spot duplicate bar")
    func thresholdIsLooserThanBlindSpots() {
        // Deliberate, and the reason is asymmetric cost: two overlapping blind
        // spots are both still findings, while a reflection overlapping a
        // summary is exactly the failure this must prevent.
        #expect(ReflectionDedup.summaryOverlapThreshold
                < ReflectionCritics.duplicateTitleOverlap)
    }

    @Test("uses the existing similarity measure rather than a second one")
    func reusesExistingSimilarity() {
        // Two definitions of "the same claim" in one product drift apart, and
        // the drift is invisible until someone compares outputs.
        let a = "Maria will send the contract by Friday"
        let b = "Maria will send the contract by Friday"
        #expect(ReflectionDedup.restates(a, of: b))
        #expect(ReflectionCritics.similarity(a, b) >= ReflectionDedup.summaryOverlapThreshold)
    }

    @Test("order is preserved")
    func preservesOrder() {
        // The reflection's own ranking is more meaningful than anything a
        // filter could re-sort by.
        let points = ["Alpha claim about ownership", "Beta claim about evidence",
                      "Gamma claim about timing"]
        #expect(ReflectionDedup.removingSummaryRestatements(points, summary: ["unrelated heading text here"])
                == points)
    }
}
