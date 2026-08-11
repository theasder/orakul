import CoreML
import Foundation
import os
import WhisperKit

enum LocalWhisperTranscriptionError: LocalizedError {
    case inferenceUnavailable

    var errorDescription: String? {
        switch self {
        case .inferenceUnavailable:
            return "On-device transcription couldn't recover from a macOS machine-learning error. Stop and start recording, or choose another transcription engine in Settings."
        }
    }
}

/// On-device Whisper via WhisperKit (Core ML) — Neural Engine acceleration on
/// Apple silicon and CPU/GPU compute on Intel. No audio ever leaves the Mac.
///
/// The model (`TRANSCRIPTION_LOCAL_MODEL`, default "base") downloads once on
/// first use and is cached locally by WhisperKit. An actor: chunks from the two
/// capture sources (system + mic) arrive concurrently, and both model setup
/// and inference must be serialized.
actor LocalWhisperTranscription: TranscriptionService {
    private let modelName: String
    /// Snapshotted when a recording starts so changing Settings cannot alter
    /// the decoder halfway through an in-flight meeting.
    private let configuredLanguage: String
    private let configuredGlossary: String
    private var pipeline: WhisperKit?
    /// Once the Neural Engine reports an execution-stream failure, stay on the
    /// more conservative CPU/GPU path across chunks and app launches.
    private var compatibilityMode: Bool
    /// In-flight setup, shared so concurrent first chunks trigger ONE download.
    private var setupTask: Task<WhisperKit, Error>?
    /// Actors are re-entrant at `await`. Without an explicit gate, concurrent
    /// mic/system chunks can both run WhisperKit. Keep inference single-file for
    /// deterministic decoding and bounded local resource use.
    private var inferenceInProgress = false
    private struct InferenceWaiter {
        let streamID: String?
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var inferenceWaiters: [InferenceWaiter] = []
    private var quiescenceWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Highest recording generation observed. A new meeting invalidates old
    /// queued chunks instead of waiting for every obsolete decode.
    private var latestGeneration = -1
    /// A failed compatibility retry circuit-breaks the rest of that recording.
    /// The next recording gets one fresh attempt instead of one alert per chunk.
    private var suspendedGeneration: Int?
    /// Sustained real-time telemetry. Ignore first-load work and require three
    /// slow completions before suggesting a change, avoiding one-off spikes.
    private var inferenceEWMA: TimeInterval?
    private var slowInferenceStreak = 0
    private struct SourceActivity {
        var recentCount: Int
        var lastSeen: TimeInterval
    }
    private var sourceActivity: [String: SourceActivity] = [:]
    private var performanceRecommendation: TranscriptionPerformanceRecommendation?
    private var performanceRecommendationIssued = false
    private var thermalStreak = 0
    /// Injectable for tests; production reads the live thermal state.
    var thermalStateProvider: () -> ProcessInfo.ThermalState =
        { ProcessInfo.processInfo.thermalState }
    /// A service instance belongs to one local-model lifecycle. Once AppState
    /// switches model/backend it is permanently closed; stale setup work may
    /// finish, but an epoch guard prevents it from republishing a pipeline.
    private var isShutDown = false
    private var lifecycleEpoch = 0
    private var setupTaskEpoch: Int?

    private struct InferenceBatch {
        let results: [TranscriptionResult]
    }

    /// How many times a failed decode is retried at a higher temperature.
    ///
    /// Whisper's own remedy for a degenerate window — a repetition loop, or
    /// text hallucinated over silence. Zero disables it: the bad decode is kept
    /// and then thrown away wholesale by the confidence filter, which loses the
    /// words that WERE spoken in that window. Retrying often recovers them.
    ///
    /// It costs a re-decode, which is why the live path cannot afford it: a
    /// caption has to appear while people are still talking. The whole-file
    /// pass runs at ~0.15x realtime and has the headroom.
    private let temperatureFallbackCount: Int

    /// How the decoder splits audio longer than one 30s window.
    ///
    /// `nil` uses fixed windows, which cut wherever 30 seconds lands — routinely
    /// mid-word and mid-sentence. `.vad` cuts on speech boundaries instead, so a
    /// seam falls in a pause. The live path hands over 6-second slices and never
    /// reaches this; it matters only for the whole-file pass.
    private let chunkingStrategy: ChunkingStrategy?

    /// The confidence floor below which a decoded segment is discarded.
    ///
    /// The default (-0.85) is a PRECISION bar written for live captions, where a
    /// wrong caption appears on screen while people are still talking and a
    /// missing one is barely noticed. Average log probability is a measure of
    /// how expected the audio was, not of whether the transcription is right,
    /// and accented speech scores lower even when the words are correct — so
    /// this bar deletes accented speech disproportionately.
    ///
    /// The whole-file pass wants the opposite trade: it exists to produce a
    /// fuller record, nobody is reading it live, and a dropped segment is
    /// content permanently lost.
    private let logProbabilityFloor: Float

    /// Reports every segment the decoder produced and whether the confidence
    /// filter kept it. Diagnostic seam: without it there is no way to tell a
    /// segment the filter DELETED from one the decoder never emitted, and those
    /// two have completely different fixes.
    private let onSegmentVerdict: ((Bool, String) -> Void)?

    init(model: String = Config.localWhisperModel,
         language: String = Config.transcriptionLanguage,
         glossary: String = Config.transcriptionGlossary,
         temperatureFallbackCount: Int = 0,
         chunkingStrategy: ChunkingStrategy? = nil,
         logProbabilityFloor: Float = LocalWhisperTranscription.defaultLogProbabilityFloor,
         onSegmentVerdict: ((Bool, String) -> Void)? = nil) {
        self.logProbabilityFloor = logProbabilityFloor
        self.onSegmentVerdict = onSegmentVerdict
        self.temperatureFallbackCount = temperatureFallbackCount
        self.chunkingStrategy = chunkingStrategy
        self.modelName = model
        self.configuredLanguage = language
        self.configuredGlossary = glossary
        self.compatibilityMode = Self.shouldUseCompatibilityCompute(
            savedMode: Config.localWhisperCompatibilityMode,
            isIntel: Self.isIntelBuild
        )
    }

    /// Internal regression seam: confirms a recording keeps the language mode
    /// captured at construction even if Settings changes mid-stream.
    func languageSnapshot() -> String { configuredLanguage }
    func glossarySnapshot() -> String { configuredGlossary }

    /// Download + load the model ahead of the first chunk. Lets the UI show a
    /// "preparing" state instead of a blank transcript during the first-use
    /// download, and surfaces a download failure instead of swallowing it.
    func prewarm() async throws {
        guard !isShutDown else { throw CancellationError() }
        do {
            _ = try await preparedPipeline()
        } catch {
            guard Self.isCoreMLPredictionFailure(error) else { throw error }
            Log.transcribe.error("local Whisper prewarm hit a Core ML execution failure; retrying on CPU/GPU: \(error.localizedDescription, privacy: .private)")
            await activateCompatibilityMode()
            do {
                _ = try await preparedPipeline()
            } catch {
                Log.transcribe.error("local Whisper CPU/GPU prewarm retry failed: \(error.localizedDescription, privacy: .private)")
                await discardPipeline()
                throw LocalWhisperTranscriptionError.inferenceUnavailable
            }
        }
    }

    func transcribe(wav: Data) async throws -> String {
        try await transcribe(wav: wav, streamID: nil)
    }

    func transcribe(wav: Data, streamID: String?) async throws -> String {
        let samples = Self.floatSamples(fromWAV: wav)
        // Whisper hallucinates on near-empty audio; skip sub-0.3s slivers.
        guard samples.count > 4800 else { return "" }
        guard !isShutDown else { throw CancellationError() }

        registerGeneration(from: streamID)
        registerSource(from: streamID)
        if let generation = Self.generation(from: streamID), suspendedGeneration == generation {
            throw LocalWhisperTranscriptionError.inferenceUnavailable
        }
        guard await acquireInferenceSlot(streamID: streamID) else { return "" }
        defer { releaseInferenceSlot() }
        // Another chunk can fail or a new recording can start while this one
        // waits behind inference. Recheck after the continuation resumes.
        if isStale(streamID) { return "" }
        if let generation = Self.generation(from: streamID), suspendedGeneration == generation {
            throw LocalWhisperTranscriptionError.inferenceUnavailable
        }
        let eligibleForPerformanceMeasurement = pipeline != nil
        let inferenceStartedAt = ProcessInfo.processInfo.systemUptime
        let batch = try await inferenceBatchWithRecovery(samples: samples, streamID: streamID)
        guard !isShutDown, !isStale(streamID) else { return "" }
        if eligibleForPerformanceMeasurement {
            recordInferencePerformance(
                elapsed: ProcessInfo.processInfo.systemUptime - inferenceStartedAt,
                sampleCount: samples.count
            )
        }
        guard let batch else { return "" }
        let candidates = batch.results.flatMap { result in
            result.segments.compactMap { segment -> String? in
                guard self.isReliable(segment: segment) else {
                    self.onSegmentVerdict?(false, segment.text)
                    SpeechQualityMonitor.shared.record(accepted: false)
                    Log.transcribe.notice("dropped low-confidence local segment: avgLogProb=\(segment.avgLogprob, privacy: .public) noSpeech=\(segment.noSpeechProb, privacy: .public) compression=\(segment.compressionRatio, privacy: .public)")
                    return nil
                }
                // Whole-result sign-offs are filtered after joining. Applying
                // them here can delete legitimate words from a longer chunk.
                let clean = TranscriptArtifacts.cleanInline(segment.text)
                // Confidence and audio/VAD evidence decide whether speech is
                // real. Names, numbers, "yes", and other short turns are valid.
                guard !clean.isEmpty else { return nil }
                // Brief fragments are the most common silence hallucinations,
                // but also normal conversation. Preserve them when Whisper's
                // own evidence is strong instead of deleting by word count.
                if Self.isShortFragment(clean), !Self.isReliableShortFragment(segment: segment) {
                    SpeechQualityMonitor.shared.record(accepted: false)
                    Log.transcribe.notice("dropped uncertain short local segment: avgLogProb=\(segment.avgLogprob, privacy: .public) noSpeech=\(segment.noSpeechProb, privacy: .public) compression=\(segment.compressionRatio, privacy: .public)")
                    return nil
                }
                // The accept side of the ratio. Without it every verdict is a
                // reject and the reject rate is always 1.0 — which would suppress
                // quotes on perfectly clean audio.
                self.onSegmentVerdict?(true, clean)
                SpeechQualityMonitor.shared.record(accepted: true)
                return clean
            }
        }

        // Collapse repeats WITHIN this one chunk before joining.
        //
        // `batch.results` is an array, and WhisperKit can return more than one
        // result for the same audio — decode retries and temperature fallbacks
        // each produce their own segments. flatMap then concatenated all of them,
        // so a single 6-second chunk emitted the same utterance twice, worded
        // slightly differently by each decode pass. That is the reported
        // "duplicates that are not the same but differently transcribed", and it
        // is a technical artefact rather than anything the speaker did.
        //
        // Safe because the scope is ONE chunk: two decodes of the same few seconds
        // agreeing in substance is not a person repeating themselves. Genuine
        // repetition across chunks is untouched — that is the deduplicator's job,
        // with its own time window and thresholds.
        if batch.results.count > 1 {
            Log.transcribe.notice("local chunk returned \(batch.results.count, privacy: .public) results — collapsing intra-chunk repeats")
        }
        let text = Self.collapseIntraChunkRepeats(candidates).joined(separator: " ")
        return TranscriptArtifacts.clean(text)
    }

    /// Drop candidates that repeat one already collected from the SAME chunk.
    ///
    /// Compares on normalized tokens so "the pricing change" and "the pricing
    /// changes" collapse, and only for candidates long enough to be a phrase —
    /// short interjections ("no", "right") legitimately repeat inside a few
    /// seconds and must survive.
    static func collapseIntraChunkRepeats(_ candidates: [String]) -> [String] {
        guard candidates.count > 1 else { return candidates }
        var kept: [String] = []
        var keptTokens: [[String]] = []
        for candidate in candidates {
            let tokens = TranscriptDeduplicator.tokens(candidate)
            if tokens.count >= TranscriptDeduplicator.fuzzyMinimumTokens {
                // Deliberately the CROSS-TRACK bar, not the same-track one: two
                // decode passes over identical audio are as close a pair as the
                // two capture paths, and the competing explanation ("they said it
                // twice in six seconds") is much weaker here.
                let isRepeat = keptTokens.contains { existing in
                    existing == tokens
                        || TranscriptDeduplicator.similarity(existing, tokens)
                            >= TranscriptDeduplicator.crossTrackSimilarityThreshold
                }
                if isRepeat { continue }
            } else if kept.contains(candidate) {
                // Short fragments still collapse on an EXACT match.
                continue
            }
            kept.append(candidate)
            keptTokens.append(tokens)
        }
        return kept
    }

    // MARK: - Language routing and inference recovery

    /// Route one voiced chunk in Auto. This is deliberately stateless: every
    /// chunk is detected again, so English -> Russian -> English on the same
    /// system track adapts immediately instead of locking to the first speaker.
    /// The shared-language gate prevents a false unsupported detection from
    /// turning room noise into fluent foreign-language captions. Speech and
    /// transcript confidence are handled by VAD and the segment filters below,
    /// not by deleting short turns before they have been decoded.
    static func acceptedAutoLanguage(_ language: String,
                                     supportedLanguages: Set<String> = Config.automaticTranscriptionLanguageCodes) -> String? {
        let normalized = language.lowercased().split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        guard supportedLanguages.contains(normalized) else { return nil }
        return normalized
    }

    static var compatibilityComputeOptions: ModelComputeOptions {
        ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU
        )
    }

    /// Intel Macs have no Neural Engine. Select their best available Core ML
    /// path immediately instead of paying for a failed default load and retry.
    static func shouldUseCompatibilityCompute(savedMode: Bool, isIntel: Bool) -> Bool {
        savedMode || isIntel
    }

    private static var isIntelBuild: Bool {
#if arch(x86_64)
        true
#else
        false
#endif
    }

    /// A serialized local pipeline must finish the work produced by each audio
    /// source before the next chunk interval. EWMA absorbs transient spikes;
    /// source count accounts for simultaneous mic + system streams.
    static func effectiveRealtimeLoad(inferenceSeconds: TimeInterval,
                                      sampleCount: Int,
                                      activeSourceCount: Int) -> Double {
        let audioSeconds = max(0.1, Double(sampleCount) / Double(WhisperKit.sampleRate))
        return max(0, inferenceSeconds) * Double(max(1, activeSourceCount)) / audioSeconds
    }

    static func recentActiveSourceCount(
        _ activities: [(recentCount: Int, lastSeen: TimeInterval)],
        now: TimeInterval,
        activityWindow: TimeInterval
    ) -> Int {
        let active = activities.filter {
            $0.recentCount >= 2 && now - $0.lastSeen <= max(0, activityWindow)
        }.count
        return max(1, active)
    }

    static func isSustainedOverload(load: Double,
                                    currentStreak: Int,
                                    threshold: Double = 0.80,
                                    requiredCompletions: Int = 3) -> (streak: Int, overloaded: Bool) {
        let streak = load >= threshold ? currentStreak + 1 : 0
        return (streak, streak >= max(2, requiredCompletions))
    }

    /// Core ML wraps the same execution failure under different NSError layers
    /// on different macOS releases. Match its domain and known runtime wording,
    /// while leaving model-download/network failures on their normal path.
    static func isCoreMLPredictionFailure(_ error: Error) -> Bool {
        // WhisperKit 1.0 intentionally erases the decoder's underlying Core ML
        // error in Auto detection and replaces it with this generic wrapper.
        if error.localizedDescription == "Language detection failed" {
            return true
        }
        let nsError = error as NSError
        let signature = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.localizedRecoverySuggestion ?? ""
        ].joined(separator: " ").lowercased()
        return signature.contains("unable to compute the asynchronous prediction")
            || signature.contains("ml program")
            || signature.contains("mlmodelerrordomain")
            || signature.contains("com.apple.coreml")
            || signature.contains("e5rt")
            || signature.contains("aneprogram")
    }

    private func inferenceBatchWithRecovery(samples: [Float],
                                            streamID: String?) async throws -> InferenceBatch? {
        do {
            let whisper = try await preparedPipeline()
            return try await runInference(samples: samples, streamID: streamID, whisper: whisper)
        } catch {
            guard Self.isCoreMLPredictionFailure(error) else { throw error }
            Log.transcribe.error("local Whisper Core ML inference failed; rebuilding on CPU/GPU and retrying the chunk once: \(error.localizedDescription, privacy: .private)")
            await activateCompatibilityMode()
            do {
                let whisper = try await preparedPipeline()
                return try await runInference(samples: samples, streamID: streamID, whisper: whisper)
            } catch {
                Log.transcribe.error("local Whisper CPU/GPU recovery failed; suspending this recording: \(error.localizedDescription, privacy: .private)")
                await discardPipeline()
                suspendedGeneration = Self.generation(from: streamID)
                throw LocalWhisperTranscriptionError.inferenceUnavailable
            }
        }
    }

    private func runInference(samples: [Float],
                              streamID: String?,
                              whisper: WhisperKit) async throws -> InferenceBatch? {
        let automatic = configuredLanguage == "multi"

        let options = DecodingOptions(
            task: .transcribe,
            language: automatic ? nil : configuredLanguage,
            temperatureFallbackCount: temperatureFallbackCount,
            usePrefillPrompt: true,
            // WhisperKit performs detection from the encoder output it already
            // computed for transcription. This keeps Auto to one encoder pass
            // per chunk and re-detects for each window in imported long media.
            detectLanguage: automatic,
            skipSpecialTokens: true,
            promptTokens: glossaryPromptTokens(for: whisper),
            concurrentWorkerCount: 1,
            chunkingStrategy: chunkingStrategy
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        // Imported media can span many windows and legitimately contain more
        // languages than the live-engine common set. WhisperKit exposes only
        // one final result language for that file, so filtering it here could
        // erase earlier valid windows. Live six-second chunks have one detected
        // language and retain the anti-hallucination allowlist.
        guard automatic, streamID != nil else { return InferenceBatch(results: results) }

        let accepted = results.filter { result in
            guard let language = Self.acceptedAutoLanguage(result.language) else {
                Log.transcribe.notice("dropped local Auto result in unsupported detected language: \(result.language, privacy: .public)")
                return false
            }
            Log.transcribe.debug("local Auto selected \(language, privacy: .public) for the current chunk")
            return true
        }
        return InferenceBatch(results: accepted)
    }

    private func recordInferencePerformance(elapsed: TimeInterval, sampleCount: Int) {
        let smoothed = inferenceEWMA.map { $0 * 0.70 + elapsed * 0.30 } ?? elapsed
        inferenceEWMA = smoothed
        let now = ProcessInfo.processInfo.systemUptime
        let activityWindow = max(8, Config.transcriptionChunkSeconds * 2.5)
        sourceActivity = sourceActivity.filter { now - $0.value.lastSeen <= activityWindow }
        // A second source counts only after two recent voiced chunks. A lone
        // cough/notification on the other track must not double load forever.
        let activeSourceCount = Self.recentActiveSourceCount(
            sourceActivity.values.map { ($0.recentCount, $0.lastSeen) },
            now: now,
            activityWindow: activityWindow
        )
        let load = Self.effectiveRealtimeLoad(
            inferenceSeconds: smoothed,
            sampleCount: sampleCount,
            activeSourceCount: activeSourceCount
        )
        let outcome = Self.isSustainedOverload(load: load, currentStreak: slowInferenceStreak)
        slowInferenceStreak = outcome.streak
        // Heat is a separate axis from speed: a fast chip can hold realtime on
        // large-v3 while the chassis cooks. macOS reports it directly.
        let thermal = Self.isSustainedThermalPressure(
            state: thermalStateProvider(), currentStreak: thermalStreak)
        thermalStreak = thermal.streak
        Log.transcribe.debug("local Whisper performance: model=\(self.modelName, privacy: .public) elapsed=\(elapsed, privacy: .public)s load=\(load, privacy: .public) streak=\(self.slowInferenceStreak, privacy: .public) thermalStreak=\(self.thermalStreak, privacy: .public)")

        guard Config.adaptiveLocalWhisperEnabled,
              !performanceRecommendationIssued else { return }
        if outcome.overloaded {
            performanceRecommendationIssued = true
            if let lighter = LocalWhisperModel.nextLighter(than: modelName) {
                performanceRecommendation = .lighterLocalModel(current: modelName, recommended: lighter)
            } else {
                performanceRecommendation = .offerDeepgram
            }
        } else if thermal.hot, let lighter = LocalWhisperModel.nextLighter(than: modelName) {
            performanceRecommendationIssued = true
            performanceRecommendation = .coolerLocalModel(current: modelName, recommended: lighter)
        }
    }

    /// Pure: sustained `.serious`/`.critical` thermal pressure across
    /// consecutive chunks (one hot reading is a spike, not a trend).
    static func isSustainedThermalPressure(
        state: ProcessInfo.ThermalState,
        currentStreak: Int,
        threshold: Int = 3
    ) -> (hot: Bool, streak: Int) {
        let pressured = state == .serious || state == .critical
        let streak = pressured ? currentStreak + 1 : 0
        return (hot: streak >= threshold, streak: streak)
    }

    func takePerformanceRecommendation() async -> TranscriptionPerformanceRecommendation? {
        defer { performanceRecommendation = nil }
        return performanceRecommendation
    }

    func cancelPendingTranscriptions(beforeGeneration: Int) async {
        latestGeneration = max(latestGeneration, beforeGeneration)
        suspendedGeneration = nil
        inferenceEWMA = nil
        slowInferenceStreak = 0
        sourceActivity.removeAll(keepingCapacity: true)
        performanceRecommendation = nil
        performanceRecommendationIssued = false
        let queued = inferenceWaiters
        inferenceWaiters.removeAll(keepingCapacity: false)
        for waiter in queued { waiter.continuation.resume(returning: false) }
    }

    func shutdown() async {
        if !isShutDown {
            isShutDown = true
            lifecycleEpoch &+= 1
            setupTask?.cancel()

            // Queued chunks have not touched the model yet; reject all of them.
            let queued = inferenceWaiters
            inferenceWaiters.removeAll(keepingCapacity: false)
            for waiter in queued { waiter.continuation.resume(returning: false) }
        }

        // Never unload Core ML while an inference or model setup still owns it.
        // Some model initializers ignore cooperative cancellation, so bound the
        // wait: the retired service finishes unloading itself once it becomes
        // idle instead of blocking the user's next recording indefinitely.
        let quiescent = await waitForQuiescence(timeout: 2.0)
        guard quiescent else {
            Log.transcribe.notice("local Whisper retirement is still busy; deferring model unload")
            return
        }
        await unloadAfterShutdownIfQuiescent()
    }

    private func activateCompatibilityMode() async {
        compatibilityMode = true
        Config.localWhisperCompatibilityMode = true
        await discardPipeline()
    }

    private func discardPipeline() async {
        lifecycleEpoch &+= 1
        setupTask?.cancel()
        setupTask = nil
        setupTaskEpoch = nil
        let previous = pipeline
        pipeline = nil
        if let previous { await previous.unloadModels() }
        notifyQuiescenceIfNeeded()
    }

    /// WhisperKit's built-in silence rule lets a high token probability
    /// override a high no-speech probability. That is exactly how memorized
    /// subtitle/sign-off phrases leak out over room noise. Live captions favor
    /// precision: reject uncertain, repetitive, or probably-silent segments.
    static let defaultLogProbabilityFloor: Float = -0.85

    static func isReliable(avgLogProbability: Float,
                           noSpeechProbability: Float,
                           compressionRatio: Float,
                           logProbabilityFloor: Float = defaultLogProbabilityFloor) -> Bool {
        // Only the confidence floor moves. The no-speech and compression bars
        // stay put: they are what block memorized sign-off phrases over room
        // noise and repetition loops, and neither failure mode gets more
        // acceptable just because nobody is reading the output live.
        avgLogProbability >= logProbabilityFloor
            && noSpeechProbability <= 0.50
            && compressionRatio <= 2.20
    }

    private func isReliable(segment: TranscriptionSegment) -> Bool {
        Self.isReliable(avgLogProbability: segment.avgLogprob,
                        noSpeechProbability: segment.noSpeechProb,
                        compressionRatio: segment.compressionRatio,
                        logProbabilityFloor: logProbabilityFloor)
    }

    /// Short fragments used to face a much stricter bar than everything else
    /// (-0.50 / 0.20 / 1.80 against -0.85 / 0.50 / 2.20) because the common
    /// short fragment was a silence hallucination.
    ///
    /// Overlapping windows changed that. A seam now produces legitimate short
    /// fragments — "Kubernetes", "and the launch moves" — and the strict bar
    /// deleted them as hallucinations. Measured across four harness runs, the
    /// count of dropped segments tracked WER almost monotonically: 2 drops at
    /// WER 0.20, 31 drops at 0.44. A real seam fragment is also corroborated by
    /// the neighbouring window, and ChunkStitcher removes the duplicate, so the
    /// hallucination risk this guarded against is now covered elsewhere.
    static func isReliableShortFragment(avgLogProbability: Float,
                                        noSpeechProbability: Float,
                                        compressionRatio: Float) -> Bool {
        avgLogProbability >= -0.75
            && noSpeechProbability <= 0.40
            && compressionRatio <= 2.10
    }

    private static func isReliableShortFragment(segment: TranscriptionSegment) -> Bool {
        isReliableShortFragment(avgLogProbability: segment.avgLogprob,
                                noSpeechProbability: segment.noSpeechProb,
                                compressionRatio: segment.compressionRatio)
    }

    private static func isShortFragment(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }
        if words.count > 4 { return false }
        // CJK and other unspaced scripts carry a full phrase in one lexical
        // token; don't treat a substantive character run as a tiny fragment.
        let compactLetters = text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return !(words.count <= 1 && compactLetters.count >= 8)
    }

    // MARK: - Inference serialization

    private func acquireInferenceSlot(streamID: String?) async -> Bool {
        if isShutDown || isStale(streamID) { return false }
        if !inferenceInProgress {
            inferenceInProgress = true
            return true
        }
        return await withCheckedContinuation { continuation in
            inferenceWaiters.append(InferenceWaiter(streamID: streamID,
                                                     continuation: continuation))
        }
    }

    private func releaseInferenceSlot() {
        while !inferenceWaiters.isEmpty {
            let waiter = inferenceWaiters.removeFirst()
            if isShutDown || isStale(waiter.streamID) {
                waiter.continuation.resume(returning: false)
                continue
            }
            waiter.continuation.resume(returning: true)
            return
        }
        inferenceInProgress = false
        notifyQuiescenceIfNeeded()
    }

    private func registerGeneration(from streamID: String?) {
        guard let generation = Self.generation(from: streamID), generation > latestGeneration else { return }
        latestGeneration = generation
        suspendedGeneration = nil
        inferenceEWMA = nil
        slowInferenceStreak = 0
        sourceActivity.removeAll(keepingCapacity: true)
        performanceRecommendation = nil
        performanceRecommendationIssued = false
        var retained: [InferenceWaiter] = []
        for waiter in inferenceWaiters {
            if isStale(waiter.streamID) {
                waiter.continuation.resume(returning: false)
            } else {
                retained.append(waiter)
            }
        }
        inferenceWaiters = retained
    }

    private func registerSource(from streamID: String?) {
        guard let streamID,
              let source = streamID.split(separator: ":", maxSplits: 1).last else { return }
        let key = String(source)
        let now = ProcessInfo.processInfo.systemUptime
        let activityWindow = max(8, Config.transcriptionChunkSeconds * 2.5)
        if let previous = sourceActivity[key], now - previous.lastSeen <= activityWindow {
            sourceActivity[key] = SourceActivity(
                recentCount: min(2, previous.recentCount + 1), lastSeen: now
            )
        } else {
            sourceActivity[key] = SourceActivity(recentCount: 1, lastSeen: now)
        }
    }

    private func notifyQuiescenceIfNeeded() {
        guard !inferenceInProgress, setupTask == nil else { return }
        let waiters = Array(quiescenceWaiters.values)
        quiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if isShutDown {
            Task { await self.unloadAfterShutdownIfQuiescent() }
        }
    }

    private func waitForQuiescence(timeout: TimeInterval) async -> Bool {
        guard inferenceInProgress || setupTask != nil else { return true }
        let id = UUID()
        await withCheckedContinuation { continuation in
            quiescenceWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.timeOutQuiescenceWaiter(id)
            }
        }
        return !inferenceInProgress && setupTask == nil
    }

    private func timeOutQuiescenceWaiter(_ id: UUID) {
        guard let waiter = quiescenceWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    private func unloadAfterShutdownIfQuiescent() async {
        guard isShutDown, !inferenceInProgress, setupTask == nil else { return }
        let previous = pipeline
        pipeline = nil
        if let previous { await previous.unloadModels() }
    }

    private func isStale(_ streamID: String?) -> Bool {
        guard let generation = Self.generation(from: streamID) else { return false }
        return generation < latestGeneration
    }

    private static func generation(from streamID: String?) -> Int? {
        guard let prefix = streamID?.split(separator: ":", maxSplits: 1).first else { return nil }
        return Int(prefix)
    }

    /// Encode the team glossary into decoder prompt tokens (biases spelling).
    /// Follows WhisperKit's own pattern: encode the hint, drop special tokens.
    /// nil when the glossary is empty so decoding is unaffected.
    ///
    /// The large tier never receives prompt tokens. Measured on the live
    /// pipeline (2026-08-09, fixtures 14/15): the same answer-key glossary
    /// that lifts small's term recall 0.53→0.93 at flat WER makes large HALVE
    /// its output — 559→296 and 729→499 words, deletions 109→308 and
    /// 203→392 — for zero term gain on 14 (11/15 both ways). The whole-file
    /// pass shows the same signature harder (WER 0.95, D 2757). Large's terms
    /// come from `GlossaryRestore` on the finished text instead, which cannot
    /// delete speech.
    private func glossaryPromptTokens(for whisper: WhisperKit) -> [Int]? {
        guard !Self.suppressesGlossaryPrompt(model: modelName) else { return nil }
        let hint = Glossary.promptHint(from: configuredGlossary)
        guard !hint.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + hint)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// Substring rather than an id list: the model string arrives as a short
    /// id ("large-v3-v20240930"), a legacy id ("large-v3") or a full repo
    /// folder ("openai_whisper-large-v3-v20240930") depending on the caller,
    /// and every large build shares the failure.
    static func suppressesGlossaryPrompt(model: String) -> Bool {
        model.localizedCaseInsensitiveContains("large")
    }

    // MARK: - Model lifecycle

    private func preparedPipeline() async throws -> WhisperKit {
        guard !isShutDown else { throw CancellationError() }
        if let pipeline { return pipeline }
        if let setupTask {
            let epoch = setupTaskEpoch ?? lifecycleEpoch
            let whisper = try await setupTask.value
            guard !isShutDown, lifecycleEpoch == epoch else { throw CancellationError() }
            return whisper
        }

        let model = modelName
        let useCompatibilityMode = compatibilityMode
        let computeOptions = useCompatibilityMode ? Self.compatibilityComputeOptions : nil
        let epoch = lifecycleEpoch
        let task = Task<WhisperKit, Error> {
            let computePath = useCompatibilityMode ? "CPU/GPU compatibility" : "default"
            Log.transcribe.info("loading local Whisper model \"\(model, privacy: .public)\" using \(computePath, privacy: .public) compute (downloads on first use)")
            let config = WhisperKitConfig(
                model: model,
                computeOptions: computeOptions,
                verbose: false,
                prewarm: true,
                load: true
            )
            let whisper = try await WhisperKit(config)
            Log.transcribe.info("local Whisper model ready using \(computePath, privacy: .public) compute")
            return whisper
        }
        setupTask = task
        setupTaskEpoch = epoch
        do {
            let whisper = try await task.value
            guard !isShutDown, lifecycleEpoch == epoch else {
                await whisper.unloadModels()
                if setupTaskEpoch == epoch {
                    setupTask = nil
                    setupTaskEpoch = nil
                    notifyQuiescenceIfNeeded()
                }
                throw CancellationError()
            }
            pipeline = whisper
            if setupTaskEpoch == epoch {
                setupTask = nil
                setupTaskEpoch = nil
                notifyQuiescenceIfNeeded()
            }
            return whisper
        } catch {
            // Reset so a later chunk can retry (e.g. transient network failure
            // during the model download).
            if setupTaskEpoch == epoch {
                setupTask = nil
                setupTaskEpoch = nil
                notifyQuiescenceIfNeeded()
            }
            throw error
        }
    }

    // MARK: - WAV decoding

    /// Decode our mono 16 kHz PCM-16 WAV chunks into the raw Float samples
    /// WhisperKit consumes. Walks RIFF chunks to find "data" (robust to any
    /// extra header chunks) with a 44-byte-offset fallback.
    static func floatSamples(fromWAV wav: Data) -> [Float] {
        var payload: Data?
        // RIFF header is 12 bytes, then chunks of [4-byte id][4-byte size][body].
        var offset = 12
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[wav.startIndex + offset ..< wav.startIndex + offset + 4], as: UTF8.self)
            let size = wav.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            }
            if id == "data" {
                let start = offset + 8
                let end = min(start + Int(size), wav.count)
                if start < end { payload = wav.subdata(in: wav.startIndex + start ..< wav.startIndex + end) }
                break
            }
            offset += 8 + Int(size) + (Int(size) % 2)   // chunks are word-aligned
        }
        let data = payload ?? (wav.count > 44 ? wav.subdata(in: wav.startIndex + 44 ..< wav.endIndex) : Data())

        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let value = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                samples[i] = Float(value) / 32768.0
            }
        }
        return samples
    }
}

