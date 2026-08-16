import CoreML
import Foundation
import Testing
@testable import MeetGPT

/// On-device model tiering: the pure hardware-aware default + the catalog the
/// Settings picker renders.
@Suite("Local Whisper model")
struct LocalWhisperModelTests {
    @Test("default is the strongest model the machine carries WITHOUT running hot")
    func hardwareDefault() {
        // Max/Ultra with memory → best quality regardless of generation.
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 16, chipTier: .max, chipGeneration: 1) == LocalWhisperModel.largeVariant)
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 64, chipTier: .ultra, chipGeneration: 2) == LocalWhisperModel.largeVariant)
        // Pro chips are generation-gated. A call runs TWO concurrent streams,
        // so an early Pro that fits large-v3 in memory still cooks under it —
        // this is the machine that reported heat and glitching.
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 32, chipTier: .pro, chipGeneration: 1) == "small")
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 32, chipTier: .pro, chipGeneration: 2) == "small")
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 32, chipTier: .pro, chipGeneration: 4) == LocalWhisperModel.largeVariant)
        // Unknown generation is treated as old: a hot machine is worse than
        // slightly softer accuracy on a fallback engine.
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 32, chipTier: .pro, chipGeneration: nil) == "small")
        // Plain M-chips (every fanless Air) → small, even with plenty of RAM:
        // RAM fits large-v3, the chassis doesn't.
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 24, chipTier: .plain) == "small")
        // Low-memory performance chips → small (large-v3 would swap).
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: true, memoryGB: 8, chipTier: .pro) == "small")
        // Intel (no Neural Engine) → conservative regardless of memory.
        #expect(LocalWhisperModel.recommendedDefault(
            isAppleSilicon: false, memoryGB: 64, chipTier: nil) == "base")
    }

    @Test("post-call uses Turbo only when capable and already available")
    func postCallModelSelection() {
        let turbo = LocalWhisperModel.largeVariant
        #expect(LocalWhisperModel.postCallRefinementModel(
            liveModel: turbo,
            availableModels: [turbo],
            isAppleSilicon: true,
            memoryGB: 32,
            chipTier: .pro,
            chipGeneration: 4) == turbo)

        #expect(LocalWhisperModel.postCallRefinementModel(
            liveModel: "small",
            availableModels: ["small"],
            isAppleSilicon: true,
            memoryGB: 32,
            chipTier: .pro,
            chipGeneration: 4) == "small")

        #expect(LocalWhisperModel.postCallRefinementModel(
            liveModel: turbo,
            availableModels: [turbo, "small"],
            isAppleSilicon: true,
            memoryGB: 16,
            chipTier: .plain,
            chipGeneration: 4) == "small")
    }

    @Test("post-call never downloads Small over an available legacy Base")
    func postCallAvoidsSurpriseDownload() {
        #expect(LocalWhisperModel.postCallRefinementModel(
            liveModel: "base",
            availableModels: ["base"],
            isAppleSilicon: true,
            memoryGB: 32,
            chipTier: .pro,
            chipGeneration: 4) == "base")
    }

    @Test("legacy automatic base upgrades once without overriding deliberate choices")
    func legacyAutomaticBaseMigration() {
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .automatic,
            migrationCompleted: false, recommended: "small") == "small")
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .user,
            migrationCompleted: false, recommended: "small") == nil)
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .adaptive,
            migrationCompleted: false, recommended: "small") == nil)
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .legacyUnknown,
            migrationCompleted: false, recommended: "small") == nil)
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .automatic,
            migrationCompleted: false, recommended: "base") == nil)
        #expect(LocalWhisperModel.legacyAutomaticDefaultReplacement(
            saved: "base", provenance: .automatic,
            migrationCompleted: true, recommended: "small") == nil)
    }

    @Test("chip generation parses from the CPU brand string")
    func chipGenerationParse() {
        #expect(Hardware.appleChipGeneration(brand: "Apple M1 Pro") == 1)
        #expect(Hardware.appleChipGeneration(brand: "Apple M4 Max") == 4)
        #expect(Hardware.appleChipGeneration(brand: "Apple M2") == 2)
        #expect(Hardware.appleChipGeneration(brand: "Intel(R) Core(TM) i9") == nil)
    }

    @Test("chip tier parses from the CPU brand string")
    func chipTierParse() {
        #expect(Hardware.appleChipTier(brand: "Apple M1 Pro") == .pro)
        #expect(Hardware.appleChipTier(brand: "Apple M4 Max") == .max)
        #expect(Hardware.appleChipTier(brand: "Apple M3 Ultra") == .ultra)
        #expect(Hardware.appleChipTier(brand: "Apple M2") == .plain)
        #expect(Hardware.appleChipTier(brand: "Intel(R) Core(TM) i9") == nil)
    }

    @Test("sustained thermal pressure needs a streak; one hot reading is a spike")
    func thermalPolicy() {
        var r = LocalWhisperTranscription.isSustainedThermalPressure(state: .serious, currentStreak: 0)
        #expect(!r.hot && r.streak == 1)
        r = LocalWhisperTranscription.isSustainedThermalPressure(state: .critical, currentStreak: 2)
        #expect(r.hot && r.streak == 3)
        // Recovery resets the streak.
        r = LocalWhisperTranscription.isSustainedThermalPressure(state: .nominal, currentStreak: 2)
        #expect(!r.hot && r.streak == 0)
        r = LocalWhisperTranscription.isSustainedThermalPressure(state: .fair, currentStreak: 5)
        #expect(!r.hot && r.streak == 0)
    }

    @Test("the catalog offers exactly the unambiguous WhisperKit variants")
    func catalog() {
        let ids = LocalWhisperModel.options.map(\.id)
        // "large-v3" is NOT offered, and that is the point of this test: two
        // cached WhisperKit builds contain that substring and the resolver
        // matches on it, so the shipped id must name exactly one of them. They
        // measure 0.57x and 0.15x realtime — a difference a user feels live.
        #expect(ids == ["base", "small", LocalWhisperModel.largeVariant])
        #expect(!ids.contains("large-v3"))
        // Every option has an advantage-first title and a caption.
        #expect(LocalWhisperModel.options.allSatisfy { !$0.title.isEmpty && !$0.caption.isEmpty })
    }

    @Test("isKnown accepts catalog ids and rejects anything else")
    func known() {
        #expect(LocalWhisperModel.isKnown("small"))
        #expect(LocalWhisperModel.isKnown(LocalWhisperModel.largeVariant))
        // The ambiguous id is no longer an offered variant, but an install that
        // saved it still resolves — via migrated(), not by widening isKnown.
        #expect(LocalWhisperModel.isKnown("large-v3") == false)
        #expect(LocalWhisperModel.isKnown(LocalWhisperModel.migrated("large-v3")))
        #expect(LocalWhisperModel.isKnown("tiny") == false)      // valid WhisperKit name, but not offered
        #expect(LocalWhisperModel.isKnown("garbage") == false)
        #expect(LocalWhisperModel.isKnown("") == false)
    }

    @Test("adaptive downgrade stays local and stops at the validated base model")
    func adaptiveDowngradeLadder() {
        #expect(LocalWhisperModel.nextLighter(than: "large-v3") == "small")
        #expect(LocalWhisperModel.nextLighter(than: "small") == "base")
        #expect(LocalWhisperModel.nextLighter(than: "base") == nil)
        #expect(LocalWhisperModel.nextLighter(than: "tiny") == nil)
    }

    @Test("performance load accounts for both live audio sources")
    func effectiveRealtimeLoad() {
        let oneSource = LocalWhisperTranscription.effectiveRealtimeLoad(
            inferenceSeconds: 1.5, sampleCount: 96_000, activeSourceCount: 1
        )
        let twoSources = LocalWhisperTranscription.effectiveRealtimeLoad(
            inferenceSeconds: 1.5, sampleCount: 96_000, activeSourceCount: 2
        )
        #expect(abs(oneSource - 0.25) < 0.0001)
        #expect(abs(twoSources - 0.50) < 0.0001)
    }

    @Test("a sporadic or expired second source cannot double measured load")
    func recentSourceActivity() {
        #expect(LocalWhisperTranscription.recentActiveSourceCount(
            [(recentCount: 2, lastSeen: 99), (recentCount: 1, lastSeen: 99)],
            now: 100, activityWindow: 15
        ) == 1)
        #expect(LocalWhisperTranscription.recentActiveSourceCount(
            [(recentCount: 2, lastSeen: 99), (recentCount: 2, lastSeen: 99)],
            now: 100, activityWindow: 15
        ) == 2)
        #expect(LocalWhisperTranscription.recentActiveSourceCount(
            [(recentCount: 2, lastSeen: 70), (recentCount: 2, lastSeen: 70)],
            now: 100, activityWindow: 15
        ) == 1)
    }

    @Test("a shut down local service cannot restart its model")
    func shutdownClosesService() async {
        let local = LocalWhisperTranscription(model: "base")
        await local.shutdown()
        await #expect(throws: CancellationError.self) {
            _ = try await local.transcribe(wav: AudioFixtures.wav(), streamID: "0:mic")
        }
    }

    @Test("stop cancellation rejects queued generations without loading a model")
    func cancelQueuedGeneration() async throws {
        let local = LocalWhisperTranscription(model: "base")
        await local.cancelPendingTranscriptions(beforeGeneration: 2)
        let text = try await local.transcribe(
            wav: AudioFixtures.wav(), streamID: "1:mic"
        )
        #expect(text.isEmpty)
        await local.shutdown()
    }

    @Test("one slow inference cannot trigger an adaptive change")
    func sustainedOverload() {
        let first = LocalWhisperTranscription.isSustainedOverload(load: 0.9, currentStreak: 0)
        let second = LocalWhisperTranscription.isSustainedOverload(load: 0.9, currentStreak: first.streak)
        let third = LocalWhisperTranscription.isSustainedOverload(load: 0.9, currentStreak: second.streak)
        let recovered = LocalWhisperTranscription.isSustainedOverload(load: 0.2, currentStreak: third.streak)

        #expect(!first.overloaded)
        #expect(!second.overloaded)
        #expect(third.overloaded)
        #expect(recovered.streak == 0)
        #expect(!recovered.overloaded)
    }

    @Test("hardware probe answers without crashing and reports positive memory")
    func hardwareProbe() {
        _ = Hardware.isAppleSilicon                 // returns a Bool, no crash
        #expect(Hardware.physicalMemoryGB > 0)
    }

    @Test("Config.localWhisperModel honors a saved known choice and rejects garbage")
    func configPersistence() async {
        // Held across the whole test: `SettingsDuringCallTests` writes this same
        // key, and without the lock this read back its "small".
        await SharedDefaults.withExclusiveAccess { configPersistenceBody() }
    }

    private func configPersistenceBody() {
        let key = "transcription.localModel"
        let defaults = UserDefaults.standard
        let keys = [
            key,
            "transcription.localModelUserChosen",
            "transcription.localModelProvenance",
            Config.localModelHardwareDefaultMigrationKey,
        ]
        let saved = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // An EXPLICIT pick is never rewritten by the default correction that
        // downgrades machines the old ladder over-provisioned.
        Config.localModelChosenByUser = true
        Config.localWhisperModel = LocalWhisperModel.largeVariant
        #expect(Config.localWhisperModel == LocalWhisperModel.largeVariant)

        // Migration of the old ambiguous id is covered by
        // WhisperLeverFindingsTests.oldIDMigrates, against the pure function.
        // Asserting it here would mean writing the shared defaults key that
        // other suites read in parallel, and it raced them.

        // A stale/garbage stored value falls back to the hardware default.
        defaults.set("not-a-model", forKey: key)
        #expect(LocalWhisperModel.isKnown(Config.localWhisperModel))
    }

    @Test("compatibility mode avoids the Neural Engine for every model stage")
    func compatibilityComputePath() {
        let options = LocalWhisperTranscription.compatibilityComputeOptions
        #expect(options.melCompute == .cpuAndGPU)
        #expect(options.audioEncoderCompute == .cpuAndGPU)
        #expect(options.textDecoderCompute == .cpuAndGPU)
    }

    @Test("Intel starts on CPU/GPU without a Neural Engine failure retry")
    func intelStartsOnCompatibleCompute() {
        #expect(LocalWhisperTranscription.shouldUseCompatibilityCompute(
            savedMode: false, isIntel: true
        ))
        #expect(LocalWhisperTranscription.shouldUseCompatibilityCompute(
            savedMode: true, isIntel: false
        ))
        #expect(LocalWhisperTranscription.shouldUseCompatibilityCompute(
            savedMode: false, isIntel: false
        ) == false)
    }

    @Test("Auto independently routes a mixed-language sequence without locking")
    func adaptiveAutomaticLanguage() {
        let detections = ["en", "ru", "ja", "en"]
        let routed = detections.map { LocalWhisperTranscription.acceptedAutoLanguage($0) }
        #expect(routed == ["en", "ru", "ja", "en"])
    }

    @Test("Auto normalizes regions and rejects languages outside the shared engine set")
    func guardedAutomaticLanguage() {
        #expect(LocalWhisperTranscription.acceptedAutoLanguage("en-US") == "en")
        #expect(LocalWhisperTranscription.acceptedAutoLanguage("zh") == nil)
        #expect(LocalWhisperTranscription.acceptedAutoLanguage(
            "pl", supportedLanguages: ["pl"]
        ) == "pl")
    }

    @Test("Auto retries an unstable blip but preserves supported code switches")
    func automaticLanguageRecovery() {
        #expect(LocalWhisperTranscription.autoRecoveryLanguage(
            detected: ["zh", "uk"], previous: "ru") == "ru")
        #expect(LocalWhisperTranscription.autoRecoveryLanguage(
            detected: ["pt"], previous: "ru") == nil)
        #expect(LocalWhisperTranscription.autoRecoveryLanguage(
            detected: ["pt"], previous: "ru",
            acceptedHasReliableSpeech: false) == "ru")
        #expect(LocalWhisperTranscription.autoRecoveryLanguage(
            detected: ["zh"], previous: nil) == nil)
    }

    @Test("a clearly Cyrillic private call seeds Auto without replacing Auto")
    func cyrillicLanguageHint() {
        let russian = String(
            repeating: "мы обсуждаем продукт и следующие шаги ", count: 4)
        let english = String(
            repeating: "we are discussing the product and next steps ", count: 4)
        #expect(LocalWhisperTranscription.fallbackAutoLanguageHint(
            configured: "multi", recentText: russian) == "ru")
        #expect(LocalWhisperTranscription.fallbackAutoLanguageHint(
            configured: "multi", recentText: english) == nil)
        #expect(LocalWhisperTranscription.fallbackAutoLanguageHint(
            configured: "en", recentText: russian) == nil)
    }

    @Test("one supported conflict does not replace stable Auto; a sustained switch does")
    func autoLanguageConsensus() {
        let russian = LocalWhisperTranscription.AutoLanguageState(
            stable: "ru", conflictingCandidate: nil, conflictingCount: 0)
        let firstPortuguese = LocalWhisperTranscription.updatedAutoLanguageState(
            russian, observed: "pt")
        #expect(firstPortuguese.stable == "ru")
        #expect(firstPortuguese.conflictingCandidate == "pt")
        let secondPortuguese = LocalWhisperTranscription.updatedAutoLanguageState(
            firstPortuguese, observed: "pt")
        #expect(secondPortuguese.stable == "pt")
        #expect(secondPortuguese.conflictingCandidate == nil)
    }

    @Test("the Auto seed lasts one recording generation")
    func autoLanguageHintLifecycle() async {
        let local = LocalWhisperTranscription(
            model: "base", language: "multi", autoLanguageHint: "ru")
        await local.registerGenerationForTesting(20)
        #expect(await local.stableAutoLanguageForTesting() == "ru")
        await local.cancelPendingTranscriptions(beforeGeneration: 20)
        #expect(await local.stableAutoLanguageForTesting() == "ru")
        await local.registerGenerationForTesting(21)
        #expect(await local.stableAutoLanguageForTesting() == nil)
        await local.shutdown()

        let stoppedBeforeFirstChunk = LocalWhisperTranscription(
            model: "base", language: "multi", autoLanguageHint: "ru")
        await stoppedBeforeFirstChunk.cancelPendingTranscriptions(beforeGeneration: 30)
        #expect(await stoppedBeforeFirstChunk.stableAutoLanguageForTesting() == "ru")
        await stoppedBeforeFirstChunk.registerGenerationForTesting(31)
        #expect(await stoppedBeforeFirstChunk.stableAutoLanguageForTesting() == nil)
        await stoppedBeforeFirstChunk.shutdown()
    }

    @Test("Core ML prediction errors are recoverable, unrelated errors are not")
    func coreMLFailureClassification() {
        let prediction = NSError(
            domain: "com.apple.CoreML",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey:
                "Unable to compute the asynchronous prediction using ML Program. It can be an invalid input data or broken/unsupported model."]
        )
        #expect(LocalWhisperTranscription.isCoreMLPredictionFailure(prediction))
        #expect(LocalWhisperTranscription.isCoreMLPredictionFailure(
            NSError(domain: "WhisperKit.WhisperError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Language detection failed"])
        ))
        #expect(LocalWhisperTranscription.isCoreMLPredictionFailure(
            NSError(domain: NSURLErrorDomain, code: -1009,
                    userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        ) == false)
    }
}
