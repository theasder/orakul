import Foundation
import Testing
@testable import MeetGPT

/// A call captures two streams. When the meeting plays through speakers the
/// microphone hears it too, so remote speech arrives a second time under the
/// local label — which is why "Them" lines and "You" lines read the same. On
/// top of that, chunked Whisper re-emits its own tail and loops on near-silence.
///
/// The risk of fixing this is deleting real dialogue, so these tests weigh the
/// suppression cases against the must-keep cases.
@Suite("Transcript deduplication")
struct TranscriptDeduplicatorTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ text: String,
                       _ source: TranscriptSource = .system,
                       at offset: TimeInterval = 0) -> TranscriptEntry {
        TranscriptEntry(source: source, text: text,
                        timestamp: start.addingTimeInterval(offset))
    }

    // MARK: - Must suppress

    @Test("the same sentence heard on both tracks is dropped")
    func dropsCrossTrackEcho() {
        let them = entry("we should ship the pricing change on Friday", .system, at: 0)
        let echo = entry("We should ship the pricing change on Friday.", .mic, at: 1.5)
        #expect(TranscriptDeduplicator.isDuplicate(echo, of: [them]))
    }

    @Test("echo with small ASR differences is still dropped")
    func dropsImperfectEcho() {
        // The mic path colours the audio, so the second transcription differs.
        let them = entry("we should ship the pricing change on Friday", .system, at: 0)
        let echo = entry("we should ship the pricing changes on Friday", .mic, at: 2)
        #expect(TranscriptDeduplicator.isDuplicate(echo, of: [them]))
    }

    @Test("a chunk boundary re-emitting the previous tail is dropped")
    func dropsChunkOverlap() {
        // Chunked inference repeats the END of the last window at the START of
        // the next one, so the new line opens with words already recorded.
        let first = entry("so the plan is to raise the price and tell customers next week", .system, at: 0)
        let overlap = entry("and tell customers next week", .system, at: 6)
        #expect(TranscriptDeduplicator.isDuplicate(overlap, of: [first]))
    }

    @Test("a handover that merely shares a few words is kept")
    func keepsShortHandover() {
        // The distinction from the case above: the shared run is a small part
        // of the new line, which then says something new.
        let first = entry("so the plan is to raise the price and tell customers next week", .system, at: 0)
        let next = entry("next week I am on leave so someone else has to send that note", .system, at: 6)
        #expect(!TranscriptDeduplicator.isDuplicate(next, of: [first]))
    }

    @Test("Whisper looping on the same line is dropped")
    func dropsRepetitionLoop() {
        let line = entry("thanks for watching thanks for watching", .system, at: 0)
        let loop = entry("thanks for watching thanks for watching", .system, at: 3)
        #expect(TranscriptDeduplicator.isDuplicate(loop, of: [line]))
    }

    @Test("punctuation and casing do not hide a duplicate")
    func normalizesBeforeComparing() {
        let line = entry("Let's move on to the roadmap, then.", .system, at: 0)
        let same = entry("lets move on to the roadmap then", .mic, at: 1)
        #expect(TranscriptDeduplicator.isDuplicate(same, of: [line]))
    }

    @Test("an empty or punctuation-only line never reaches the transcript")
    func dropsEmpty() {
        #expect(TranscriptDeduplicator.isDuplicate(entry("...", .system, at: 0), of: []))
        #expect(TranscriptDeduplicator.isDuplicate(entry("   ", .system, at: 0), of: []))
    }

    // MARK: - Must keep

    @Test("the same sentence much later in the call is genuine")
    func keepsLaterRepeat() {
        let early = entry("we should ship the pricing change on Friday", .system, at: 0)
        let later = entry("we should ship the pricing change on Friday", .system, at: 600)
        #expect(!TranscriptDeduplicator.isDuplicate(later, of: [early]))
    }

    @Test("short agreements from both people are kept")
    func keepsShortReplies() {
        // "yes" / "right" legitimately recur seconds apart on both tracks;
        // fuzzy-matching them would delete real dialogue.
        let them = entry("yes exactly", .system, at: 0)
        let you = entry("yes exactly right", .mic, at: 2)
        #expect(!TranscriptDeduplicator.isDuplicate(you, of: [them]))
    }

    @Test("a genuine reply that shares words is kept")
    func keepsDistinctSentences() {
        let them = entry("we should ship the pricing change on Friday", .system, at: 0)
        let you = entry("I think Friday is too early for the pricing change to land", .mic, at: 3)
        #expect(!TranscriptDeduplicator.isDuplicate(you, of: [them]))
    }

    @Test("a longer follow-up that adds real content is kept")
    func keepsElaboration() {
        let first = entry("the migration is risky", .system, at: 0)
        let second = entry("the migration is risky because the backfill has never been tested at this size", .system, at: 4)
        // A strict prefix rule would drop this; it carries new information.
        #expect(!TranscriptDeduplicator.isDuplicate(second, of: [first]))
    }

    @Test("unrelated speech is untouched")
    func keepsUnrelated() {
        let them = entry("we should ship the pricing change on Friday", .system, at: 0)
        let you = entry("did anyone book the venue for the offsite", .mic, at: 2)
        #expect(!TranscriptDeduplicator.isDuplicate(you, of: [them]))
    }

    @Test("the search stops at the window instead of scanning the whole call")
    func stopsAtWindow() {
        let old = entry("we should ship the pricing change on Friday", .system, at: 0)
        let recent = entry("something else entirely happened here", .system, at: 100)
        let candidate = entry("we should ship the pricing change on Friday", .mic, at: 101)
        // The matching line is far outside the window, so this survives.
        #expect(!TranscriptDeduplicator.isDuplicate(candidate, of: [old, recent]))
    }

    // MARK: - Helpers

    @Test("tokenizing folds case, punctuation and apostrophes together")
    func tokenizes() {
        // "let's" and "lets" must collapse: two transcriptions of the same word
        // routinely disagree about the apostrophe, and counting that as a
        // difference is what let echo through.
        #expect(TranscriptDeduplicator.tokens("Let's go, now!") == ["lets", "go", "now"])
        #expect(TranscriptDeduplicator.tokens("lets go now") == ["lets", "go", "now"])
        #expect(TranscriptDeduplicator.tokens("").isEmpty)
    }

    @Test("similarity is order-insensitive overlap")
    func similarityScores() {
        #expect(TranscriptDeduplicator.similarity(["a", "b"], ["a", "b"]) == 1)
        #expect(TranscriptDeduplicator.similarity(["a", "b"], ["c", "d"]) == 0)
        #expect(TranscriptDeduplicator.similarity([], ["a"]) == 0)
    }
}

