import Foundation
import Testing
@testable import MeetGPT

/// Cutting the seam between overlapping transcription windows.
///
/// The measured failure this serves: with hard 6-second cuts, an utterance
/// crossing a boundary came back as "The vendor has not confirmed the delivery
/// date for the" plus the orphans "Agreed. The", "Kubernetes," and "and", and
/// the short-fragment filter then deleted the orphans. 124 spoken words arrived
/// as 53. Overlapping the windows stops the loss but transcribes the seam
/// twice; this removes the repeat without removing the new speech.
@Suite("Chunk stitching")
struct ChunkStitcherTests {

    @Test("removes the repeated opening and keeps what is new")
    func removesRepeatKeepsNew() {
        let previous = "The vendor has not confirmed the delivery date"
        let next = "the delivery date for the hardware order."

        #expect(ChunkStitcher.stitch(previous: previous, next: next)
                == "for the hardware order.")
    }

    @Test("ignores case and punctuation, which the two decodes rarely agree on")
    func normalisesAcrossDecodes() {
        let previous = "before we migrate the Postgres cluster."
        let next = "the postgres cluster and run the backfill twice."

        // "Postgres cluster." and "postgres cluster" are the same words; a
        // byte comparison would miss the seam and duplicate them.
        #expect(ChunkStitcher.stitch(previous: previous, next: next)
                == "and run the backfill twice.")
    }

    @Test("takes the LONGEST seam, not the first one it finds")
    func prefersLongestOverlap() {
        let previous = "we should ship the release on the second week"
        let next = "on the second week of September."

        // A greedy short match on "on the" would leave "second week" emitted
        // twice.
        #expect(ChunkStitcher.stitch(previous: previous, next: next)
                == "of September.")
    }

    @Test("leaves unrelated text alone")
    func leavesUnrelatedAlone() {
        let previous = "Maria will send the updated contract by Friday."
        let next = "There is one open risk."

        #expect(ChunkStitcher.stitch(previous: previous, next: next) == next)
    }

    @Test("a single shared word is a coincidence, not a seam")
    func ignoresSingleWordOverlap() {
        // "the", "and", "we" end and begin sentences constantly. Cutting on one
        // of them would delete a real word from the new window.
        #expect(ChunkStitcher.stitch(previous: "we agreed on the",
                                     next: "the Kubernetes rollout waits.")
                == "the Kubernetes rollout waits.")
    }

    @Test("a window entirely inside the overlap is a pure repeat")
    func detectsPureRepeat() {
        let previous = "before we migrate the Postgres cluster"
        #expect(ChunkStitcher.isPureRepeat(previous: previous,
                                           next: "the Postgres cluster") == true)
        #expect(ChunkStitcher.isPureRepeat(previous: previous,
                                           next: "and run the backfill") == false)
    }

    @Test("empty input on either side is returned unchanged")
    func handlesEmptyInput() {
        #expect(ChunkStitcher.stitch(previous: "", next: "anything at all") == "anything at all")
        #expect(ChunkStitcher.stitch(previous: "anything at all", next: "") == "")
        #expect(ChunkStitcher.stitch(previous: "", next: "") == "")
    }

    @Test("punctuation-only input does not crash or cut")
    func handlesPunctuationOnly() {
        #expect(ChunkStitcher.stitch(previous: "...", next: "Real speech here.")
                == "Real speech here.")
    }

    @Test("keeps the new window's own punctuation and spacing")
    func preservesFormatting() {
        let stitched = ChunkStitcher.stitch(previous: "one open risk",
                                            next: "one open risk — the vendor.")
        // Rebuilding from normalised tokens would return "the vendor" and lose
        // the dash and the full stop.
        #expect(stitched == "— the vendor.")
    }

    @Test("a long repeat is capped so a coincidence cannot eat real speech")
    func capsOverlapLength() {
        let shared = (1...40).map { "word\($0)" }.joined(separator: " ")
        let stitched = ChunkStitcher.stitch(previous: shared, next: "\(shared) and then something new.")

        // Beyond the cap the seam is not searched, so the result still contains
        // the new words rather than being over-trimmed into nothing.
        #expect(stitched.contains("something new"))
    }

    @Test("the whole next window can be consumed when it repeats entirely")
    func consumesFullRepeat() {
        #expect(ChunkStitcher.stitch(previous: "the delivery date for the hardware",
                                     next: "the delivery date for the hardware").isEmpty)
    }

    // MARK: - Near-matching seams

    @Test("cuts a seam the two decodes worded differently")
    func cutsFuzzySeam() {
        // Measured on a real call: the first window ended mid-word on "back",
        // the second heard the whole word. Exact matching found no seam and
        // emitted the entire overlap twice.
        let previous = "you're a little bit more comfortable like using the back"
        let next = "little bit more comfortable like using the background images."

        let stitched = ChunkStitcher.stitch(previous: previous, next: next)

        #expect(stitched == "images.")
    }

    @Test("tolerates one disagreeing word inside a long seam")
    func toleratesOneDisagreement() {
        let previous = "so I really say that there's three different levels to Canva"
        let next = "I really say that there is three different levels to Canva, the basics."

        #expect(ChunkStitcher.stitch(previous: previous, next: next) == "the basics.")
    }

    @Test("does NOT cut two different sentences that share filler")
    func doesNotCutOnSharedFiller() {
        // The risk the fuzzy pass introduces. These share "you can" and little
        // else; trimming here would delete real speech, which is the exact
        // failure the overlap was added to prevent.
        let previous = "so you can make it look like a different style"
        let next = "and you can also export the whole thing as a PDF."

        #expect(ChunkStitcher.stitch(previous: previous, next: next) == next)
    }

    @Test("a short near-match is not enough evidence")
    func requiresLengthForFuzzyMatch() {
        // Three words with one wrong is noise, not a seam.
        let stitched = ChunkStitcher.stitch(previous: "we agreed on that",
                                            next: "we agreed in principle today.")
        #expect(stitched == "we agreed in principle today.")
    }

    @Test("agreement scores identical, disjoint and partial overlaps")
    func agreementScoring() {
        #expect(ChunkStitcher.agreement(["a", "b", "c"], ["a", "b", "c"]) == 1.0)
        #expect(ChunkStitcher.agreement(["a", "b", "c"], ["x", "y", "z"]) == 0.0)
        #expect(ChunkStitcher.agreement([], ["a"]) == 0.0)

        // An extra word on one side must not collapse the score: this is the
        // "gonna" / "going to" case that positional comparison gets wrong.
        let withExtra = ChunkStitcher.agreement(["using", "the", "background", "images"],
                                                ["using", "the", "nice", "background", "images"])
        #expect(withExtra > 0.7)
    }

    @Test("prefers the longest near-match, like the exact pass")
    func fuzzyPrefersLongest() {
        let previous = "before we migrate the Postgres cluster and run the backfill"
        let next = "we migrate the Postgres cluster and run a backfill twice tomorrow."

        // A short match near the end would leave most of the overlap duplicated.
        #expect(ChunkStitcher.stitch(previous: previous, next: next) == "twice tomorrow.")
    }

    @Test("exact matches still win over near ones")
    func exactStillPreferred() {
        // The exact pass runs first and at full length, so a clean seam is cut
        // at exactly the right place rather than at a longer fuzzy one.
        let previous = "ship the release on the second week"
        let next = "on the second week of September."
        #expect(ChunkStitcher.stitch(previous: previous, next: next) == "of September.")
    }

    @Test("reconstructs the measured failure end to end")
    func reconstructsMeasuredFailure() {
        // What the seam looked like in the failing run, if the windows had
        // overlapped: the second window re-decodes the tail with enough context
        // to finish the sentence.
        let first = "There is one open risk. The vendor has not confirmed the delivery date"
        let second = "has not confirmed the delivery date for the hardware, and Kubernetes rollout waits."

        let stitched = ChunkStitcher.stitch(previous: first, next: second)

        #expect(stitched == "for the hardware, and Kubernetes rollout waits.")
        // The words that were lost entirely before are present exactly once.
        let joined = "\(first) \(stitched)"
        #expect(joined.components(separatedBy: "delivery date").count - 1 == 1)
        #expect(joined.contains("Kubernetes"))
    }
}
