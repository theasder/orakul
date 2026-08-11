import Foundation
import Testing
@testable import MeetGPT

/// The scorer itself, because every transcription conclusion rests on it.
///
/// A scorer that silently miscounts would not fail — it would report a
/// plausible number, and tuning would follow it in the wrong direction. Two
/// tuning rounds were already spent chasing measurement noise; a wrong metric
/// is the same mistake with no spread to warn about it.
@Suite("Transcript accuracy scoring")
struct TranscriptAccuracyTests {

    @Test("a perfect match scores zero")
    func perfectMatch() {
        let text = "We ship US-only on the twentieth."
        let score = TranscriptAccuracy.score(reference: text, hypothesis: text)

        #expect(score.wer == 0)
        #expect(score.recall == 1)
    }

    @Test("counts a dropped word as a deletion, not a substitution")
    func countsDeletions() {
        let score = TranscriptAccuracy.score(reference: "the vendor has not confirmed the date",
                                             hypothesis: "the vendor has confirmed the date")

        // The distinction is the point: deletions mean audio was lost, which is
        // a chunking problem. Substitutions mean it was misheard, which is a
        // model problem. They do not share a fix.
        #expect(score.deletions == 1)
        #expect(score.substitutions == 0)
        #expect(score.insertions == 0)
    }

    @Test("counts an invented word as an insertion")
    func countsInsertions() {
        let score = TranscriptAccuracy.score(reference: "legal has not signed",
                                             hypothesis: "legal has not yet signed")
        #expect(score.insertions == 1)
        #expect(score.deletions == 0)
    }

    @Test("counts a misheard word as a substitution")
    func countsSubstitutions() {
        let score = TranscriptAccuracy.score(reference: "migrate the Postgres cluster",
                                             hypothesis: "migrate the postgres blaster")
        #expect(score.substitutions == 1)
        #expect(score.deletions == 0)
        #expect(score.insertions == 0)
    }

    @Test("WER is edits over reference length")
    func werIsEditsOverReference() {
        // 1 substitution in 4 reference words.
        let score = TranscriptAccuracy.score(reference: "one two three four",
                                             hypothesis: "one two nine four")
        #expect(abs(score.wer - 0.25) < 0.0001)
    }

    @Test("ignores case and punctuation, which are formatting not hearing")
    func ignoresFormatting() {
        let score = TranscriptAccuracy.score(reference: "So, that's where it brought me.",
                                             hypothesis: "so that's where it brought me")
        #expect(score.wer == 0)
    }

    @Test("treats spelled-out and digit numbers as the same word")
    func normalisesNumbers() {
        // The two engines genuinely disagree on this and it is not an error:
        // AssemblyAI wrote "3 different levels", Whisper writes it out.
        let score = TranscriptAccuracy.score(reference: "there are 3 different levels",
                                             hypothesis: "there are three different levels")
        #expect(score.wer == 0)
    }

    @Test("treats casual contractions as the same word")
    func normalisesContractions() {
        let score = TranscriptAccuracy.score(reference: "I'm just gonna go through it, yeah",
                                             hypothesis: "I'm just going to go through it, yep")
        #expect(score.wer == 0)
    }

    @Test("normalisation is applied to both sides")
    func normalisationIsSymmetric() {
        // Applied to one side only, the mapping would erase the other engine's
        // errors and flatter whichever side it was applied to.
        let forward = TranscriptAccuracy.score(reference: "yeah ok, 3 levels", hypothesis: "yep okay, three levels")
        let backward = TranscriptAccuracy.score(reference: "yep okay, three levels", hypothesis: "yeah ok, 3 levels")
        #expect(forward.wer == backward.wer)
        #expect(forward.wer == 0)
    }

    @Test("does not equate synonyms, only formatting variants")
    func doesNotEquateSynonyms() {
        // "okay" and "alright" mean the same thing but are different words.
        // Folding them together would hide a real substitution and quietly
        // improve every score.
        #expect(TranscriptAccuracy.score(reference: "okay", hypothesis: "alright").substitutions == 1)
    }

