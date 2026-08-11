import Foundation
import Testing
@testable import MeetGPT

/// What the whole-file accuracy levers actually measured.
///
/// Not behaviour tests. These record results that cost about ninety minutes of
/// corpus runs each, so the next person to look at local-Whisper accuracy starts
/// from the evidence instead of from the same two plausible guesses.
///
/// The corpus: 16 real recordings, 300s each, `openai_whisper-large-v3`,
/// whole-file single pass, no glossary. Mean WER 0.1775, term recall 0.7238.
/// Deletions dominate — 1293 across the corpus against 313 insertions — and they
/// concentrate on accented speech (D 153, 153, 169, 195 on the Indian, Ghanaian,
/// Romanian and Chinese fixtures) while nearly vanishing on clean audio (D 8, D 13).
@Suite("Whisper lever findings")
struct WhisperLeverFindingsTests {

    @Test("temperature fallback changes nothing on this corpus")
    func temperatureFallbackIsANoOp() {
        // Swept 0 and 2. Output was byte-identical on all 16 fixtures: same WER,
        // same substitution/deletion/insertion counts, same word totals.
        //
        // The reading is NOT "fallback does not help". Fallback only fires when a
        // decode FAILS Whisper's own thresholds (compression ≤ 2.4, avg logprob
        // ≥ -1.0), and those defaults are live. Identical output means no window
        // ever failed them — so the deletions are not repetition loops and not
        // hallucinated spans, which is what fallback exists to repair.
        //
        // Measured once at one setting, "enabled it, WER unchanged" would have
        // read as a tested lever. It never ran.
        let werAtZero = 0.1775
        let werAtTwo = 0.1775
        #expect(werAtZero == werAtTwo)
    }

    @Test("the confidence filter is not what deletes accented speech")
    func confidenceFloorIsANoOp() {
        // Swept the floor -0.85 → -1.2 → -1.6 → -99, the last of which disables
        // the check. All four identical: WER 0.1775, D 1293, I 313, 11677 words.
        //
        // Then instrumented directly, which is what settled it. On the two worst
        // fixtures the filter kept EVERY segment the decoder produced — 94 of 94
        // and 49 of 49 — losing one word in total. The 139 and 153 missing words
        // are absent from the decoder's own output.
        //
        // So `isReliable` is a precision bar that costs nothing here, and the
        // hypothesis that it was over-deleting accented speech is wrong. Raising
        // it would recover nothing; the words are lost upstream, inside decoding.
        let segmentsEmitted = 94
        let segmentsKept = 94
        #expect(segmentsEmitted == segmentsKept)
        #expect(LocalWhisperTranscription.defaultLogProbabilityFloor == -0.85)
    }

    @Test("deletions dominate, and they track accent rather than audio quality")
    func deletionsDominate() {
        // The shape of the remaining error, which is where any further work
        // belongs: 4x more deletions than insertions. The model is not mis-hearing
        // words so much as declining to emit them.
        let deletions = 1293
        let insertions = 313
        #expect(deletions > insertions * 3)
    }

    @Test("VAD chunking does not help, and proves the other knobs were wired")
    func vadChunkingIsMarginallyWorse() {
        // Splitting on speech boundaries instead of fixed 30s windows: WER
        // 0.1787 against 0.1775, recall unchanged at 0.7238. Slightly worse, so
        // it stays off.
        //
        // Its real value is as a control. It DID move the output — 11720 words
        // against 11677, recovering 43 at the seams — which proves the harness
        // and the decoding-options plumbing work end to end. That retroactively
        // confirms the byte-identical results above were genuine no-ops rather
        // than a knob that never reached the decoder, which was the obvious
        // rival explanation for two identical sweeps in a row.
        let werFixed = 0.1775
        let werVAD = 0.1787
        let wordsFixed = 11677
        let wordsVAD = 11720
        #expect(werVAD > werFixed, "VAD measured slightly worse")
        #expect(wordsVAD != wordsFixed, "but it changed the output, so the knob is live")
    }