/// Picks the transcription backend for chunked (non-Deepgram) transcription.
enum TranscriptionFactory {
    static func make(engine: TranscriptionEngine = Config.transcriptionEngineValue,
                     language: String = Config.transcriptionLanguage,
                     glossary: String = Config.transcriptionGlossary,
                     localModel: String = Config.localWhisperModel) -> TranscriptionService {
        switch engine {
        case .local:
            // Live captions only: the post-call whole-file pass constructs
            // its Whisper service directly and never sees this branch.
            if ParakeetLiveTranscription.shouldServe(language: language) {
                return ParakeetLiveTranscription(language: language)
            }
            return LocalWhisperTranscription(
                model: localModel, language: language, glossary: glossary)
        case .server:
            // Managed large-v3 with an on-device safety net: cap / outage /
            // sign-out degrades the session instead of erroring every chunk.
            return ServerFallbackTranscription(
                primary: ServerWhisperTranscription(language: language, glossary: glossary),
                fallback: LocalWhisperTranscription(model: localModel,
                                                    language: language,
                                                    glossary: glossary))
        case .whisper:
            return WhisperAPITranscription(language: language, glossary: glossary)
        case .deepgram:
            // Deepgram's live streams are owned by AppState; this service is
            // not used for chunks while that engine is active.
            return WhisperAPITranscription(language: language, glossary: glossary)
        }
    }
}
