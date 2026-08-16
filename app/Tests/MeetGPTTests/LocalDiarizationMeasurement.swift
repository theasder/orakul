import Foundation
import Testing
@testable import MeetGPT

/// Opt-in measurement harness for the explicit-count speaker-label Beta.
/// Point it at recordings whose speaker count is known and inspect only
/// aggregate quality/timing data; ordinary test runs never load the models.
///
///     ORAKUL_DIARIZE_DIR=/path/with/wavs \
///     ORAKUL_DIARIZE_EXPECT=2 \
///     swift test --filter measureAgainstKnownRecordings
///
/// EdAcc conversation files are two-speaker by construction, which makes
/// "did it find exactly two voices" a real pass/fail rather than a vibe.
/// Deliberately env-gated: it needs CoreML weights and minutes of audio, so it
/// must never run in the ordinary suite.
@Suite("Local diarization measurement")
struct LocalDiarizationMeasurement {

    @Test("measure: known-speaker-count recordings",
          .enabled(if: ProcessInfo.processInfo.environment["ORAKUL_DIARIZE_DIR"] != nil))
    func measureAgainstKnownRecordings() async throws {
        // Наличие гарантирует трейт выше — без переменной тело не соберётся.
        let dir = ProcessInfo.processInfo.environment["ORAKUL_DIARIZE_DIR"]!
        let env = ProcessInfo.processInfo.environment
        let expected = Int(env["ORAKUL_DIARIZE_EXPECT"] ?? "2") ?? 2

        let files = (try FileManager.default.contentsOfDirectory(atPath: dir))
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        guard !files.isEmpty else { return }

        var correct = 0
        for name in files {
            let wav = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
            let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
            let audioSeconds = Double(samples.count) / 16_000

            let began = Date()
            let segments = try await LocalDiarization.segments(
                samples: samples,
                expectedRemoteSpeakerCount: expected)
            let elapsed = Date().timeIntervalSince(began)

            let found = SpeakerAssignment.distinctSpeakers(in: segments)
            let covered = segments.reduce(0.0) { $0 + Double($1.endSeconds - $1.startSeconds) }
            if found == expected { correct += 1 }

            // Counts and timings only — never a word of what was said. This
            // harness runs against real recordings and must stay safe to paste
            // into a build log.
            print(String(format: "%@  audio %.0fs  speakers %d (expected %d)  segments %d  speech %.0f%%  in %.1fs (%.0fx realtime)",
                         name, audioSeconds, found, expected, segments.count,
                         audioSeconds > 0 ? covered / audioSeconds * 100 : 0,
                         elapsed, elapsed > 0 ? audioSeconds / elapsed : 0))
        }
        print("speaker-count agreement: \(correct)/\(files.count)")

        // A sweep, not a fudge: if no threshold gets the count right on
        // recordings that are two-speaker by construction, the honest finding
        // is that this pass is not ready — not that the default was unlucky.
        if env["ORAKUL_DIARIZE_SWEEP"] != nil {
            for threshold in [Double(0.5), 0.6, 0.65, 0.7, 0.8, 0.9] {
                var hits = 0
                var counts: [Int] = []
                for name in files {
                    let wav = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
                    let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
                    let segments = try await LocalDiarization.segments(
                        samples: samples,
                        expectedRemoteSpeakerCount: expected,
                        clusteringThreshold: threshold)
                    let found = SpeakerAssignment.distinctSpeakers(in: segments)
                    counts.append(found)
                    if found == expected { hits += 1 }
                }
                print("threshold \(threshold): \(hits)/\(files.count) correct, counts \(counts)")
            }
        }

        // The bar for flipping the flag: it gets the count right everywhere.
        // A pass that miscounts voices mislabels every line that follows.
        #expect(correct == files.count)
    }

    /// Does it put the right words on the right person?
    ///
    /// Counting voices is necessary and not sufficient: a pass can find exactly
    /// two speakers and still swap them halfway, which reads as the transcript
    /// confidently lying about who committed to what. EdAcc conversations ship
    /// per-turn speaker labels, so this scores attribution over time — the thing
    /// a user would actually notice — instead of one integer per file.
    ///
    ///     ORAKUL_DIARIZE_GT_DIR=/path/with/wav+gt \
    ///     swift test --filter measureAttributionAgainstGroundTruth
    ///
    /// Each `<stem>.wav` needs a sibling `<stem>.gt`: tab-separated
    /// `start<TAB>end<TAB>speaker`, seconds from the start of the file.
    @Test("measure: attribution against per-turn ground truth",
          .enabled(if: ProcessInfo.processInfo.environment["ORAKUL_DIARIZE_GT_DIR"] != nil))
    func measureAttributionAgainstGroundTruth() async throws {
        // Наличие гарантирует трейт выше — без переменной тело не соберётся.
        let dir = ProcessInfo.processInfo.environment["ORAKUL_DIARIZE_GT_DIR"]!
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: dir)

