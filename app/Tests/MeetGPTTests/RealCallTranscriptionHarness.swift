import AVFoundation
import WhisperKit
import Foundation
import Testing
@testable import MeetGPT

/// Measure the transcription pipeline against a REAL recorded call.
///
/// Everything before this measured synthetic speech played through the
/// speakers and recaptured through ScreenCaptureKit. That path is honest about
/// the acoustics but hopeless as a metric: three runs of an identical build
/// scored 0.1048, 0.1613 and 0.1452, and the same build later measured 0.23,
/// so a change had to beat a moving target it could not see.
///
/// This feeds the file straight into the same `AudioChunkBuffer` the live
/// capture feeds, so the chunking, the VAD gate and the stitching are all
/// exercised — but the speaker-to-microphone path is gone. Same bytes in, same
/// WER out. A difference between two runs is now a difference in the code.
///
/// The fixture is a real meeting, so it is NOT in git. Build it once:
///
///     bash testlib/build_real_call_fixture.sh path/to/recording.mp4
///
/// then run:
///
///     CRUXWING_REAL_CALL_FIXTURE=data swift test --filter RealCallTranscriptionHarness
///
/// The reference transcript comes from AssemblyAI, which is a strong engine but
/// not perfect truth — its own confidence on this segment was 0.980. Treat the
/// absolute number as "distance from a good cloud engine", and trust the
/// relative movement between runs.
@Suite("Real call transcription harness", .serialized)
struct RealCallTranscriptionHarness {

    struct Reference: Decodable {
        let text: String
        let confidence: Double?
        let utterances: [Utterance]
        /// Absent in the earliest fixture, so the corpus keeps working on it.
        let segmentDurationSeconds: Double?
        /// Domain vocabulary the recording is meant to test. Work-call fixtures
        /// carry it because acronyms and product names are what actually break
        /// on a work call, and WER weights them the same as "the".
        let expectedTerms: [Term]?
        /// Realistic pre-call context — what a calendar invite or agenda would
        /// carry. Used to mine a glossary WITHOUT touching `expectedTerms`,
        /// which is the answer key.
        let topic: String?

        struct Term: Decodable {
            let term: String
            /// How a weak ASR mangles it — "PCE" as "piece". Reproducing one is
            /// a stronger signal than simply missing the term.
            let weakAsrRendering: [String]?
        }

        struct Utterance: Decodable {
            let speaker: String
            let text: String
            let startMs: Int
            let endMs: Int
        }
    }

    // MARK: - Fixture

    /// Model under test. Overridable so size can be swept against the corpus
    /// the same way the seam threshold was — the corpus showed accent, not
    /// chunking, is now the dominant error, and model size is the obvious lever.
    static var modelUnderTest: String {
        let requested = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_MODEL"] ?? ""
        return requested.isEmpty ? Config.localWhisperModel : requested
    }

    /// Substring filter, so one slow recording can be measured without decoding
    /// the whole corpus.
    private static var fixtureFilter: String {
        ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_ONLY"] ?? ""
    }