/// Diagnostics for the misses. Drops were already logged; a line the thresholds
/// let through left no trace, so "sometimes it still duplicates" could only be
/// answered by guessing at numbers.
@Suite("Dedup near-miss reporting")
struct TranscriptDeduplicatorNearMissTests {
    private func entry(_ text: String, at offset: TimeInterval,
                       source: TranscriptSource = .system) -> TranscriptEntry {
        TranscriptEntry(source: source, text: text,
                        timestamp: Date(timeIntervalSince1970: 1_000_000 + offset))
    }

    @Test("reports the closest line and its score")
    func reportsClosest() throws {
        let candidate = entry("we should ship the export rewrite on Friday", at: 6)
        let recent = [
            entry("completely unrelated budget discussion here", at: 0),
            entry("we should ship the export rewrite by Friday", at: 3),
        ]
        let near = try #require(TranscriptDeduplicator.closestScore(candidate, of: recent))
        #expect(near.text.contains("export rewrite by Friday"))
        #expect(near.score > 0.6)
    }

    @Test("ignores lines outside the time window")
    func respectsWindow() {
        let candidate = entry("we should ship the export rewrite on Friday", at: 600)
        let recent = [entry("we should ship the export rewrite by Friday", at: 0)]
        #expect(TranscriptDeduplicator.closestScore(candidate, of: recent) == nil)
    }

    @Test("returns nil for a line too short to score meaningfully")
    func skipsShortLines() {
        // Below fuzzyMinimumTokens the score is noise, and logging noise as a
        // near-miss would bury the real ones.
        let candidate = entry("okay sure", at: 3)
        let recent = [entry("okay sure thing", at: 0)]
        #expect(TranscriptDeduplicator.closestScore(candidate, of: recent) == nil)
    }