        let stems = (try FileManager.default.contentsOfDirectory(atPath: dir))
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
            .filter {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent($0 + ".gt").path)
            }
            .sorted()
        guard !stems.isEmpty else { return }

        let thresholds = (env["ORAKUL_DIARIZE_THRESHOLDS"] ?? "0.5,0.6,0.65,0.7,0.8,0.9")
            .split(separator: ",").compactMap { Double($0) }

        var meanByThreshold: [(threshold: Double, mean: Double, asRead: Double, exactCounts: Int)] = []
        for threshold in thresholds {
            var accuracies: [Double] = []
            var lineAccuracies: [Double] = []
            var exactCounts = 0
            for stem in stems {
                let wav = try Data(contentsOf: root.appendingPathComponent(stem + ".wav"))
                let truth = DiarizationScoring.parseGroundTruth(
                    try String(contentsOf: root.appendingPathComponent(stem + ".gt"),
                               encoding: .utf8))
                let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
                let expected = max(1, Set(truth.map(\.speaker)).count)
                let segments = try await LocalDiarization.segments(
                    samples: samples,
                    expectedRemoteSpeakerCount: expected,
                    clusteringThreshold: threshold)

                let hypothesis = DiarizationScoring.intervals(from: segments)
                let score = DiarizationScoring.attribution(reference: truth, hypothesis: hypothesis)
                // Two numbers, deliberately. Time-weighted attribution is the
                // standard, harsher measure; line accuracy is what a reader
                // sees, because SpeakerAssignment gives each line the speaker
                // who overlaps it most and quietly absorbs turns too short to
                // win one. Shipping on the first would be pessimistic about the
                // product; shipping on the second alone would be flattering.
                let asRead = DiarizationScoring.lineAccuracy(
                    reference: truth, hypothesis: hypothesis,
                    lineDuration: SpeakerAssignment.defaultLineDuration)
                // Segment shape, which is how the island-merge idea was killed:
                // collapsing sub-second speaker islands (the cloud path's fix
                // for "duplicating speaker name all the time") cannot help here
                // because this pass does not emit any. Zero segments under a
                // second on all five conversations, median 2.3-3.1s. The
                // over-segmentation is multi-second turns given too many
                // identities — a clustering problem, not a fragmentation one.
                if env["ORAKUL_DIARIZE_DIAG"] != nil {
                    let shortOnes = segments.filter { $0.endSeconds - $0.startSeconds <= 1.0 }.count
                    let durations = segments.map { $0.endSeconds - $0.startSeconds }.sorted()
                    print(String(format: "    diag %@ th %.2f: %d segments (%d under 1s), median %.1fs, max %.1fs",
                                 stem, threshold, segments.count, shortOnes,
                                 durations.isEmpty ? 0 : durations[durations.count / 2],
                                 durations.last ?? 0))
                }
                accuracies.append(score.accuracy)
                lineAccuracies.append(asRead)
                if score.hypothesisSpeakers == score.referenceSpeakers { exactCounts += 1 }

                // Speaker counts, durations and percentages only — never a word
                // of what was said. This runs against real recordings and must
                // stay safe to paste into a build log.
                print(String(format: "  threshold %.2f  %@  attribution %.1f%%  as-read %.1f%%  voices %d (truth %d)",
                             threshold, stem, score.accuracy * 100, asRead * 100,
                             score.hypothesisSpeakers, score.referenceSpeakers))
            }
            let mean = accuracies.reduce(0, +) / Double(accuracies.count)
            let meanAsRead = lineAccuracies.reduce(0, +) / Double(lineAccuracies.count)
            // The worst file, not only the mean: 88% mean with one conversation
            // at 75% is a feature that gets a quarter of the lines wrong for
            // somebody, and they will not be consoled by the average.
            let worstAsRead = lineAccuracies.min() ?? 0
            meanByThreshold.append((threshold, mean, meanAsRead, exactCounts))
            print(String(format: "threshold %.2f: attribution %.1f%%, as-read %.1f%% (worst file %.1f%%), exact speaker count %d/%d",
                         threshold, mean * 100, meanAsRead * 100, worstAsRead * 100,
                         exactCounts, stems.count))
        }

        let best = meanByThreshold.max { $0.asRead < $1.asRead }
        if let best {
            print(String(format: "best: threshold %.2f, %.1f%% as-read, %.1f%% attribution, %d/%d exact counts, over %d conversations",
                         best.threshold, best.asRead * 100, best.mean * 100, best.exactCounts,
                         stems.count, stems.count))
        }

        // The bar for flipping `LocalDiarization.isEnabled`, written down BEFORE
        // the run so the number cannot be talked into being good enough
        // afterwards. 90% attribution is already roughly one line in ten on the
        // wrong person — generous for a feature whose whole justification is
        // that a confidently wrong label is worse than no label.
        #expect((best?.asRead ?? 0) >= 0.9,
                "no threshold reaches the 90% as-read bar — F5 stays dark")
    }
}
