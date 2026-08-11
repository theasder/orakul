import Foundation
import Testing
@testable import MeetGPT

/// The scorer decides whether F5 ships. It gets tested like it matters.
///
/// A scorer that flatters the model would turn the measurement into theatre —
/// the roadmap would read "diarization is ready" because the arithmetic was
/// wrong. Each case below is a specific way that could happen.
@Suite("Diarization scoring")
struct DiarizationScoringTests {

    private typealias Interval = DiarizationScoring.Interval

    private let twoSpeakers = [
        Interval(start: 0, end: 10, speaker: "A"),
        Interval(start: 10, end: 20, speaker: "B"),
        Interval(start: 20, end: 30, speaker: "A"),
    ]

    @Test("a perfect diarization scores 1.0")
    func perfect() {
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: twoSpeakers)
        #expect(result.accuracy == 1.0)
        #expect(result.referenceSeconds == 30)
    }

    @Test("naming the same two people differently is still perfect")
    func labelsAreArbitrary() {
        // The single most important property: speaker IDs carry no meaning, so
        // "Speaker 1/Speaker 2" against "A/B" must not be scored as failure. A
        // scorer without this reports 0% for correct output, and F5 would stay
        // dark on an arithmetic bug.
        let renamed = twoSpeakers.map {
            Interval(start: $0.start, end: $0.end, speaker: $0.speaker == "A" ? "spk_7" : "spk_2")
        }
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: renamed)
        #expect(result.accuracy == 1.0)
        #expect(result.mapping["spk_7"] == "A")
        #expect(result.mapping["spk_2"] == "B")
    }

    @Test("hearing one voice in a two-person call loses the smaller speaker")
    func collapsedToOneSpeaker() {
        // The observed failure at threshold 0.9. One label can only map to one
        // reference speaker, so the other's time is unattributed: 20 of 30s.
        let collapsed = [Interval(start: 0, end: 30, speaker: "only")]
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: collapsed)
        #expect(abs(result.accuracy - 20.0 / 30.0) < 0.001)
        #expect(result.hypothesisSpeakers == 1)
    }

    @Test("splitting one person into many voices is charged for it")
    func overSegmented() {
        // The observed failure at the library default: five voices in a
        // two-person call. Only the two best-matching labels can map; the rest
        // is error, which is what a user sees as "who on earth is Speaker 4".
        let shattered = [
            Interval(start: 0, end: 5, speaker: "s1"),
            Interval(start: 5, end: 10, speaker: "s2"),
            Interval(start: 10, end: 20, speaker: "s3"),
            Interval(start: 20, end: 25, speaker: "s4"),
            Interval(start: 25, end: 30, speaker: "s5"),
        ]
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: shattered)
        #expect(result.hypothesisSpeakers == 5)
        // Best mapping takes B's 10s (s3) plus one 5s slice of A: 15 of 30.
        #expect(abs(result.accuracy - 0.5) < 0.001)
    }

    @Test("swapping the speakers halfway through scores as half wrong")
    func swappedMidway() {
        let swapped = [
            Interval(start: 0, end: 10, speaker: "A"),
            Interval(start: 10, end: 20, speaker: "B"),
            Interval(start: 20, end: 30, speaker: "B"),   // should have been A
        ]
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: swapped)
        // A maps to A (10s), B maps to B (10s of its 20s): 20 of 30.
        #expect(abs(result.accuracy - 20.0 / 30.0) < 0.001)
    }

    @Test("silence in the hypothesis is missed speech, not free credit")
    func missedSpeech() {
        let partial = [Interval(start: 0, end: 10, speaker: "A")]
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: partial)
        #expect(abs(result.accuracy - 10.0 / 30.0) < 0.001)
    }

    @Test("accuracy never exceeds 1.0, even when the pass overlaps itself")
    func overlappingHypothesis() {
        // Diarizers can emit overlapping turns. Summing raw overlap could then
        // exceed the reference duration and report 130% accuracy — a number
        // that would quietly clear any threshold the roadmap sets.
        let overlapping = [
            Interval(start: 0, end: 30, speaker: "A"),
            Interval(start: 0, end: 30, speaker: "A"),
        ]
        let result = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: overlapping)
        #expect(result.accuracy <= 1.0)
    }

    @Test("an empty reference scores zero rather than dividing by it")
    func emptyReference() {
        let result = DiarizationScoring.attribution(reference: [], hypothesis: twoSpeakers)
        #expect(result.accuracy == 0)
        #expect(result.referenceSeconds == 0)
    }

    @Test("ground truth parses tab-separated seconds, skipping malformed rows")
    func parsing() {
        let text = """
        0.000\t10.500\tA
        10.500\t20.000\tB
        broken line
        30.000\t20.000\tA
        """
        let parsed = DiarizationScoring.parseGroundTruth(text)
        #expect(parsed.count == 2)
        #expect(parsed[0].speaker == "A")
        #expect(abs(parsed[0].end - 10.5) < 0.0001)
        // End before start is a corrupt row, not a negative-duration turn.
        #expect(parsed.allSatisfy { $0.duration > 0 })
    }

    @Test("line scoring absorbs a spurious voice too short to win its line")
    func lineScoringOutvotesSpuriousTurns() {
        // The reason this metric exists. A 0.4s phantom speaker inside a
        // four-second line never reaches the screen, because the line takes the
        // speaker who overlaps it most — so charging the model for it would be
        // scoring an error the product already absorbs.
        let noisy = [
            Interval(start: 0, end: 3.6, speaker: "A"),
            Interval(start: 3.6, end: 4.0, speaker: "ghost"),
            Interval(start: 4, end: 10, speaker: "A"),
            Interval(start: 10, end: 20, speaker: "B"),
            Interval(start: 20, end: 30, speaker: "A"),
        ]
        let byTime = DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: noisy)
        #expect(byTime.accuracy < 1.0)                                  // time-weighted: charged
        #expect(DiarizationScoring.lineAccuracy(reference: twoSpeakers,
                                                hypothesis: noisy) == 1.0)   // as read: invisible
    }

    @Test("line scoring still catches a speaker who is wrong for whole lines")
    func lineScoringCatchesRealErrors() {
        // The metric must not be a whitewash: an error big enough to own a line
        // has to show up, or it would rate a broken pass as perfect.
        let wrong = [
            Interval(start: 0, end: 10, speaker: "A"),
            Interval(start: 10, end: 30, speaker: "A"),   // 10-20 should be B
        ]
        // Eight lines on the grid, two of them B's. Calling everyone A gets
        // exactly the other six: 0.75, and visibly not perfect.
        let accuracy = DiarizationScoring.lineAccuracy(reference: twoSpeakers, hypothesis: wrong)
        #expect(abs(accuracy - 0.75) < 0.001)
    }

    @Test("a line nobody spoke in is not a line anyone can get wrong")
    func silentLinesAreSkipped() {
        // Reference speech from 0-10 only; the grid runs to 10, so a pass that
        // says nothing after 10 must not be credited or charged for silence.
        let sparse = [Interval(start: 0, end: 10, speaker: "A")]
        #expect(DiarizationScoring.lineAccuracy(reference: sparse, hypothesis: sparse) == 1.0)
    }

    @Test("speaker identity is mapped once for the whole call, not per line")
    func mappingIsGlobal() {
        // A pass that flips its labels every line is wrong, not perfect. If the
        // mapping were recomputed per line, this input would score 100%.
        let flipping = [
            Interval(start: 0, end: 10, speaker: "x"),
            Interval(start: 10, end: 20, speaker: "y"),
            Interval(start: 20, end: 30, speaker: "y"),   // should be x again
        ]
        #expect(DiarizationScoring.lineAccuracy(reference: twoSpeakers,
                                                hypothesis: flipping) < 1.0)
    }

    @Test("scoring is deterministic when overlaps tie")
    func deterministicOnTies() {
        // Two hypothesis labels with identical overlap must not map differently
        // between runs, or the same corpus reports two different accuracies and
        // nobody can tell a real regression from dictionary ordering.
        let tied = [
            Interval(start: 0, end: 10, speaker: "z"),
            Interval(start: 10, end: 20, speaker: "a"),
        ]
        let scores = (0..<8).map { _ in
            DiarizationScoring.attribution(reference: twoSpeakers, hypothesis: tied).accuracy
        }
        #expect(Set(scores).count == 1)
    }
}