    @Test("is purely diagnostic — it never changes the drop decision")
    func doesNotAffectDecision() {
        // A near-miss must still be KEPT. If scoring it changed the outcome, the
        // diagnostic would be silently suppressing content.
        let candidate = entry("we should ship the export rewrite on Friday", at: 6)
        let recent = [entry("the budget review is moved to next week entirely", at: 3)]
        #expect(TranscriptDeduplicator.closestScore(candidate, of: recent) != nil)
        #expect(TranscriptDeduplicator.isDuplicate(candidate, of: recent) == false)
    }

    @Test("an empty window reports nothing rather than a zero score")
    func emptyWindow() {
        #expect(TranscriptDeduplicator.closestScore(
            entry("a reasonably long line of speech here", at: 0), of: []) == nil)
    }
}

/// Cross-track duplication is the reported failure: one utterance reaching both
/// the mic and the system tap, transcribed differently enough that token overlap
/// fell under the same-track threshold and BOTH copies were kept.
///
/// The pairs below are not invented — their Jaccard scores were MEASURED before
/// the thresholds were chosen. That mattered: the first pair tried scored 0.77 and
/// was already being dropped, so it would have tested nothing, and a genuine
/// paraphrase scored 0.24 against 0.12 for unrelated speech — too close to
/// separate lexically at all. The real gap is 0.55–0.72, and these sit in it at
/// 0.64.
@Suite("Cross-track duplicate suppression")
struct TranscriptDeduplicatorCrossTrackTests {
    private func entry(_ text: String, at offset: TimeInterval,
                       source: TranscriptSource) -> TranscriptEntry {
        TranscriptEntry(source: source, text: text,
                        timestamp: Date(timeIntervalSince1970: 2_000_000 + offset))
    }

    /// Measured sim 0.64 — below the same-track bar, above the cross-track one.
    private let systemLine = "we need to get legal to look at the liability cap before signing"
    private let micLine = "we need legal to look at that liability cap before we sign"

    @Test("the same sentence recognised differently on the two tracks is one line")
    func differentlyTranscribedCrossTrack() {
        let system = entry(systemLine, at: 0, source: .system)
        let mic = entry(micLine, at: 2, source: .mic)
        #expect(TranscriptDeduplicator.isDuplicate(mic, of: [system]))
    }

    @Test("the SAME wording gap on ONE track is kept")
    func sameTrackKeepsTheStricterBar() {
        // Same 0.64 pair, same source. Here the competing explanation — someone
        // actually said something similar again — is real, and dropping it would
        // lose content silently.
        let first = entry(systemLine, at: 0, source: .system)
        let second = entry(micLine, at: 2, source: .system)
        #expect(TranscriptDeduplicator.isDuplicate(second, of: [first]) == false)
    }

    @Test("a later cleaner system final identifies the earlier mic echo for replacement")
    func systemFinalPrefersLabeledSourceWhenOrderReverses() {
        let mic = entry(micLine, at: 0, source: .mic)
        let system = entry(systemLine, at: 2, source: .system)
        #expect(TranscriptDeduplicator.preferredMicEchoIndex(
            forSystem: system, in: [mic]) == 0)

        // Capture time can precede the mic entry even though a slower system
        // decode arrived afterward; source preference follows arrival state.
        let slowerSystem = entry(systemLine, at: -2, source: .system)
        #expect(TranscriptDeduplicator.preferredMicEchoIndex(
            forSystem: slowerSystem, in: [mic]) == 0)
    }

    @Test("a later system final never selects genuinely distinct microphone speech")
    func systemFinalKeepsDistinctMicSpeech() {
        let mic = entry(
            "I still need legal to sign off on the data clause", at: 0, source: .mic)
        let system = entry(
            "can we push the launch to the following Tuesday", at: 2, source: .system)
        #expect(TranscriptDeduplicator.preferredMicEchoIndex(
            forSystem: system, in: [mic]) == nil)
    }

    @Test("cross-track leniency expires — two people are not an echo")
    func crossTrackWindowIsNarrow() {
        // Beyond crossTrackWindow the two tracks are two speakers, not one sound
        // through two paths, so the strict threshold governs again.
        let system = entry(systemLine, at: 0, source: .system)
        let mic = entry(micLine, at: 12, source: .mic)
        #expect(TranscriptDeduplicator.isDuplicate(mic, of: [system]) == false)
    }

    @Test("genuinely different cross-track speech is never merged")
    func unrelatedCrossTrackSurvives() {
        // The risk of a lower bar is eating real dialogue. Measured at 0.12.
        let system = entry("can we push the launch to the following Tuesday", at: 0, source: .system)
        let mic = entry("I still need legal to sign off on the data clause", at: 2, source: .mic)
        #expect(TranscriptDeduplicator.isDuplicate(mic, of: [system]) == false)
    }

    @Test("short cross-track replies still require an exact match")
    func shortRepliesUnaffected() {
        // "yes" / "right" legitimately come from both people seconds apart, and
        // the lower threshold must not start deleting them.
        let system = entry("yes exactly", at: 0, source: .system)
        let mic = entry("yeah exactly", at: 1, source: .mic)
        #expect(TranscriptDeduplicator.isDuplicate(mic, of: [system]) == false)
    }

    @Test("the cross-track bar is genuinely looser than the same-track bar")
    func thresholdsAreOrdered() {
        #expect(TranscriptDeduplicator.crossTrackSimilarityThreshold
                < TranscriptDeduplicator.similarityThreshold)
        #expect(TranscriptDeduplicator.crossTrackWindow < TranscriptDeduplicator.window)
    }
}

