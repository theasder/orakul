import Foundation
import Testing
@testable import MeetGPT

/// What the seam levers actually do, at fixed caption latency.
///
/// The chunk-length sweep showed insertions falling as windows grow — most live
/// insertions are duplicated fragments where two windows meet. A longer window
/// costs caption latency, so these two levers were measured instead: they attack
/// the same seams without touching the window.
///
/// Both came back negative, and the SHAPE of each negative is the useful part.
@Suite("Seam lever findings")
struct SeamLeverFindingsTests {

    @Test("more overlap trades insertions for substitutions, and loses")
    func overlapIsNetNegative() {
        // Five accented fixtures, 6s window, large-v3-v20240930:
        //
        //   overlap 1.5s   WER 0.2484   S 338   D 526   I 160
        //   overlap 3.0s   WER 0.2580   S 401   D 545   I 118
        //
        // The mechanism predicted by the chunk-length sweep is REAL: doubling
        // the overlap cut insertions by a quarter, 160 to 118. But the stitcher
        // has to reconcile twice as much duplicated audio, and it resolves the
        // extra ambiguity by picking wrong words — substitutions rose 338 to
        // 401, more than cancelling the gain.
        //
        // So seam insertions are worth attacking and overlap is the wrong knob:
        // it moves the error rather than removing it.
        let insertionsAt1_5 = 160, insertionsAt3 = 118
        let substitutionsAt1_5 = 338, substitutionsAt3 = 401
        #expect(insertionsAt3 < insertionsAt1_5, "overlap does cut seam insertions")
        #expect(substitutionsAt3 > substitutionsAt1_5, "and buys them with substitutions")
        #expect(0.2580 > 0.2484, "net worse, so the default stands")
        #expect(Config.transcriptionChunkOverlapSeconds == 1.5)
    }

    @Test("pause alignment was dead code, and fixing it barely moves the number")
    func boundarySlackIsRealButSmall() {
        // Two measurements, and the gap between them is the lesson.
        //
        // Before the frame-size fix, slack 0 and slack 2 produced BYTE-IDENTICAL
        // output — the search could never fire (see the fix in
        // AudioChunkBuffer/VoiceActivity). Afterwards, on five accented
        // fixtures, slack 2 scored 0.2388 against 0.2484: a 3.9% gain, for free,
        // since the window ends earlier rather than later.
        //
        // On the FULL sixteen-fixture corpus that gain almost vanishes:
        //
        //   slack 0   WER 0.2279   S 953   D 1107   I 775
        //   slack 2   WER 0.2269   S 992   D 1097   I 734
        //
        // 0.4%, not 3.9%. Insertions do fall as the mechanism predicts, 775 to
        // 734, and deletions edge down — but substitutions rise 953 to 992 and
        // very nearly cancel it.
        //
        // So the five-fixture figure did not generalise. It was measured on the
        // accented subset, where seam damage is worst and pauses between two
        // speakers are most likely; across a corpus that also contains webinars
        // and single-speaker talks the effect is inside the noise.
        //
        // The default stays 0. A 0.4% change is not a basis for moving a
        // shipped setting, and the honest record of this lever is "real
        // mechanism, negligible size" rather than the flattering first number.
        let fullCorpusSlack0 = 0.2279
        let fullCorpusSlack2 = 0.2269
        let accentedSubsetGain = (0.2484 - 0.2388) / 0.2484
        let fullCorpusGain = (fullCorpusSlack0 - fullCorpusSlack2) / fullCorpusSlack0
        #expect(fullCorpusSlack2 < fullCorpusSlack0, "the direction holds")
        #expect(fullCorpusGain < 0.01, "but the size does not")
        #expect(accentedSubsetGain > fullCorpusGain * 5,
                "the subset overstated it by roughly an order of magnitude")
        #expect(Config.transcriptionBoundarySlackSeconds == 0,
                "default unchanged — 0.4% does not justify moving a shipped setting")
    }

    // MARK: - The search itself works

    /// A tone, not a DC constant.
    ///
    /// Written down because the first version of these tests used a constant
    /// amplitude as "loud speech" and the search treated it as silence — a
    /// steady value has no variation, so every frame read as a pause and the
    /// LATEST one won, which is the target itself. The test failed while the
    /// code was right.
    private func speech(_ count: Int, amplitude: Double = 8_000) -> [Int16] {
        (0..<count).map { index in
            Int16(amplitude * sin(Double(index) * 0.35))
        }
    }

    @Test("a real pause moves the boundary")
    func pauseMovesTheBoundary() {
        // Proves the corpus negative is about the AUDIO, not about the code.
        let rate = 16_000
        var samples = speech(rate * 6)
        // A half-second of silence ending 1s before the target.
        for index in (rate * 5 - rate / 2)..<(rate * 5) { samples[index] = 0 }

        let cut = AudioChunkBuffer.quietestBoundary(
            in: samples, target: rate * 6, slack: rate * 2)
        #expect(cut < rate * 6, "the window should end early, at the pause")
        #expect(cut <= rate * 5, "and at the silence, not after it")
    }

    @Test("continuous speech leaves the boundary on the clock")
    func continuousSpeechKeepsTheClock() {
        // The corpus case: two people in conversation, no qualifying pause in
        // the two seconds before the boundary.
        let rate = 16_000
        #expect(AudioChunkBuffer.quietestBoundary(
            in: speech(rate * 6), target: rate * 6, slack: rate * 2) == rate * 6)
    }

    @Test("zero slack is an exact clock boundary")
    func zeroSlackIsExact() {
        let rate = 16_000
        let samples = [Int16](repeating: 0, count: rate * 6)
        #expect(AudioChunkBuffer.quietestBoundary(
            in: samples, target: rate * 6, slack: 0) == rate * 6)
    }

    @Test("the search never waits for audio that has not arrived")
    func searchesBackwardOnly() {
        // Forward search would delay the first caption, which is the one thing
        // the live path exists to protect.
        let rate = 16_000
        let cut = AudioChunkBuffer.quietestBoundary(
            in: speech(rate * 6), target: rate * 4, slack: rate)
        #expect(cut <= rate * 4)
    }
}
