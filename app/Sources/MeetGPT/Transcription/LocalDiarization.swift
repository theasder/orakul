import Foundation
import FluidAudio

/// On-device speaker turns for the whole-file post-call pass (roadmap F5).
///
/// The existing speaker pass is metered and goes to a vendor. This one runs on
/// the Mac: the same product promise as on-device transcription, applied to the
/// single most-complained-about failure in this category — "the inability to
/// tell who said what is a show stopper" (HN), "speaker attribution broke down
/// when people talked over each other" (multi-tool review).
///
/// The mapping rules live in `SpeakerAssignment`, which is pure and tested
/// without CoreML. This file is only the model shell: load once, run, hand back
/// plain segments. It stays off by default until it has been measured against
/// the cloud pass on real calls — a speaker label that is confidently wrong is
/// worse than none, which is the whole complaint being answered here.
enum LocalDiarization {

    /// Off, and now off on EVIDENCE rather than caution.
    ///
    /// Measured 2026-08-11 against three EdAcc conversations that are
    /// two-speaker by construction (accented English — Indian, Romanian,
    /// Chinese, American — which is what this product's users actually sound
    /// like). At the library default threshold of 0.7 the pass found 1, 3 and
    /// 5 voices: wrong on every file. A sweep over 0.5–0.9 put the best score
    /// at threshold 0.6 with 2/3, and 0.7 among the WORST settings tested.
    ///
    /// Speed is not the problem — 32–97x realtime, 82–88% speech coverage.
    /// Clustering is. Until a setting gets the count right on every file in a
    /// larger corpus, this stays off: a label that confidently says "Speaker 5"
    /// in a two-person call is precisely the failure this feature exists to
    /// answer, and shipping it would make Cruxwing the thing its own landing
    /// page criticises. Re-run: Tests/MeetGPTTests/LocalDiarizationMeasurement.swift.
    ///
    /// **Measured again 2026-08-11, and the answer got worse, not better.**
    /// Five EdAcc conversations, five minutes each, scored on per-turn ground
    /// truth by ATTRIBUTION — the share of speech time landing on the right
    /// person, after mapping arbitrary speaker IDs the way that flatters the
    /// model most. Best setting was 0.5 at 70.6% mean; the library default
    /// managed 57.5%.
    ///
    /// Then measured AS READ, which is the number that decides shipping: the
    /// product never shows raw turns, it gives each transcript line the speaker
    /// who overlaps it most, so turns too short to win a line never reach the
    /// screen. That absorbs 17.7 points of the model's error — 88.3% of lines
    /// carry the right name at threshold 0.5. Still under the 90% bar written
    /// down before the run, so F5 stays dark, but by 1.7 points rather than by
    /// twenty: worth another attempt, not worth shipping.
    ///
    /// The finding that matters is not the number, it is that COUNTING VOICES
    /// WAS THE WRONG QUESTION. Threshold 0.8 got the speaker count exactly
    /// right most often (3/5) and scored 49.5% attribution — second worst of
    /// six. On one conversation it found precisely two voices and still put
    /// only 38.9% of the words on the right person: a coin flip wearing a
    /// correct answer's clothes. Had the old metric chosen the default, it
    /// would have picked nearly the worst setting a user could feel.
    ///
    /// Do not pick a threshold from speaker counts, and do not pick 0.6 from
    /// the old n=3 run — at n=5 by attribution it is mid-table (63.8%).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.localDiarization") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.localDiarization") }
    }

    /// Below this, clustering has nothing to work with and the result is a
    /// coin flip presented as a fact.
    static let minimumSeconds: Double = 20

    static func canRun(sampleCount: Int, sampleRate: Int = 16_000) -> Bool {
        guard sampleRate > 0 else { return false }
        return Double(sampleCount) / Double(sampleRate) >= minimumSeconds
    }

    /// Speaker turns for 16 kHz mono float samples, or [] when the audio is too
    /// short to cluster. Throws only on model failure — callers treat any
    /// failure as "no labels this time" and keep the transcript they have.
    static func segments(samples: [Float], sampleRate: Int = 16_000,
                         clusteringThreshold: Float? = nil) async throws -> [SpeakerSegment] {
        guard canRun(sampleCount: samples.count, sampleRate: sampleRate) else { return [] }
        let manager = try await Runtime.shared.loadedManager(clusteringThreshold: clusteringThreshold)
        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
        return result.segments.map {
            SpeakerSegment(speakerID: $0.speakerId,
                           startSeconds: $0.startTimeSeconds,
                           endSeconds: $0.endTimeSeconds)
        }
    }

    /// Serialises model loading so two post-call passes cannot each pull a
    /// copy of the weights into memory.
    private actor Runtime {
        static let shared = Runtime()
        private var manager: DiarizerManager?
        private var loadedThreshold: Float?

        /// `clusteringThreshold` is how eagerly two voices are treated as one.
        /// It exists as a parameter only so the measurement harness can sweep
        /// it — production passes nil and takes the library default until a
        /// value is chosen on evidence.
        func loadedManager(clusteringThreshold: Float?) async throws -> DiarizerManager {
            if let manager, loadedThreshold == clusteringThreshold { return manager }
            let models = try await DiarizerModels.downloadIfNeeded()
            var config = DiarizerConfig.default
            if let clusteringThreshold { config.clusteringThreshold = clusteringThreshold }
            let fresh = DiarizerManager(config: config)
            fresh.initialize(models: consume models)
            manager = fresh
            loadedThreshold = clusteringThreshold
            return fresh
        }
    }
}