    @Test("every model measured on one corpus by one method")
    func modelSweepResults() {
        // 2026-08-09, all 16 fixtures, whole-file pass, no glossary:
        //
        //   base                WER 0.2361  recall 0.519  0.08x
        //   small               WER 0.1919  recall 0.657  0.13x
        //   medium              WER 0.1844  recall 0.657  0.31x
        //   large-v3            WER 0.1704  recall 0.657  0.57x
        //   large-v3-v20240930  WER 0.1775  recall 0.724  0.15x
        //
        // The reason this run existed: the shipped captions quoted base 0.26,
        // small 0.21, large-v3 0.14, and each of those means came from a
        // DIFFERENT subset of recordings. base's was measured only on the five
        // clean Western ones — it had never run on the accented corpus at all,
        // which is exactly where the caption claimed the gap widened. Comparing
        // means over different subsets measures the subsets.
        let base = 0.2361, small = 0.1919, large = 0.1704
        #expect(small < base)
        #expect(large < small)
        // The real gap is far smaller than "about a third fewer errors".
        #expect((1 - large / small) < 0.15)
    }

    @Test("medium is not worth offering")
    func mediumEarnsNoSlot() {
        // 0.008 WER better than small, identical term recall, 2.4x the time and
        // a much larger download. A fourth option that buys nothing costs the
        // user a decision.
        let smallWER = 0.1919, mediumWER = 0.1844
        let smallRT = 0.13, mediumRT = 0.31
        #expect(mediumWER < smallWER)
        #expect((smallWER - mediumWER) < 0.01)
        #expect(mediumRT > smallRT * 2)
        #expect(!LocalWhisperModel.isKnown("medium"), "medium must stay unoffered")
    }

    @Test("the large build is chosen for recall and speed, not WER")
    func largeVariantChoice() {
        // v20240930 has a marginally HIGHER word error rate than plain large-v3
        // (0.1775 against 0.1704) and is still the right choice: nearly four
        // times faster (0.15x against 0.57x) and much better at domain terms
        // (0.724 against 0.657).
        //
        // WER counts every word equally. Getting a participant's name and the
        // project right is worth more than getting "the" right, and term recall
        // is the measure that says so.
        #expect(LocalWhisperModel.largeVariant == "large-v3-v20240930")
        let plainRecall = 0.657, variantRecall = 0.724
        #expect(variantRecall > plainRecall)
    }

    @Test("the offered large id is unambiguous")
    func largeIDIsExplicit() {
        // WhisperKit resolves a model string by matching repo folder names, and
        // both openai_whisper-large-v3 and openai_whisper-large-v3-v20240930
        // contain "large-v3". They measure 0.57x and 0.15x realtime — a
        // difference a user feels on a live call — so the shipped id must name
        // exactly one of them.
        #expect(LocalWhisperModel.largeVariant != "large-v3")
        #expect(LocalWhisperModel.options.contains { $0.id == LocalWhisperModel.largeVariant })
    }

    @Test("an install that saved the old id keeps its choice")
    func oldIDMigrates() {
        // Treating "large-v3" as unknown would silently drop the user back to
        // the hardware default — a downgrade they never asked for and would
        // only notice as worse transcripts.
        #expect(LocalWhisperModel.migrated("large-v3") == LocalWhisperModel.largeVariant)
        #expect(LocalWhisperModel.migrated("small") == "small")
        #expect(LocalWhisperModel.isKnown(LocalWhisperModel.migrated("large-v3")))
    }

    @Test("the downgrade ladder still works from the explicit id")
    func ladderHandlesBothIDs() {
        #expect(LocalWhisperModel.nextLighter(than: LocalWhisperModel.largeVariant) == "small")
        #expect(LocalWhisperModel.nextLighter(than: "large-v3") == "small")
        #expect(LocalWhisperModel.nextLighter(than: "small") == "base")
        #expect(LocalWhisperModel.nextLighter(than: "base") == nil)
    }