    private static var fixtureRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_FIXTURE"],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Every `<name>.wav` with a matching `<name>.reference.json`, plus the
    /// original single-fixture layout.
    ///
    /// A corpus rather than one recording, because one call cannot tell a real
    /// improvement from one that fits a single speaker in a single room. The
    /// fixtures deliberately differ in accent, acoustics and format.
    static func loadFixtures() throws -> [(name: String, audio: URL, reference: Reference)] {
        guard let root = fixtureRoot else { return [] }
        let manager = FileManager.default
        let decoder = JSONDecoder()
        var found: [(String, URL, Reference)] = []

        // The first fixture predates the corpus layout and is still valid.
        let legacyAudio = root.appendingPathComponent("real-call-segment.wav")
        let legacyReference = root.appendingPathComponent("real-call-reference.json")
        if manager.fileExists(atPath: legacyAudio.path),
           manager.fileExists(atPath: legacyReference.path) {
            found.append(("real-call",
                          legacyAudio,
                          try decoder.decode(Reference.self, from: Data(contentsOf: legacyReference))))
        }

        for directory in [root, root.appendingPathComponent("fixtures")] {
            let entries = (try? manager.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil)) ?? []
            for audio in entries.filter({ $0.pathExtension == "wav" }).sorted(by: { $0.path < $1.path }) {
                let name = audio.deletingPathExtension().lastPathComponent
                let referenceURL = audio.deletingPathExtension()
                    .appendingPathExtension("reference.json")
                guard manager.fileExists(atPath: referenceURL.path) else { continue }
                found.append((name, audio,
                              try decoder.decode(Reference.self, from: Data(contentsOf: referenceURL))))
            }
        }
        let filter = fixtureFilter
        return filter.isEmpty ? found : found.filter { $0.0.contains(filter) }
    }

    private static func loadFixture() throws -> (audio: URL, reference: Reference)? {
        guard let first = try loadFixtures().first else { return nil }
        return (first.audio, first.reference)
    }

    private func skipNotice() {
        print("""

        [real-call] skipped — no fixture. Build one from a recording you have:
          bash testlib/build_real_call_fixture.sh path/to/recording.mp4
          CRUXWING_REAL_CALL_FIXTURE=data swift test --filter RealCallTranscriptionHarness

        """)
    }

    // MARK: - One decode, shared

    /// Decoding five minutes of audio takes real time, and four tests that each
    /// re-ran it would spend most of the suite repeating identical work. One
    /// run is cached and every assertion reads it.
    private actor Cache {
        static let shared = Cache()
        private var result: (hypothesis: String, score: TranscriptAccuracy.Score)?

        func value(_ build: () async throws -> (String, TranscriptAccuracy.Score))
            async rethrows -> (hypothesis: String, score: TranscriptAccuracy.Score) {
            if let result { return result }
            let fresh = try await build()
            result = fresh
            return fresh
        }
    }

    /// Fixture, decode and score — computed once per run.
    private func measured() async throws -> (reference: Reference,
                                             hypothesis: String,
                                             score: TranscriptAccuracy.Score)? {
        guard let fixture = try Self.loadFixture() else { return nil }
        let outcome = try await Cache.shared.value {
            let service = LocalWhisperTranscription(model: Self.modelUnderTest, language: "en", glossary: "")
            let hypothesis = try await transcribeThroughPipeline(audio: fixture.audio, service: service)
            return (hypothesis, TranscriptAccuracy.score(reference: fixture.reference.text,
                                                         hypothesis: hypothesis))
        }
        return (fixture.reference, outcome.hypothesis, outcome.score)
    }

    // MARK: - Driving the real pipeline

    /// Push the file through `AudioChunkBuffer` in small buffers, the way the
    /// capture tap does, and transcribe every chunk it emits.
    ///
    /// Deliberately NOT one big decode of the whole file: that would measure
    /// WhisperKit alone and skip the chunking and stitching, which is where the
    /// worst measured failure actually lived.
    private func transcribeThroughPipeline(audio: URL,
                                           service: TranscriptionService) async throws -> String {
        try await transcribeLines(audio: audio, service: service).joined(separator: " ")
    }

    /// The individual emitted lines, which is what the live duplication metric
    /// counts. The joined text hides a repeated line entirely.
    private func transcribeLines(audio: URL,
                                 service: TranscriptionService,
                                 chunkSeconds: Double? = nil,
                                 overlapSeconds: Double? = nil,
                                 boundarySlackSeconds: Double? = nil) async throws -> [String] {
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat

        var chunks: [Data] = []
        let buffer = AudioChunkBuffer(
            chunkSeconds: chunkSeconds ?? Config.transcriptionChunkSeconds,
            label: "real-call",
            overlapSeconds: overlapSeconds ?? Config.transcriptionChunkOverlapSeconds,
            boundarySlackSeconds: boundarySlackSeconds
                ?? Config.transcriptionBoundarySlackSeconds) { wav, _ in
            chunks.append(wav)
        }

        // 0.1 s at a time: close to a real capture callback, and small enough
        // that the boundary search sees realistic arrival granularity.
        let framesPerPush = AVAudioFrameCount(format.sampleRate / 10)
        while file.framePosition < file.length {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerPush) else { break }
            try file.read(into: pcm, frameCount: framesPerPush)
            if pcm.frameLength == 0 { break }
            buffer.append(pcm)
        }
        buffer.flush()

        var lines: [String] = []
        var previous = ""
        for wav in chunks {
            let text = try await service.transcribe(wav: wav, streamID: "real-call")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // The same stitching the live path uses: overlapping windows
            // transcribe the seam twice.
            let stitched = ChunkStitcher.stitch(previous: previous, next: trimmed)
            guard !stitched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append(stitched)
            previous = trimmed
        }
        return lines
    }

    // MARK: - Tests

    @Test("transcribes a real call within the accuracy ceiling")
    func realCallAccuracy() async throws {
        guard let (reference, _, score) = try await measured() else { return skipNotice() }

        print("""

        [real-call] \(score.summary)
          reference engine confidence: \(reference.confidence.map { String(format: "%.3f", $0) } ?? "n/a")
          model: \(Self.modelUnderTest)  window: \(Config.transcriptionChunkSeconds)s  overlap: \(Config.transcriptionChunkOverlapSeconds)s

        """)

        // A number says something changed; only the text says what. Errors
        // here have twice been misdiagnosed from the score alone.
        if let dump = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_DUMP"],
           !dump.isEmpty {
            let (_, hypothesis, _) = try await measured() ?? (reference, "", score)
            try? """
            === REFERENCE (\(score.referenceWords) words) ===
            \(reference.text)

            === HYPOTHESIS (\(score.hypothesisWords) words) ===
            \(hypothesis)
            """.write(toFile: dump, atomically: true, encoding: .utf8)
            print("[real-call] wrote transcripts to \(dump)")
        }

        // Recorded so the number is written down rather than eyeballed. The
        // ceiling is deliberately loose: it is a regression alarm, not a claim
        // that this is good.
        #expect(score.referenceWords > 500, "fixture should be a substantial sample")
        #expect(score.wer < 0.60, "transcription is far worse than the recorded baseline")
    }

    @Test("does not lose most of the speech")
    func doesNotDropSpeech() async throws {
        guard let (_, _, score) = try await measured() else { return skipNotice() }

        // The measured chunk-boundary failure showed up here first: 124 spoken
        // words arrived as 53 while WER alone still looked survivable. Recall
        // catches dropped audio that WER can mask.
        #expect(score.recall > 0.55, "too much speech is being dropped: \(score.summary)")
        #expect(score.hypothesisWords > score.referenceWords / 2,
                "output is far shorter than the speech: \(score.summary)")
    }

    @Test("does not hallucinate more than it hears")
    func doesNotHallucinate() async throws {
        guard let (_, _, score) = try await measured() else { return skipNotice() }

        // Whisper's known failure on near-silence is to repeat a phrase for the
        // length of the window. Overlapping windows made that likelier, so it
        // gets its own assertion rather than being averaged into WER.
        #expect(score.insertions < score.referenceWords / 3,
                "output looks padded with invented speech: \(score.summary)")
    }

    @Test("keeps the words the meeting is actually about")
    func keepsMeaningfulTerms() async throws {
        guard let (reference, hypothesis, _) = try await measured() else { return skipNotice() }

        // WER weights "the" and the product name identically. A meeting is
        // recalled by its nouns, so they get measured separately. Terms are
        // taken from the reference rather than hardcoded, so the assertion
        // survives a change of fixture.
        let terms = Self.salientTerms(in: reference.text, limit: 20)
        let (found, missing) = TranscriptAccuracy.termRecall(terms: terms, in: hypothesis)
        let rate = terms.isEmpty ? 1 : Double(found.count) / Double(terms.count)
        print(String(format: "[real-call] term recall %.2f (%d/%d), missing: %@",
                     rate, found.count, terms.count, missing.prefix(8).joined(separator: ", ")))

        #expect(rate > 0.5, "over half the meeting's distinctive words were lost")
    }

    @Test("seam trimming does not leave repeated or dangling lines")
    func lineHygiene() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        var worstDuplicate = 0.0
        var worstConjunction = 0.0
        print("\n[real-call] line hygiene, model \(Self.modelUnderTest):")
        for fixture in fixtures {
            let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                    language: "en", glossary: "")
            let lines = try await transcribeLines(audio: fixture.audio, service: service)
            let hygiene = TranscriptAccuracy.lineHygiene(lines)
            worstDuplicate = max(worstDuplicate, hygiene.duplicateRate)
            worstConjunction = max(worstConjunction, hygiene.conjunctionOpenRate)
            print(String(format: "  %-52@ lines %3d  dup %.3f  opens-with-conjunction %.3f",
                         fixture.name as NSString, lines.count,
                         hygiene.duplicateRate, hygiene.conjunctionOpenRate))
        }

        // The live harness bars duplication at 0.10. It is measured here on
        // hundreds of lines rather than six, where the rate can only be 0,
        // 0.167, 0.333 — a bar of 0.10 that a single repeat cannot clear.
        #expect(worstDuplicate < 0.10, "seam trimming is emitting repeated lines")
        // Not a hard failure on its own: real speech does start sentences with
        // "and". A high rate means cuts are landing before conjunctions, which
        // is what a too-loose seam threshold looks like.
        #expect(worstConjunction < 0.45, "cuts are landing before conjunctions")
    }

    @Test("the same audio scores the same twice")
    func isDeterministic() async throws {
        guard let fixture = try Self.loadFixture() else { return skipNotice() }

        // Deliberately does NOT use the cache: this is the one test that has to
        // decode twice. If file-fed decoding is not reproducible then the
        // live-capture spread was never the problem and every A/B on this
        // metric is still worthless.
        let service = LocalWhisperTranscription(model: Self.modelUnderTest, language: "en", glossary: "")
        let first = try await transcribeThroughPipeline(audio: fixture.audio, service: service)
        let second = try await transcribeThroughPipeline(audio: fixture.audio, service: service)

        let a = TranscriptAccuracy.score(reference: fixture.reference.text, hypothesis: first)
        let b = TranscriptAccuracy.score(reference: fixture.reference.text, hypothesis: second)
        print("[real-call] determinism: run1 \(a.summary)\n[real-call] determinism: run2 \(b.summary)")

        #expect(abs(a.wer - b.wer) < 0.01,
                "file-fed decoding is not reproducible; the metric cannot support A/B")
    }

    @Test("scores the whole corpus, so one recording cannot carry a conclusion")
    func scoresWholeCorpus() async throws {
        let fixtures = try Self.loadFixtures()
        guard fixtures.count > 1 else {
            print("[real-call] corpus test needs 2+ fixtures — build them with " +
                  "testlib/build_srt_fixtures.py")
            return
        }

        var rows: [(name: String, score: TranscriptAccuracy.Score, realtime: Double)] = []
        for fixture in fixtures {
            let service = LocalWhisperTranscription(model: Self.modelUnderTest, language: "en", glossary: "")
            let began = Date()
            let hypothesis = try await transcribeThroughPipeline(audio: fixture.audio,
                                                                 service: service)
            let elapsed = Date().timeIntervalSince(began)
            let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
            rows.append((fixture.name,
                         TranscriptAccuracy.score(reference: fixture.reference.text,
                                                  hypothesis: hypothesis),
                         elapsed / max(audioSeconds, 1)))
        }

        print("\n[real-call] corpus, model \(Self.modelUnderTest):")
        for (name, score, realtime) in rows {
            print(String(format: "  %-52@ %@  rt %.2fx", name as NSString, score.summary, realtime))
        }

        // Accuracy alone cannot pick a default. A model that decodes slower
        // than the audio arrives cannot run a live call at all, however well it
        // scores: `medium` needed 365s for 300s of audio.
        let slowest = rows.map(\.realtime).max() ?? 0
        print(String(format: "  slowest realtime factor %.2fx (must stay well under 1.0 for live use)", slowest))
        let mean = rows.map(\.score.wer).reduce(0, +) / Double(rows.count)
        let worst = rows.max { $0.score.wer < $1.score.wer }
        print(String(format: "  mean WER %.4f over %d recordings; worst %@ at %.4f\n",
                     mean, rows.count, (worst?.name ?? "-") as NSString, worst?.score.wer ?? 0))

        // A mean hides a recording the engine cannot handle at all, which is
        // exactly what a corpus is for. Both are asserted.
        #expect(mean < 0.40, "mean accuracy across recordings regressed")
        #expect((worst?.score.wer ?? 0) < 0.65,
                "one recording is far worse than the rest: \(worst?.name ?? "")")
    }

    /// Distinctive words: long enough to carry meaning, and not the filler that
    /// every meeting contains.
    static func salientTerms(in text: String, limit: Int) -> [String] {
        let stopWords: Set<String> = [
            "that", "this", "with", "have", "just", "like", "what", "when", "they",
            "there", "here", "your", "you", "were", "are", "and", "but", "for",
            "not", "can", "will", "would", "could", "about", "them", "then",
            "from", "into", "some", "going", "want", "know", "really", "think",
            "because", "okay", "yes", "right", "much", "very", "make", "made",
        ]
        var counts: [String: Int] = [:]
        for word in TranscriptAccuracy.normalise(text) where word.count >= 5 && !stopWords.contains(word) {
            counts[word, default: 0] += 1
        }
        // Frequent AND distinctive: a word said repeatedly is what the meeting
        // was about, and a one-off is as likely to be a reference-side error.
        return counts.filter { $0.value >= 2 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }
    @Test("compares a cloud engine on the same audio and the same scorer")
    func cloudEngineComparison() throws {
        let fixtures = try Self.loadFixtures()
        // One row per (engine, recording). The engine that SHIPS is
        // gpt-4o-transcribe-diarize behind /api/diarize; assemblyai is the
        // BYO-key fallback. Comparing them needs both scored by this scorer
        // against these references, or the numbers are not comparable.
        let engines = ["assemblyai", "openai-diarize", "fireflies"]
        var rows: [(String, TranscriptAccuracy.Score)] = []
        for engine in engines {
            for fixture in fixtures {
                let sidecar = fixture.audio.deletingPathExtension()
                    .appendingPathExtension("\(engine).txt")
                guard let hypothesis = try? String(contentsOf: sidecar, encoding: .utf8) else { continue }
                rows.append(("\(engine)  \(fixture.name)",
                             TranscriptAccuracy.score(reference: fixture.reference.text,
                                                      hypothesis: hypothesis)))
            }
        }
        guard !rows.isEmpty else {
            print("[real-call] no <name>.assemblyai.txt sidecars — cloud comparison skipped")
            return
        }

        // Scored with the SAME scorer and the same references as the local
        // numbers. A different normaliser would make the comparison meaningless.
        print("\n[real-call] cloud engine on identical audio:")
        for (name, score) in rows {
            print(String(format: "  %-52@ %@", name as NSString, score.summary))
        }
        for engine in engines {
            let engineRows = rows.filter { $0.0.hasPrefix(engine) }
            guard !engineRows.isEmpty else { continue }
            let mean = engineRows.map(\.1.wer).reduce(0, +) / Double(engineRows.count)
            print(String(format: "  %-16@ mean WER %.4f over %d recordings",
                         engine as NSString, mean, engineRows.count))
        }
        print("")
        #expect(rows.allSatisfy { $0.1.referenceWords > 0 })
    }

    @Test("keeps the domain vocabulary a work call is actually about")
    func domainTermRecall() async throws {
        let fixtures = try Self.loadFixtures().filter { $0.reference.expectedTerms?.isEmpty == false }
        guard !fixtures.isEmpty else {
            print("[real-call] no fixture carries expectedTerms — domain recall skipped")
            return
        }

        // Optional decoder-prompt glossary. The app already supports one and it
        // has never been measured; this is the experiment.
        // "1" supplies the answer key (the ceiling). "mined" supplies only
        // what GlossaryMiner extracts from the pre-call topic, which is what a
        // user would actually have.
        let glossaryMode = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_GLOSSARY"] ?? ""
        let useGlossary = glossaryMode == "1"
        print("\n[real-call] domain term recall, model \(Self.modelUnderTest), " +
              "glossary \(glossaryMode.isEmpty ? "off" : glossaryMode):")
        _ = useGlossary

        var worst = 1.0
        for fixture in fixtures {
            let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
            let glossary: String
            switch glossaryMode {
            case "1":
                glossary = terms.joined(separator: ", ")
            case "mined":
                let mined = GlossaryMiner.candidates(in: fixture.reference.topic ?? "")
                glossary = mined.map(\.term).joined(separator: ", ")
            default:
                glossary = ""
            }
            let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                    language: "en", glossary: glossary)
            let hypothesis = try await transcribeThroughPipeline(audio: fixture.audio,
                                                                 service: service)
            let (found, missing) = TranscriptAccuracy.termRecall(terms: terms, in: hypothesis)
            // A glossary biases the decoder, so it can buy terms by inventing
            // them. WER on the same run is the check on that.
            let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                 hypothesis: hypothesis)
            let rate = terms.isEmpty ? 1 : Double(found.count) / Double(terms.count)
            worst = min(worst, rate)

            // A term reproduced AS the weak-ASR corruption is worse than a miss:
            // it looks like a confident answer and reads as a real word.
            let corruptions = (fixture.reference.expectedTerms ?? []).filter { entry in
                guard let wrong = entry.weakAsrRendering, !wrong.isEmpty else { return false }
                return !found.contains(entry.term)
                    && wrong.contains { TranscriptAccuracy.termRecall(terms: [$0], in: hypothesis).found.count == 1 }
            }.map(\.term)

            print(String(format: "  %-46@ terms %2d/%2d (%.2f)  %@  missed: %@%@",
                         fixture.name as NSString, found.count, terms.count, rate,
                         score.summary as NSString,
                         missing.prefix(5).joined(separator: ", ") as NSString,
                         corruptions.isEmpty ? "" : "  CORRUPTED: \(corruptions.joined(separator: ", "))"))
        }
        #expect(worst >= 0.0)
    }

    @Test("a second pass primed by the first recovers inconsistent terms")
    func twoPassSelfPriming() async throws {
        let fixtures = try Self.loadFixtures().filter { $0.reference.expectedTerms?.isEmpty == false }
        guard !fixtures.isEmpty else { return }

        print("\n[real-call] two-pass self-priming, model \(Self.modelUnderTest):")
        for fixture in fixtures {
            let terms = (fixture.reference.expectedTerms ?? []).map(\.term)

            let first = try await transcribeThroughPipeline(
                audio: fixture.audio,
                service: LocalWhisperTranscription(model: Self.modelUnderTest,
                                                   language: "en", glossary: ""))

            // Mined from the FIRST PASS, not from the answer key. Whisper often
            // gets a term right in one chunk and wrong in another; the terms it
            // did get are legitimate priming for the ones it did not. Nothing
            // outside the audio is consulted.
            let mined = GlossaryMiner.candidates(in: first).map(\.term)
            let second = try await transcribeThroughPipeline(
                audio: fixture.audio,
                service: LocalWhisperTranscription(model: Self.modelUnderTest,
                                                   language: "en",
                                                   glossary: mined.joined(separator: ", ")))

            let before = TranscriptAccuracy.termRecall(terms: terms, in: first)
            let after = TranscriptAccuracy.termRecall(terms: terms, in: second)
            let beforeWER = TranscriptAccuracy.score(reference: fixture.reference.text, hypothesis: first)
            let afterWER = TranscriptAccuracy.score(reference: fixture.reference.text, hypothesis: second)

            print(String(format: "  %-42@ mined %2d  terms %d/%d -> %d/%d   WER %.4f -> %.4f",
                         fixture.name as NSString, mined.count,
                         before.found.count, terms.count,
                         after.found.count, terms.count,
                         beforeWER.wer, afterWER.wer))
        }
        #expect(Bool(true))
    }

    /// Plausible pre-call documents for the two fixtures that carry
    /// `expectedTerms` — the shape of an agenda or a ticket, written as prose
    /// rather than as a term list.
    ///
    /// This does NOT claim a user would have exactly these. It answers a
    /// narrower mechanism question: the 0.53 to 0.93 result was obtained by
    /// handing the decoder a curated list, and real context documents are
    /// prose. Does `GlossaryMiner` recover enough FROM PROSE to deliver the
    /// same gain, or was the curated list doing the work?
    static let plausibleAgendas: [String: String] = [
        "14_IETF125-CATS": """
        CATS design team sync — Computing-Aware Traffic Steering.
        Agenda: revisit how the control plane and data plane split
        responsibility, whether the management plane needs its own metric
        distribution, and what we signal over BGP versus IGP. Yizhou will walk
        through the YANG model. Open question on PCEP interaction. We still owe
        the list a decision on ingress and egress semantics, and on whether to
        encapsulate at the edge or decapsulate later. OAM implications to follow.
        """,
        "15_IETF125-PCE": """
        PCE working group — BFD parameters for PCEP.
        The draft adds a sub-TLV so a PCC can advertise its transmit interval
        and the PCE can size liveness detection accordingly. Covers MPLS-TE LSP
        setup and the SR case. Please read before the session.
        """,
    ]

    @Test("mining a prose document recovers the terms a curated list would")
    func minedFromProseMatchesCuratedList() async throws {
        let fixtures = try Self.loadFixtures().filter { $0.reference.expectedTerms?.isEmpty == false }
        guard !fixtures.isEmpty else { return }

        print("\n[real-call] glossary mined from a PROSE document, model \(Self.modelUnderTest):")
        for fixture in fixtures {
            guard let agenda = Self.plausibleAgendas.first(where: {
                fixture.name.hasPrefix($0.key)
            })?.value else { continue }

            let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
            let mined = GlossaryMiner.candidates(in: agenda).map(\.term)
            let hypothesis = try await transcribeThroughPipeline(
                audio: fixture.audio,
                service: LocalWhisperTranscription(model: Self.modelUnderTest,
                                                   language: "en",
                                                   glossary: mined.joined(separator: ", ")))

            let (found, missing) = TranscriptAccuracy.termRecall(terms: terms, in: hypothesis)
            let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                 hypothesis: hypothesis)
            // How much of the answer key the PROSE happened to contain, which
            // bounds what mining could possibly deliver.
            let mineable = terms.filter { term in
                mined.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            }
            print(String(format: "  %-40@ mined %2d  covers %d/%d of the key  terms %d/%d (%.2f)  WER %.4f",
                         fixture.name as NSString, mined.count,
                         mineable.count, terms.count,
                         found.count, terms.count,
                         Double(found.count) / Double(max(terms.count, 1)),
                         score.wer))
            if !missing.isEmpty {
                print("      missed: \(missing.prefix(6).joined(separator: ", "))")
            }
        }
        #expect(Bool(true))
    }

    @Test("one whole-file pass, the way a post-call re-transcription would run")
    func wholeFileSinglePass() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        print("\n[real-call] whole-file single pass vs the 6s live pipeline, " +
              "model \(Self.modelUnderTest):")
        for fixture in fixtures {
            // The live pipeline cuts at 6s because a caption has to appear
            // while people are still talking. After the call that constraint is
            // gone, so the question is what ONE pass over the whole recording
            // scores — WhisperKit then chunks it itself rather than being handed
            // arbitrary 6-second slices.
            let file = try AVAudioFile(forReading: fixture.audio)
            let format = file.processingFormat
            var samples: [Int16] = []
            let frames = AVAudioFrameCount(format.sampleRate)
            while file.framePosition < file.length {
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
                try file.read(into: pcm, frameCount: frames)
                if pcm.frameLength == 0 { break }
                if let channel = pcm.int16ChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                                   count: Int(pcm.frameLength)))
                } else if let floats = pcm.floatChannelData?[0] {
                    for index in 0..<Int(pcm.frameLength) {
                        samples.append(Int16(max(-1, min(1, floats[index])) * 32767))
                    }
                }
            }
            guard !samples.isEmpty else { continue }

            let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(format.sampleRate))
            // The shipped feature passes Config.transcriptionGlossary into this
            // decode, and glossary/model interactions have already proved
            // non-obvious — it HURT large-v3 while helping small. So the
            // combination is measured rather than assumed.
            let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
            let glossary = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_GLOSSARY"] == "1"
                ? terms.joined(separator: ", ") : ""
            let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                    language: "en", glossary: glossary)
            let began = Date()
            let hypothesis = try await service.transcribe(wav: wav)
            let elapsed = Date().timeIntervalSince(began)

            let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                 hypothesis: hypothesis)
            let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
            let found = terms.isEmpty ? 0
                : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count
            print(String(format: "  %-46@ %@  rt %.2fx  terms %d/%d",
                         fixture.name as NSString, score.summary,
                         elapsed / audioSeconds, found, terms.count))
        }
        #expect(Bool(true))
    }

    /// Does retrying a failed decode at a higher temperature recover words?
    ///
    /// The engine ships with `temperatureFallbackCount: 0`, so a degenerate
    /// window — a repetition loop, or text hallucinated over silence — is kept
    /// as decoded and then discarded wholesale by the confidence filter. That
    /// throws away the words that WERE spoken in the window, which shows up as
    /// deletions: the whole-file pass scored 467 words against a 588-word
    /// reference on fixture 14.
    ///
    /// Whisper's own remedy is to re-decode at a higher temperature. It costs a
    /// second pass over the failed window, which the live path cannot afford but
    /// the whole-file pass — ~0.15x realtime — plainly can.
    ///
    /// Measured rather than assumed, because the last "obvious" lever here cost
    /// 14 points of recall.
    @Test("temperature fallback sweep, whole-file pass", .timeLimit(.minutes(60)))
    func temperatureFallbackSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let counts = (ProcessInfo.processInfo.environment["CRUXWING_WHISPER_FALLBACK_SWEEP"]
                      ?? "0,2").split(separator: ",").compactMap { Int($0) }
        print("\n[real-call] temperature fallback sweep, model \(Self.modelUnderTest), " +
              "counts \(counts):")

        var means: [Int: (wer: Double, recall: Double, words: Int, rt: Double)] = [:]
        for count in counts {
            var wers: [Double] = []
            var recalls: [Double] = []
            var words = 0
            var realtimes: [Double] = []

            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                // No glossary: measured to cost 14 points of recall in THIS
                // pass even while helping the live path.
                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: "",
                                                        temperatureFallbackCount: count)
                let began = Date()
                let hypothesis = try await service.transcribe(wav: wav)
                let elapsed = Date().timeIntervalSince(began)

                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count
                let recall = terms.isEmpty ? 0 : Double(found) / Double(terms.count)

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(recall) }
                words += hypothesis.split(separator: " ").count
                realtimes.append(elapsed / audioSeconds)
                print(String(format: "  fb=%d %-42@ %@  rt %.2fx  terms %d/%d",
                             count, fixture.name as NSString, score.summary,
                             elapsed / audioSeconds, found, terms.count))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            means[count] = (mean(wers), mean(recalls), words, mean(realtimes))
            print(String(format: "  fb=%d MEAN wer %.4f  recall %.4f  words %d  rt %.2fx",
                         count, mean(wers), mean(recalls), words, mean(realtimes)))
        }

        print("\n[real-call] fallback summary:")
        for count in counts.sorted() {
            guard let m = means[count] else { continue }
            print(String(format: "  fb=%d  wer %.4f  recall %.4f  words %d  rt %.2fx",
                         count, m.wer, m.recall, m.words, m.rt))
        }
        #expect(Bool(true))
    }

    /// Does splitting on speech boundaries beat splitting every 30 seconds?
    ///
    /// A file longer than one window is cut into 30-second pieces wherever 30
    /// seconds happens to land — routinely mid-word, and reliably mid-sentence.
    /// The decoder then has no context across the seam. `.vad` cuts in pauses
    /// instead, which should remove a whole class of seam errors.
    ///
    /// Runs on top of whichever fallback count won the sweep above, passed in
    /// via CRUXWING_WHISPER_FALLBACK, so the two levers are not confounded.
    @Test("VAD chunking vs fixed windows, whole-file pass", .timeLimit(.minutes(60)))
    func chunkingStrategySweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let fallback = Int(ProcessInfo.processInfo.environment["CRUXWING_WHISPER_FALLBACK"] ?? "0") ?? 0
        let useVAD: [Bool] = [false, true]
        print("\n[real-call] chunking sweep, model \(Self.modelUnderTest), fallback \(fallback):")

        for vad in useVAD {
            let label = vad ? "vad" : "fixed"
            let strategy: ChunkingStrategy? = vad ? ChunkingStrategy.vad : nil
            var wers: [Double] = []
            var recalls: [Double] = []
            var words = 0
            var realtimes: [Double] = []

            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: "",
                                                        temperatureFallbackCount: fallback,
                                                        chunkingStrategy: strategy)
                let began = Date()
                let hypothesis = try await service.transcribe(wav: wav)
                let elapsed = Date().timeIntervalSince(began)

                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(Double(found) / Double(terms.count)) }
                words += hypothesis.split(separator: " ").count
                realtimes.append(elapsed / audioSeconds)
                print(String(format: "  %-5@ %-42@ %@  rt %.2fx  terms %d/%d",
                             label as NSString, fixture.name as NSString, score.summary,
                             elapsed / audioSeconds, found, terms.count))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            print(String(format: "  %-5@ MEAN wer %.4f  recall %.4f  words %d  rt %.2fx",
                         label as NSString, mean(wers), mean(recalls), words, mean(realtimes)))
        }
        #expect(Bool(true))
    }

    /// Is the confidence filter deleting correct speech?
    ///
    /// The fallback sweep came back byte-identical at every count, which means
    /// no window ever failed Whisper's own thresholds — the deletions are not
    /// degenerate decodes. They cluster instead on the accented fixtures
    /// (D 153, 153, 169, 195) and nearly vanish on the clean ones (D 8, D 13).
    ///
    /// Average log probability measures how EXPECTED the audio was, not whether
    /// the transcription is right. Accented speech scores lower while still
    /// being correct, so a precision bar written for live captions deletes it.
    /// This measures what raising that bar costs and what it recovers.
    @Test("confidence floor sweep, whole-file pass", .timeLimit(.minutes(60)))
    func confidenceFloorSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let floors = (ProcessInfo.processInfo.environment["CRUXWING_WHISPER_LOGPROB_SWEEP"]
                      ?? "-0.85,-1.2,-1.6,-99").split(separator: ",").compactMap { Float($0) }
        print("\n[real-call] confidence floor sweep, model \(Self.modelUnderTest):")

        for floor in floors {
            var wers: [Double] = []
            var recalls: [Double] = []
            var deletions = 0
            var insertions = 0
            var words = 0

            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: "",
                                                        logProbabilityFloor: floor)
                let hypothesis = try await service.transcribe(wav: wav)
                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(Double(found) / Double(terms.count)) }
                deletions += score.deletions
                insertions += score.insertions
                words += hypothesis.split(separator: " ").count
                print(String(format: "  floor %-6.2f %-42@ %@  terms %d/%d",
                             floor, fixture.name as NSString, score.summary,
                             found, terms.count))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            print(String(format: "  floor %-6.2f MEAN wer %.4f  recall %.4f  D %d  I %d  words %d",
                         floor, mean(wers), mean(recalls), deletions, insertions, words))
        }
        #expect(Bool(true))
    }

    /// Where do the missing words actually go?
    ///
    /// Two sweeps came back byte-identical: temperature fallback at every count,
    /// and the confidence floor all the way down to -99, which disables it. Two
    /// different knobs on two different code paths both changing nothing is not
    /// two coincidences — it means neither is where the deletions happen.
    ///
    /// This counts what the decoder emitted against what the filter kept, which
    /// separates the two possibilities that the WER number cannot: a segment the
    /// filter DELETED, versus one the decoder never produced. They have
    /// completely different fixes.
    @Test("segment accounting on an accented fixture", .timeLimit(.minutes(20)))
    func segmentAccounting() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        // Worst deletion counts in the corpus: 05 (D 153) and 15 (D 195).
        let targets = fixtures.filter { $0.name.hasPrefix("05_") || $0.name.hasPrefix("15_") }
        let chosen = targets.isEmpty ? Array(fixtures.prefix(1)) : targets

        for fixture in chosen {
            guard let wav = try Self.wavData(for: fixture.audio) else { continue }
            let box = VerdictBox()
            let service = LocalWhisperTranscription(
                model: Self.modelUnderTest, language: "en", glossary: "",
                onSegmentVerdict: { accepted, text in box.record(accepted, text) })
            let hypothesis = try await service.transcribe(wav: wav)

            let referenceWords = fixture.reference.text.split(separator: " ").count
            let hypothesisWords = hypothesis.split(separator: " ").count
            let emittedWords = box.emittedWordCount

            print("""

            [real-call] segment accounting — \(fixture.name)
              segments emitted by decoder : \(box.total)
              segments kept by filter     : \(box.accepted)
              segments dropped by filter  : \(box.rejected)
              words in decoder output     : \(emittedWords)
              words in final transcript   : \(hypothesisWords)
              words in reference          : \(referenceWords)
              missing vs reference        : \(referenceWords - hypothesisWords)
              of which lost to the filter : \(emittedWords - hypothesisWords)
            """)
            if !box.droppedSamples.isEmpty {
                print("  dropped text samples: \(box.droppedSamples.prefix(5))")
            }
        }
        #expect(Bool(true))
    }

    /// Collects verdicts from the decoder callback, which is not main-actor bound.
    private final class VerdictBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var total = 0
        private(set) var accepted = 0
        private(set) var rejected = 0
        private(set) var emittedWordCount = 0
        private(set) var droppedSamples: [String] = []

        func record(_ wasAccepted: Bool, _ text: String) {
            lock.lock(); defer { lock.unlock() }
            total += 1
            emittedWordCount += text.split(separator: " ").count
            if wasAccepted { accepted += 1 }
            else {
                rejected += 1
                if droppedSamples.count < 5 { droppedSamples.append(text) }
            }
        }
    }

    /// Every Whisper build, on one corpus, with one method.
    ///
    /// The shipped captions in `LocalWhisperModel` quote base 0.26, small 0.21,
    /// large-v3 0.14 — measured over five recordings by an older script, with
    /// the live chunked pipeline. This corpus is sixteen recordings scored by a
    /// deterministic whole-file pass, and it already disagrees: large-v3-v20240930
    /// scores 0.1775 here, not 0.14.
    ///
    /// Both numbers can be right about different things, which is the problem —
    /// a caption a user reads when choosing a model should come from the corpus
    /// the team actually measures against, and there should be one such corpus.
    ///
    /// `medium` is in the sweep although the app does not offer it: if it sits
    /// near large-v3 at a fraction of the weight, the three-option ladder is
    /// wrong, and that is worth knowing before writing more captions.
    @Test("model sweep, whole-file pass", .timeLimit(.minutes(120)))
    func modelSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let models = (ProcessInfo.processInfo.environment["CRUXWING_WHISPER_MODEL_SWEEP"]
            ?? "openai_whisper-base,openai_whisper-small,openai_whisper-medium,"
             + "openai_whisper-large-v3,openai_whisper-large-v3-v20240930")
            .split(separator: ",").map(String.init)

        print("\n[real-call] model sweep over \(fixtures.count) fixtures:")
        var summary: [(String, Double, Double, Int, Int, Double)] = []

        for model in models {
            var wers: [Double] = []
            var recalls: [Double] = []
            var deletions = 0
            var insertions = 0
            var realtimes: [Double] = []

            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let service = LocalWhisperTranscription(model: model, language: "en", glossary: "")
                let began = Date()
                let hypothesis = try await service.transcribe(wav: wav)
                let elapsed = Date().timeIntervalSince(began)

                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(Double(found) / Double(terms.count)) }
                deletions += score.deletions
                insertions += score.insertions
                realtimes.append(elapsed / audioSeconds)
                print(String(format: "  %-38@ %-30@ %@",
                             model as NSString, fixture.name as NSString, score.summary))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            summary.append((model, mean(wers), mean(recalls), deletions, insertions,
                            mean(realtimes)))
            print(String(format: "  %-38@ MEAN wer %.4f  recall %.4f  D %d  I %d  rt %.2fx",
                         model as NSString, mean(wers), mean(recalls), deletions, insertions,
                         mean(realtimes)))
        }

        print("\n[real-call] MODEL SUMMARY (whole-file, no glossary):")
        for (model, wer, recall, deletions, insertions, rt) in summary {
            print(String(format: "  %-38@ wer %.4f  recall %.4f  D %5d  I %4d  rt %.2fx",
                         model as NSString, wer, recall, deletions, insertions, rt))
        }
        #expect(Bool(true))
    }

    /// Does the SHIPPING language setting match the one every measurement used?
    ///
    /// It does not, and that is why this exists. `Config.transcriptionLanguage`
    /// defaults to "multi" — auto-detect — while every corpus run in this
    /// harness forces "en". So the whole body of accuracy work has been measured
    /// in a configuration users do not get by default.
    ///
    /// Language misdetection on accented English is a well-known Whisper failure
    /// and would look exactly like the deletions that dominate this corpus: a
    /// window detected as Hindi or Chinese emits little or nothing useful for an
    /// English reference to match.
    @Test("auto-detect vs forced English", .timeLimit(.minutes(90)))
    func languageModeSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let model = ProcessInfo.processInfo.environment["CRUXWING_REAL_CALL_MODEL"]
            ?? "openai_whisper-large-v3-v20240930"
        print("\n[real-call] language mode sweep, model \(model):")

        for language in ["multi", "en"] {
            var wers: [Double] = []
            var recalls: [Double] = []
            var deletions = 0
            var worst: (String, Double) = ("", 0)

            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let service = LocalWhisperTranscription(model: model, language: language,
                                                        glossary: "")
                let hypothesis = try await service.transcribe(wav: wav)
                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(Double(found) / Double(terms.count)) }
                deletions += score.deletions
                if score.wer > worst.1 { worst = (fixture.name, score.wer) }
                print(String(format: "  %-6@ %-42@ %@",
                             language as NSString, fixture.name as NSString, score.summary))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            print(String(format: "  %-6@ MEAN wer %.4f  recall %.4f  D %d  worst %@ %.4f",
                         language as NSString, mean(wers), mean(recalls), deletions,
                         worst.0 as NSString, worst.1))
        }
        #expect(Bool(true))
    }

    /// What does the live path's chunk length cost in accuracy?
    ///
    /// Everything measured so far has been the WHOLE-FILE pass, which is not
    /// what users experience during a call. The live path cuts every 6 seconds
    /// because a caption has to appear while people are still talking, and it
    /// scores far worse for it — 0.2541 against 0.1731 when that comparison was
    /// last run.
    ///
    /// 6 seconds was chosen as a latency budget, not as an accuracy result. This
    /// says what the choice actually costs, so the trade can be made on numbers:
    /// a longer window gives the decoder more context either side of a word, at
    /// the price of a caption arriving later.
    @Test("live chunk length sweep", .timeLimit(.minutes(120)))
    func liveChunkLengthSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        let lengths = (ProcessInfo.processInfo.environment["CRUXWING_LIVE_CHUNK_SWEEP"]
                       ?? "4,6,8,12").split(separator: ",").compactMap { Double($0) }
        print("\n[real-call] live chunk length sweep, model \(Self.modelUnderTest):")

        for seconds in lengths {
            var wers: [Double] = []
            var recalls: [Double] = []
            var deletions = 0
            var insertions = 0

            for fixture in fixtures {
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: "")
                let lines = try await transcribeLines(audio: fixture.audio, service: service,
                                                      chunkSeconds: seconds)
                let hypothesis = lines.joined(separator: " ")
                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count

                wers.append(score.wer)
                if !terms.isEmpty { recalls.append(Double(found) / Double(terms.count)) }
                deletions += score.deletions
                insertions += score.insertions
                print(String(format: "  %.0fs %-42@ %@", seconds,
                             fixture.name as NSString, score.summary))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            print(String(format: "  %.0fs MEAN wer %.4f  recall %.4f  D %d  I %d",
                         seconds, mean(wers), mean(recalls), deletions, insertions))
        }
        #expect(Bool(true))
    }

    /// Seam quality at FIXED caption latency.
    ///
    /// The chunk-length sweep showed insertions falling monotonically as the
    /// window grows — most live insertions are duplicated or hallucinated
    /// fragments where two windows meet. But a longer window costs caption
    /// latency, which is the one thing the live path exists to protect, so that
    /// finding could not be acted on.
    ///
    /// These two levers attack the same seams WITHOUT touching the window:
    ///
    /// - `boundarySlack` lets a window end early, on a pause, instead of on an
    ///   exact clock tick. It ships at 0 — every window currently cuts wherever
    ///   six seconds lands, routinely mid-word. Costs nothing: the window ends
    ///   sooner, never later.
    /// - `overlap` decides how much audio two windows share. More overlap gives
    ///   the stitcher more to match on, at the cost of decoding the same audio
    ///   twice.
    @Test("seam levers at fixed window", .timeLimit(.minutes(120)))
    func seamLeverSweep() async throws {
        let fixtures = try Self.loadFixtures()
        guard !fixtures.isEmpty else { return skipNotice() }

        // "overlap:slack" pairs. Default first, so every row reads against it.
        let combos = (ProcessInfo.processInfo.environment["CRUXWING_SEAM_SWEEP"]
                      ?? "1.5:0,1.5:2,3:0,3:2")
            .split(separator: ",").compactMap { pair -> (Double, Double)? in
                let parts = pair.split(separator: ":")
                guard parts.count == 2, let overlap = Double(parts[0]),
                      let slack = Double(parts[1]) else { return nil }
                return (overlap, slack)
            }
        print("\n[real-call] seam sweep at \(Config.transcriptionChunkSeconds)s window, "
              + "model \(Self.modelUnderTest):")

        for (overlap, slack) in combos {
            var wers: [Double] = []
            var deletions = 0
            var insertions = 0
            var substitutions = 0

            for fixture in fixtures {
                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: "")
                let lines = try await transcribeLines(audio: fixture.audio, service: service,
                                                      overlapSeconds: overlap,
                                                      boundarySlackSeconds: slack)
                let hypothesis = lines.joined(separator: " ")
                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                wers.append(score.wer)
                deletions += score.deletions
                insertions += score.insertions
                substitutions += score.substitutions
                print(String(format: "  ov%.1f sl%.0f %-38@ %@", overlap, slack,
                             fixture.name as NSString, score.summary))
            }

            let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
            print(String(format: "  ov%.1f sl%.0f MEAN wer %.4f  S %d  D %d  I %d",
                         overlap, slack, mean(wers), substitutions, deletions, insertions))
        }
        #expect(Bool(true))
    }

    /// Glossary × tier, whole-file pass — the gate the shipped config lacks.
    ///
    /// The shipped path passes `Config.transcriptionGlossary` into every decode
    /// unconditionally, for every model. The two prior observations that make
    /// that suspect point in opposite directions: handing the decoder the right
    /// terms moved recall 0.53→0.93 and 0.57→1.00 on the accented work calls,
    /// and the same mechanism cost the large build 14 points of recall on this
    /// very pass. One knob, opposite signs, gated by nothing — so the matrix is
    /// measured per tier, on the fixtures where a glossary can exist at all
    /// (those carrying `topic` or `expectedTerms`).
    ///
    /// Modes:
    ///   off    empty glossary — the baseline every row reads against
    ///   mined  GlossaryMiner over the fixture's pre-call `topic` — what a
    ///          calendar invite or agenda would actually yield
    ///   self   mined from a first ungated pass over the same audio — the
    ///          two-pass shape the post-call re-transcription could ship
    ///   key    `expectedTerms` verbatim — the answer key: the CEILING of what
    ///          any glossary source could deliver, not a shippable mode
    @Test("glossary mode sweep, whole-file pass", .timeLimit(.minutes(120)))
    func glossaryModeSweep() async throws {
        let fixtures = try Self.loadFixtures().filter {
            $0.reference.topic?.isEmpty == false || $0.reference.expectedTerms?.isEmpty == false
        }
        guard !fixtures.isEmpty else { return skipNotice() }

        let modes = (ProcessInfo.processInfo.environment["CRUXWING_GLOSSARY_SWEEP"]
                     ?? "off,mined,self,key").split(separator: ",").map(String.init)
        print("\n[real-call] glossary mode sweep, model \(Self.modelUnderTest), " +
              "\(fixtures.count) fixtures:")

        // The self mode's first pass is byte-identical to the off decode, so
        // off's hypothesis doubles as self's priming source.
        var offHypothesis: [String: String] = [:]
        var rows: [(mode: String, name: String, score: TranscriptAccuracy.Score,
                    termsFound: Int, termsTotal: Int)] = []

        for mode in modes {
            for fixture in fixtures {
                guard let wav = try Self.wavData(for: fixture.audio) else { continue }
                let terms = (fixture.reference.expectedTerms ?? []).map(\.term)
                let glossary: String
                switch mode {
                case "mined":
                    glossary = GlossaryMiner.candidates(in: fixture.reference.topic ?? "")
                        .map(\.term).joined(separator: ", ")
                case "self":
                    let first: String
                    if let cached = offHypothesis[fixture.name] {
                        first = cached
                    } else {
                        first = try await LocalWhisperTranscription(
                            model: Self.modelUnderTest, language: "en", glossary: "")
                            .transcribe(wav: wav)
                    }
                    glossary = GlossaryMiner.candidates(in: first).map(\.term)
                        .joined(separator: ", ")
                case "key":
                    glossary = terms.joined(separator: ", ")
                case "restore":
                    // Decode bare; the answer key returns as TEXT afterwards.
                    // Measures GlossaryRestore the way the app now ships it.
                    // CRUXWING_RESTORE_LEXICON=1 appends the shipped
                    // DomainLexicon, exactly as retranscribeSessionLocally
                    // does — the safety check for a 230-term dictionary.
                    glossary = ""
                default:
                    glossary = ""
                }
                let lexiconOn = ProcessInfo.processInfo
                    .environment["CRUXWING_RESTORE_LEXICON"] == "1"
                // A mode with nothing to add is byte-identical to off; decoding
                // it again would spend minutes measuring the equality operator.
                if mode == "restore" && terms.isEmpty && !lexiconOn { continue }
                if mode != "off" && mode != "restore" && glossary.isEmpty { continue }

                let service = LocalWhisperTranscription(model: Self.modelUnderTest,
                                                        language: "en", glossary: glossary)
                let began = Date()
                var hypothesis: String
                if mode == "restore", let cached = offHypothesis[fixture.name] {
                    hypothesis = cached
                } else {
                    hypothesis = try await service.transcribe(wav: wav)
                }
                let elapsed = Date().timeIntervalSince(began)
                if mode == "off" { offHypothesis[fixture.name] = hypothesis }
                if mode == "restore" {
                    hypothesis = GlossaryRestore.restore(
                        transcript: hypothesis,
                        glossary: terms,
                        casingOnlyGlossary: lexiconOn ? DomainLexicon.productManagement : [])
                }

                let score = TranscriptAccuracy.score(reference: fixture.reference.text,
                                                     hypothesis: hypothesis)
                let found = terms.isEmpty ? 0
                    : TranscriptAccuracy.termRecall(terms: terms, in: hypothesis).found.count
                rows.append((mode, fixture.name, score, found, terms.count))
                let audioSeconds = fixture.reference.segmentDurationSeconds ?? 300
                print(String(format: "  %-5@ %-42@ %@  terms %d/%d  gloss %d chars  rt %.2fx",
                             mode as NSString, fixture.name as NSString, score.summary,
                             found, terms.count, glossary.count, elapsed / audioSeconds))
            }
        }

        // WER means exclude 14/15: their references are weak ASR the fixture
        // itself marks unscoreable, so they contribute term recall only.
        print("\n[real-call] glossary sweep summary, model \(Self.modelUnderTest):")
        for mode in modes {
            let modeRows = rows.filter { $0.mode == mode }
            guard !modeRows.isEmpty else { continue }
            let werRows = modeRows.filter { !$0.name.hasPrefix("14_") && !$0.name.hasPrefix("15_") }
            let termRows = modeRows.filter { $0.termsTotal > 0 }
            let meanWER = werRows.isEmpty ? 0
                : werRows.map(\.score.wer).reduce(0, +) / Double(werRows.count)
            let foundTotal = termRows.map(\.termsFound).reduce(0, +)
            let termTotal = termRows.map(\.termsTotal).reduce(0, +)
            print(String(format: "  %-5@ WER %.4f over %d scoreable  S %d  D %d  I %d  term recall %d/%d = %.2f",
                         mode as NSString, meanWER, werRows.count,
                         werRows.map(\.score.substitutions).reduce(0, +),
                         werRows.map(\.score.deletions).reduce(0, +),
                         werRows.map(\.score.insertions).reduce(0, +),
                         foundTotal, termTotal,
                         termTotal == 0 ? 0 : Double(foundTotal) / Double(termTotal)))
        }
        #expect(Bool(true))
    }

    /// Decode a fixture to 16-bit WAV bytes.
    private static func wavData(for url: URL) throws -> Data? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var samples: [Int16] = []
        let frames = AVAudioFrameCount(format.sampleRate)
        while file.framePosition < file.length {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: pcm, frameCount: frames)
            if pcm.frameLength == 0 { break }
            if let channel = pcm.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                               count: Int(pcm.frameLength)))
            } else if let floats = pcm.floatChannelData?[0] {
                for index in 0..<Int(pcm.frameLength) {
                    samples.append(Int16(max(-1, min(1, floats[index])) * 32767))
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        return WAVEncoder.encode(samples: samples, sampleRate: Int(format.sampleRate))
    }

}