@MainActor
@Suite("System-preferred cross-track ingestion", .serialized)
struct SystemPreferredCrossTrackIngestionTests {
    private let start = Date(timeIntervalSince1970: 3_000_000)

    @Test("mic-first echo is replaced by the labeled system final")
    func replacesMicFirstEcho() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.ingestStreamedLine(
            text: "we need legal to review the liability cap before we sign",
            source: .mic, transcriptionEngine: .deepgram, at: start)
        state.ingestStreamedLine(
            text: "we need legal to review that liability cap before signing",
            source: .system, speaker: "Speaker A", transcriptionEngine: .deepgram,
            at: start.addingTimeInterval(2))

        #expect(state.transcript.count == 1)
        #expect(state.transcript[0].source == .system)
        #expect(state.transcript[0].speaker == "Speaker A")
    }

    @Test("distinct mic speech remains when a system final follows")
    func preservesDistinctMicSpeech() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.ingestStreamedLine(
            text: "I still need legal to approve the separate data clause",
            source: .mic, transcriptionEngine: .deepgram, at: start)
        state.ingestStreamedLine(
            text: "can we move the customer launch to the following Tuesday",
            source: .system, speaker: "Speaker A", transcriptionEngine: .deepgram,
            at: start.addingTimeInterval(2))

        #expect(state.transcript.map(\.source) == [.mic, .system])
    }
}

/// Deepgram microphone hypotheses can accumulate several finalized system
/// utterances into one giant echo. Each individual comparison is too small to
/// catch that shape; the concatenated recent system window is the right unit.
@Suite("Cumulative cross-track echo suppression")
struct CumulativeCrossTrackEchoTests {
    private let start = Date(timeIntervalSince1970: 2_500_000)

    private var russianSystem: [TranscriptEntry] {
        [
            TranscriptEntry(
                source: .system,
                text: "Сегодня мы обсудим архитектуру новой платформы.",
                timestamp: start, speaker: "Speaker A",
                transcriptionEngine: .deepgram),
            TranscriptEntry(
                source: .system,
                text: "Сначала проверим интеграцию с системой платежей.",
                timestamp: start.addingTimeInterval(4), speaker: "Speaker A",
                transcriptionEngine: .deepgram),
            TranscriptEntry(
                source: .system,
                text: "Затем согласуем сроки запуска с командой.",
                timestamp: start.addingTimeInterval(8), speaker: "Speaker A",
                transcriptionEngine: .deepgram),
        ]
    }

    private let cumulativeRussianEcho = """
    Сегодня мы обсудим архитектуру новой платформы. Сначала проверим интеграцию \
    с системой платежей. Затем согласуем сроки запуска с командой.
    """