    @Test("auto-detect matches forced English on this corpus")
    func languageModeIsANoOp() {
        // Worth measuring because the SHIPPING default and the measured
        // configuration differed: Config.transcriptionLanguage defaults to
        // "multi" (auto-detect) while every harness run forces "en". The whole
        // body of accuracy work had therefore been measured in a configuration
        // users do not get by default.
        //
        // Language misdetection on accented English is a known Whisper failure
        // and would look exactly like the deletions that dominate here — a
        // window detected as Hindi or Chinese emits nothing an English
        // reference can match.
        //
        // It does not happen: multi and en produced identical WER 0.1775,
        // recall 0.7238, D 1293 and the same worst fixture. The default is safe,
        // and that is now measured rather than assumed.
        //
        // Scope: this corpus is entirely English. It says auto-detect does not
        // misfire on ACCENTED English; it says nothing about genuinely
        // multilingual calls.
        let werAuto = 0.1775
        let werForced = 0.1775
        #expect(werAuto == werForced)
    }

    @Test("a longer live window trades insertions for latency")
    func liveChunkLengthTrade() {
        // The FIRST lever in this investigation that moves the number, and it is
        // on the path users actually experience. Everything before this was
        // measured on the whole-file pass, which is not what happens during a
        // call.
        //
        // Five accented fixtures (EdAcc), live pipeline, large-v3-v20240930:
        //
        //   6s   WER 0.2484   D 526   I 160
        //   8s   WER 0.2317   D 559   I  98
        //   10s  WER 0.2409   D 629   I  96
        //   12s  WER 0.2221   D 599   I  68
        //
        // Read it by the SPLIT, not the WER. Insertions fall monotonically as
        // the window grows — 160 to 68 — which is exactly what fewer seams
        // should do: most live insertions are duplicated or hallucinated
        // fragments where two windows meet. Deletions drift the other way.
        //
        // The WER ranking between 8, 10 and 12 is NOT trustworthy on five
        // fixtures: 10s scoring worse than 8s while 12s scores best is the
        // signature of noise comparable to the effect. What is trustworthy is
        // the direction and the mechanism.
        let insertionsAt6 = 160, insertionsAt8 = 98, insertionsAt10 = 96, insertionsAt12 = 68
        #expect(insertionsAt6 > insertionsAt8)
        #expect(insertionsAt8 >= insertionsAt10)
        #expect(insertionsAt10 > insertionsAt12)

        // Not shipped as a default change. 6s is a LATENCY budget — a caption
        // has to appear while people are still talking — and doubling it to buy
        // ~10% WER on accented speech is a product decision, not a tuning one.
        // The whole-file re-transcription pass already recovers the accuracy
        // after the call at WER 0.1731, better than any live window here.
        #expect(Config.transcriptionChunkSeconds == 6.0,
                "default unchanged — the trade is latency, and it is not mine to make")
    }

    @Test("the whole-file pass still beats every live window")
    func wholeFileBeatsLive() {
        // Which is why the live window is a latency choice rather than an
        // accuracy one: accuracy is recovered afterwards, and the live path's
        // job is a caption that arrives while the sentence still matters.
        let bestLiveWER = 0.2221
        let wholeFileWER = 0.1731
        #expect(wholeFileWER < bestLiveWER)
    }

    @Test("the filter's own bars stay where the live path needs them")
    func liveThresholdsUnchanged() {
        // Whatever the whole-file pass wants, the live path still shows captions
        // on screen while people are talking. Nothing measured here justified
        // moving the no-speech or compression bars, which are what block
        // memorized sign-off phrases over room noise and repetition loops.
        #expect(LocalWhisperTranscription.isReliable(avgLogProbability: -0.5,
                                                     noSpeechProbability: 0.9,
                                                     compressionRatio: 1.0) == false)
        #expect(LocalWhisperTranscription.isReliable(avgLogProbability: -0.5,
                                                     noSpeechProbability: 0.1,
                                                     compressionRatio: 3.0) == false)
        // Lowering the confidence floor must not weaken either of those.
        #expect(LocalWhisperTranscription.isReliable(avgLogProbability: -50,
                                                     noSpeechProbability: 0.9,
                                                     compressionRatio: 1.0,
                                                     logProbabilityFloor: -99) == false)
    }

    @Test("a decoder-prompt glossary deletes speech on the whole-file pass, every tier")
    func wholeFileGlossaryDeletesSpeech() {
        // 2026-08-09, glossaryModeSweep, fixtures 10-15, WER over the four
        // scoreable ones. The same knob that lifts term recall on the live
        // path collapses the whole-file pass, worst exactly where the user
        // paid for accuracy:
        //
        //            off WER / D        mined WER / D        key recall
        //   base     0.1854 / 138      0.4257 /  943        21/22
        //   small    0.1429 / 125      0.2112 /  356        20/22
        //   large    0.1339 / 139      0.9522 / 2757        18/22 (mined: 0/22)
        //
        // Self-priming (mining the first pass) is no rescue: small D 753.
        // The effect is chaotic per fixture — the same 34-character glossary
        // improved fixture 10 and tripled the error on fixture 11 — so there
        // is no safe subset to allow; the whole-file decode runs bare, and
        // vocabulary returns as TEXT via GlossaryRestore, which cannot delete.
        let offDeletions = [138, 125, 139]
        let minedDeletions = [943, 356, 2757]
        for (off, mined) in zip(offDeletions, minedDeletions) {
            #expect(mined > off * 2, "glossary at least doubles deletions on every tier")
        }
        let largeMinedWER = 0.9522
        #expect(largeMinedWER > 0.9, "large with a mined glossary deletes nearly everything")
    }

    @Test("the local tiers stand against Fireflies on identical audio")
    func firefliesBaseline() {
        // 2026-08-09, the six fixtures with independent references, Fireflies
        // transcripts of the same source recordings sliced to the same 300 s
        // windows, one scorer. Whole-file pass, no glossary — the shipped
        // post-call configuration.
        //
        //             03 Zimb   04 UK     10 CART   11 CART   12 weak   13 weak    mean
        //   fireflies  0.2363    0.0718    0.0793    0.0770    0.1777    0.2536    0.1493
        //   base       0.3497    0.1584    0.1530    0.1366    0.1457    0.3061    0.2083
        //   small      0.2632    0.0953    0.1133    0.0828    0.1351    0.2405    0.1550
        //   large      0.2082    0.0903    0.0708    0.0785    0.1517    0.2347    0.1390
        //
        // Large wins four of six outright (03, 10, 12, 13), ties 11 within
        // noise, and loses only the clean British studio interview — its lead
        // concentrates exactly on the accented recordings, which is the
        // product's pitch. Small sits just behind the cloud baseline on the
        // mean; the earlier four-fixture read that put it ahead did not
        // survive the harder corpus, and this table is the honest one. Base
        // is clearly behind.
        let fireflies = 0.1493, small = 0.1550, large = 0.1390, base = 0.2083
        #expect(large < fireflies)
        #expect(small > fireflies && small < fireflies * 1.1,
                "Balanced trails the cloud baseline, within ten percent")
        #expect(base > fireflies, "Fast tier is honestly behind the cloud baseline")
        let hardestAccent = (fireflies: 0.2363, large: 0.2082)
        #expect(hardestAccent.large < hardestAccent.fireflies,
                "the lead is largest where the accent is hardest")
    }

    @Test("the live glossary is a per-tier decision, and large loses it")
    func livePathGlossaryPerTier() {
        // 2026-08-09, live pipeline, fixtures 14/15, answer-key glossary:
        //
        //           terms off → key          words off → key
        //   small   0.53→0.93, 0.57→1.00    511→483, 736→712   the shipped win
        //   base    0.20→0.93, 0.29→0.86    440→314, 734→691   costly but net terms
        //   large   0.73→0.73, 0.71→1.00    559→296, 729→499   HALVED for ~nothing
        //
        // Large already hears most terms without help; the prompt only feeds
        // its failure mode. So prompt tokens are suppressed for every large
        // build, and large's vocabulary rides GlossaryRestore instead.
        #expect(LocalWhisperTranscription.suppressesGlossaryPrompt(model: "large-v3-v20240930"))
        #expect(LocalWhisperTranscription.suppressesGlossaryPrompt(model: "openai_whisper-large-v3-v20240930"))
        #expect(LocalWhisperTranscription.suppressesGlossaryPrompt(model: "large-v3"))
        #expect(!LocalWhisperTranscription.suppressesGlossaryPrompt(model: "small"))
        #expect(!LocalWhisperTranscription.suppressesGlossaryPrompt(model: "base"))
        #expect(!LocalWhisperTranscription.suppressesGlossaryPrompt(model: "openai_whisper-small"))
    }

    @Test("GlossaryRestore recovers terms without the decoder's content loss")
    func restoreRecoversWithoutDeleting() {
        // 2026-08-09, whole-file pass, the six term-carrying fixtures
        // (53-term key over 10-15), key terms as the user glossary, after the
        // plural/inflection fix. Deletions byte-identical to the bare decode
        // on every tier:
        //
        //           terms off → restore    WER off → restore (10-13)
        //   base    0.45 → 0.58            0.1854 → 0.1864
        //   small   0.66 → 0.77            0.1429 → 0.1448
        //   large   0.72 → 0.83            0.1339 → 0.1339  (identical)
        //
        // On the large tier — the default on capable hardware — restoration
        // is FREE to four decimals. The residual +3/+5 substitutions on
        // base/small are one token in ~500 against six or seven recovered
        // terms. The first corpus run of this feature caught it stripping
        // plurals ("RSPs" → "RSP", nine substitutions on one fixture); the
        // inflection branch in GlossaryRestore is what keeps this table
        // honest, and the gap to the decoder-key ceiling is the prose-shaped
        // corruptions ("piece" for PCE) a text pass must refuse to touch.
        let offRecall = [0.45, 0.66, 0.72]
        let restoreRecall = [0.58, 0.77, 0.83]
        for (off, restored) in zip(offRecall, restoreRecall) {
            #expect(restored > off + 0.1, "restore lifts every tier by 10+ points")
        }
        let largeWEROff = 0.1339, largeWERRestore = 0.1339
        #expect(largeWEROff == largeWERRestore,
                "on the default capable-hardware tier the recall is free")
    }

    @Test("the shipped lexicon earns casing-only, and fuzzy is a per-source privilege")
    func lexiconIsCasingOnly() {
        // 2026-08-10, nine scoreable fixtures, 230-term DomainLexicon.
        //
        // With fuzzy repair allowed for the lexicon: +0.4 WER on every tier —
        // out-of-lexicon acronyms were pulled into one-edit lexicon
        // neighbours (GAC→CAC, IDN→IDE, PTI→PTO). A user's glossary covers
        // the acronym space of the user's own calls; a generic lexicon
        // covers no one's, so proximity to it means nothing.
        //
        // Casing-only, re-measured: large off vs restore BYTE-IDENTICAL
        // (WER 0.1188, S 264, D 278, I 173 — both) while term recall rose
        // 0.72→0.83. Small and base carry +5/+3 substitutions, all from the
        // user-glossary fuzzy path measured acceptable earlier. Any future
        // vertical pack inherits casing-only and is safe by construction.
        let largeOff = (wer: 0.1188, subs: 264)
        let largeRestore = (wer: 0.1188, subs: 264)
        #expect(largeOff == largeRestore, "the lexicon must cost nothing")
        let fuzzyLexiconPenalty = 0.004
        #expect(fuzzyLexiconPenalty > 0.003,
                "recorded so nobody re-grants fuzzy to a bulk dictionary")
    }
}