    @Test("an apostrophe does not split one word into two")
    func apostrophesDoNotSplitWords() {
        // Splitting "I'm" into "i" and "m" inflates the reference length and
        // misaligns everything downstream of it.
        #expect(TranscriptAccuracy.normalise("I'm sure that's right") == ["im", "sure", "thats", "right"])
        // Curly apostrophes are what the engines actually emit.
        #expect(TranscriptAccuracy.normalise("that\u{2019}s") == ["thats"])
    }

    @Test("an empty hypothesis deletes everything rather than scoring perfect")
    func emptyHypothesis() {
        let score = TranscriptAccuracy.score(reference: "one two three", hypothesis: "")

        // A crashed engine emits nothing. That must be the worst score, not a
        // divide-by-zero that reads as success.
        #expect(score.deletions == 3)
        #expect(score.wer == 1.0)
        #expect(score.recall == 0)
    }

    @Test("an empty reference counts hypothesis words as insertions")
    func emptyReference() {
        let score = TranscriptAccuracy.score(reference: "", hypothesis: "invented speech here")
        #expect(score.insertions == 3)
    }

    @Test("both empty is zero, not a crash")
    func bothEmpty() {
        #expect(TranscriptAccuracy.score(reference: "", hypothesis: "").wer == 0)
    }

    @Test("WER can exceed 1.0 when the engine invents more than it hears")
    func werExceedsOne() {
        let score = TranscriptAccuracy.score(reference: "one two",
                                             hypothesis: "one two three four five six")

        // Clamping would make runaway hallucination indistinguishable from
        // ordinary mediocrity.
        #expect(score.wer > 1.0)
    }

    @Test("recall ignores hallucination, so the two failures stay separable")
    func recallSeparatesFailureModes() {
        let complete = TranscriptAccuracy.score(reference: "one two three four",
                                                hypothesis: "one two three four plus five invented words")
        // Every reference word survived; only junk was added.
        #expect(complete.recall == 1.0)
        #expect(complete.wer > 0)

        let lossy = TranscriptAccuracy.score(reference: "one two three four", hypothesis: "one two")
        #expect(lossy.recall == 0.5)
    }

    @Test("reconstructs the measured chunk-boundary failure as deletions")
    func reconstructsChunkBoundaryFailure() {
        // What the failing run actually produced: most of the speech gone,
        // nothing invented.
        let reference = "There is one open risk. The vendor has not confirmed the delivery date for the hardware order and the Kubernetes rollout waits."
        let hypothesis = "There is one open risk. The vendor has not confirmed the delivery date for the"

        let score = TranscriptAccuracy.score(reference: reference, hypothesis: hypothesis)

        #expect(score.deletions > 0)
        #expect(score.insertions == 0)
        // The signature of lost audio: WER and lost recall move together.
        #expect(score.recall < 1.0)
    }

    // MARK: - Term recall

    @Test("term recall finds the words that carry the meeting's meaning")
    func termRecallFindsTerms() {
        let (found, missing) = TranscriptAccuracy.termRecall(
            terms: ["Canva", "Kubernetes", "Postgres"],
            in: "we opened canva and then the postgres migration")

        #expect(found.sorted() == ["Canva", "Postgres"])
        #expect(missing == ["Kubernetes"])
    }

    @Test("a multi-word term counts only when all of it survived")
    func termRecallRequiresWholeTerm() {
        let (found, missing) = TranscriptAccuracy.termRecall(
            terms: ["brand kit", "content planner"],
            in: "open the brand kit and then the planner")

        // "planner" alone is not "content planner" — a half-heard product name
        // is still a wrong answer downstream.
        #expect(found == ["brand kit"])
        #expect(missing == ["content planner"])
    }

    @Test("term recall ignores case and punctuation like the main scorer")
    func termRecallNormalises() {
        let (found, _) = TranscriptAccuracy.termRecall(terms: ["All Brands"],
                                                       in: "the all-brands template page")
        #expect(found == ["All Brands"])
    }
}