    @Test("a Russian mic copy spanning several Speaker A finals is dropped")
    func dropsMultilingualCumulativeEcho() {
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: cumulativeRussianEcho, source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output.isEmpty)
    }

    @Test("ASR substitutions inside a cumulative echo are tolerated")
    func toleratesRecognitionDifferences() {
        let varied = """
        Сегодня мы обсуждаем архитектуру новой платформы. Сначала проверим интеграцию \
        системы платежей. Затем согласуем сроки запуска вместе с командой.
        """
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: varied, source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output.isEmpty)
    }

    @Test("new user speech after the echoed prefix is preserved exactly")
    func keepsNovelMicSuffix() {
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: cumulativeRussianEcho + " Но я хочу уточнить план отката.",
            source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output == "Но я хочу уточнить план отката.")
    }

    @Test("a genuinely different mic turn is untouched")
    func keepsDifferentMicSpeech() {
        let reply = "Я предлагаю сначала провести отдельный тест безопасности."
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: reply, source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output == reply)
    }

    @Test("the asymmetric filter never rewrites system speech")
    func systemSpeechIsNeverFiltered() {
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: cumulativeRussianEcho, source: .system, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output == cumulativeRussianEcho)
    }

    @Test("an old system window cannot suppress a later repeated topic")
    func oldSpeechExpires() {
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: cumulativeRussianEcho, source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(
                TranscriptDeduplicator.cumulativeCrossTrackWindow + 20))
        #expect(output == cumulativeRussianEcho)
    }

    @Test("a runaway hypothesis fails safe without an unbounded LCS matrix")
    func oversizedHypothesisIsPreserved() {
        let oversized = Array(
            repeating: "архитектура",
            count: TranscriptDeduplicator.cumulativeEchoMaximumCandidateTokens + 1
        ).joined(separator: " ")
        let output = TranscriptDeduplicator.removingCumulativeCrossTrackEcho(
            from: oversized, source: .mic, recent: russianSystem,
            at: start.addingTimeInterval(10))
        #expect(output == oversized)
    }
}

/// Intra-chunk collapse. `batch.results` is an ARRAY and WhisperKit can return
/// more than one result for the same audio — decode retries and temperature
/// fallbacks each contribute their own segments. flatMap concatenated all of them,
/// so ONE chunk emitted the same utterance twice, worded differently by each pass.
///
/// This is the technical artefact behind "duplicates that are not the same but
/// differently transcribed", and it is a different mechanism from cross-track echo.
@Suite("Intra-chunk repeat collapse")
struct IntraChunkCollapseTests {
    @Test("two decode passes over one chunk collapse to one line")
    func collapsesRewordedRepeat() {
        let out = LocalWhisperTranscription.collapseIntraChunkRepeats([
            "we need to get legal to look at the liability cap before signing",
            "we need legal to look at that liability cap before we sign",
        ])
        #expect(out.count == 1)
    }

    @Test("an exact repeat collapses")
    func collapsesExactRepeat() {
        let line = "so the migration is scheduled for next Tuesday"
        #expect(LocalWhisperTranscription.collapseIntraChunkRepeats([line, line]).count == 1)
    }

    @Test("genuinely different speech in one chunk is kept")
    func keepsDistinctSpeech() {
        // Six seconds holds more than one sentence, and collapsing them would
        // delete content — the failure mode that matters here.
        let out = LocalWhisperTranscription.collapseIntraChunkRepeats([
            "can we push the launch to the following Tuesday",
            "I still need legal to sign off on the data clause",
        ])
        #expect(out.count == 2)
    }

    @Test("short interjections survive unless byte-identical")
    func shortFragmentsNeedExactMatch() {
        // "no, no" inside one chunk is real speech. Only an exact repeat collapses.
        #expect(LocalWhisperTranscription.collapseIntraChunkRepeats(["no", "not really"]).count == 2)
        #expect(LocalWhisperTranscription.collapseIntraChunkRepeats(["yes", "yes"]).count == 1)
    }

    @Test("order is preserved — the first wording wins")
    func preservesOrder() {
        let out = LocalWhisperTranscription.collapseIntraChunkRepeats([
            "first distinct sentence about the roadmap",
            "second distinct sentence about the budget",
            "first distinct sentence about the roadmap",
        ])
        #expect(out == ["first distinct sentence about the roadmap",
                        "second distinct sentence about the budget"])
    }

    @Test("a single candidate and an empty list pass through untouched")
    func trivialCases() {
        #expect(LocalWhisperTranscription.collapseIntraChunkRepeats([]).isEmpty)
        #expect(LocalWhisperTranscription.collapseIntraChunkRepeats(["only one"]) == ["only one"])
    }
}
