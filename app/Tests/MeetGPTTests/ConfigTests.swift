import Testing
import Foundation
@testable import MeetGPT

/// `Config` is the app's settings surface: a mix of build-time `Secrets` values
/// and persisted `UserDefaults`. Pin the pure, deterministic logic — the
/// transcription-engine presentation + availability gating, the two-tier model
/// selection coercion, and the clamped/validated getters. Every test that
/// touches `UserDefaults` snapshots and restores the keys it writes.
@Suite("Transcription engine presentation")
struct TranscriptionEngineTests {
    @Test("allCases is local, server, deepgram, whisper — and id mirrors the raw value")
    func casesAndID() {
        #expect(TranscriptionEngine.allCases == [.local, .server, .deepgram, .whisper])
        for engine in TranscriptionEngine.allCases {
            #expect(engine.id == engine.rawValue)
        }
        #expect(TranscriptionEngine.local.rawValue == "local")
        #expect(TranscriptionEngine.server.rawValue == "server")
        #expect(TranscriptionEngine.deepgram.rawValue == "deepgram")
        #expect(TranscriptionEngine.whisper.rawValue == "whisper")
    }

    @Test("both Accurate rows are withheld, leaving Private and Instant")
    func withheldEngines() {
        // .server has no Whisper box behind it yet and .whisper is BYO-key,
        // which contradicts the app going keyless — and the two rendered as
        // duplicate "Accurate" headings.
        #expect(!TranscriptionEngine.selectableCases.contains(.server))
        #expect(!TranscriptionEngine.selectableCases.contains(.whisper))
        #expect(TranscriptionEngine.selectableCases == [.local, .deepgram])
        // Withheld, not deleted: a saved preference still resolves, so nobody
        // already on one of these engines is silently switched.
        #expect(TranscriptionEngine.allCases.contains(.server))
        #expect(TranscriptionEngine(rawValue: TranscriptionEngine.server.rawValue) == .server)
    }

    @Test("engineAvailable still gates .server on a backend and a session")
    func serverAvailabilityUnchanged() {
        // The backend/sign-in rule that used to drive the PICKER now lives only
        // in engineAvailable, which still governs a saved preference. Withholding
        // the row must not have loosened the runtime gate.
        #expect(Config.engineAvailable(.local))
        if Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            #expect(!Config.engineAvailable(.server))
        }
    }

    @Test("label carries the vendor + trade-off summary for each engine")
    func labels() {
        #expect(TranscriptionEngine.local.label == "Local · on-device Whisper")
        #expect(TranscriptionEngine.server.label == "Cruxwing · large-v3")
        #expect(TranscriptionEngine.deepgram.label == "Deepgram · live + speakers")
        #expect(TranscriptionEngine.whisper.label == "Whisper · OpenAI chunks")
    }

    @Test("advantageTitle leads with the trade-off, not the vendor")
    func advantageTitles() {
        #expect(TranscriptionEngine.local.advantageTitle == "Private — runs on this Mac")
        #expect(TranscriptionEngine.server.advantageTitle == "Accurate — large-v3 on Cruxwing")
        #expect(TranscriptionEngine.deepgram.advantageTitle == "Instant — word-by-word captions & speaker names")
        // The vendor name is gone: the row states the trade-off (who pays),
        // which is what actually distinguishes it from the Cruxwing row.
        #expect(TranscriptionEngine.whisper.advantageTitle == "Accurate — billed to your own API key")
        #expect(!TranscriptionEngine.whisper.advantageTitle.contains("OpenAI"))
    }

    @Test("advantageCaption answers the four business concerns: privacy, accuracy, speed, price")
    func advantageCaptions() {
        // The D35 frame: each option states where audio goes, how good the
        // words are, how fast captions land, and what it draws from credits.
        #expect(TranscriptionEngine.local.advantageCaption
            == "Audio never leaves your Mac; works offline. Solid accuracy, sized to your chip. Live captions a few seconds behind. Free — no credits.")
        #expect(TranscriptionEngine.server.advantageCaption
            == "Best accuracy — large-v3 + per-language models on Cruxwing servers only; audio is discarded after transcription. Live captions a few seconds behind; requires sign-in. ≈10 min per credit.")
        #expect(TranscriptionEngine.deepgram.advantageCaption
            == "Fastest live transcript with who-said-what, streamed to Deepgram's cloud. ≈4 min of streamed audio per credit; your own key bills Deepgram instead.")
        #expect(TranscriptionEngine.whisper.advantageCaption
            == "Bring your own OpenAI key; usage bills to your account, not your credits. Live captions a few seconds behind.")
        // Every caption covers privacy (where audio goes) and price.
        for engine in TranscriptionEngine.allCases {
            let caption = engine.advantageCaption.lowercased()
            #expect(caption.contains("mac") || caption.contains("cloud")
                    || caption.contains("servers") || caption.contains("your account"))
            #expect(caption.contains("credit") || caption.contains("free") || caption.contains("billed"))
        }
    }

    @Test("advantageSymbol maps each engine to its SF Symbol")
    func advantageSymbols() {
        #expect(TranscriptionEngine.local.advantageSymbol == "lock.laptopcomputer")
        #expect(TranscriptionEngine.server.advantageSymbol == "server.rack")
        #expect(TranscriptionEngine.deepgram.advantageSymbol == "bolt")
        #expect(TranscriptionEngine.whisper.advantageSymbol == "scope")
    }
}

// Serialized: these cases mutate the process-global UserDefaults key
// "transcription.engine"; Swift Testing runs tests in parallel by default.
@Suite("Config engine availability + persistence", .serialized)
struct ConfigEngineTests {
    @Test("local always runs; server needs backend + session; cloud engines gate on keys")
    func engineAvailability() {
        // On-device engine never depends on a secret.
        #expect(Config.engineAvailable(.local) == true)
        // Cruxwing Whisper (managed large-v3) is live — but only with a
        // backend AND a signed-in session: the gateway meters per user, and
        // an anonymous first-run must keep transcribing on-device.
        #expect(Config.serverWhisperEnabled == true)
        let backendConfigured = !Config.backendBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(Config.engineAvailable(.server)
            == (backendConfigured && Config.wheesprSession != nil))
        // Deepgram: a baked/BYO key OR the backend's credit-metered token
        // grant (signed-in only) — same session gate as the server engine.
        #expect(Config.engineAvailable(.deepgram)
            == (!Config.deepgramAPIKey.isEmpty
                || (backendConfigured && Config.wheesprSession != nil)))
        // Whisper API still mirrors whether its key is present in this build.
        #expect(Config.engineAvailable(.whisper) == !Config.openAIAPIKey.isEmpty)
    }

    @Test("transcriptionEngineValue round-trips an available engine through UserDefaults")
    func engineRoundTrip() {
        let key = "transcription.engine"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // .local is always available, so this is always non-nil.
        let available = TranscriptionEngine.allCases.first(where: Config.engineAvailable)
        #expect(available != nil)
        if let available {
            Config.transcriptionEngineValue = available
            #expect(Config.transcriptionEngineValue == available)
        }
    }

    @Test("an unrecognized stored engine falls back to the build/env default")
    func engineFallback() {
        let key = "transcription.engine"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set("not-an-engine", forKey: key)
        // Mirror the getter's fallback: env engine when available, else local.
        let env = TranscriptionEngine(rawValue: Secrets.transcriptionEngine.lowercased()) ?? .local
        let expected = Config.engineAvailable(env) ? env : .local
        #expect(Config.transcriptionEngineValue == expected)
    }
}

@Suite("Config validated getters")
struct ConfigGetterTests {
    @Test("transcriptionChunkSeconds stays clamped to [2, 15] (6 when unset/0)")
    func chunkSecondsClamp() {
        let seconds = Config.transcriptionChunkSeconds
        #expect(seconds >= 2)
        #expect(seconds <= 15)
        // Mirror the implementation so the clamp/default branch is pinned.
        let v = Double(Secrets.transcriptionChunkSeconds) ?? 0
        let expected = v > 0 ? min(max(v, 2), 15) : 6.0
        #expect(seconds == expected)
    }

    @Test("backendBaseURL resolves http as-is, off/none/direct to empty, else the product default")
    func backendDefault() {
        // `.ai`, not `.com` — the .com host is NXDOMAIN, so the old default
        // could only ever fail to connect.
        #expect(Config.defaultBackendBaseURL == "https://api.cruxwing.ai")
        let raw = Secrets.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            #expect(Config.backendBaseURL == raw)
            #expect(Config.backendBaseURL.hasPrefix("http"))
        } else if ["off", "none", "direct", "local"].contains(raw.lowercased()) {
            // Explicit no-backend opt-out (dev build with baked keys).
            #expect(Config.backendBaseURL == "")
        } else {
            #expect(Config.backendBaseURL == Config.defaultBackendBaseURL)
            #expect(Config.backendBaseURL.hasPrefix("http"))
        }
    }
    // Config.userCustomRole get/set is covered by RoleSkillMatrixTests
    // (customRoleGuidance) — kept there to avoid a cross-suite race on the
    // shared "skills.userCustomRole" defaults key under parallel execution.
}

@Suite("Config transcription language", .serialized)
struct ConfigTranscriptionLanguageTests {
    @Test("Auto keeps the provider value multi but uses the concise label")
    func autoOption() {
        let auto = Config.transcriptionLanguageOptions.first
        #expect(auto?.code == "multi")
        #expect(auto?.label == "Auto")
        #expect(Config.transcriptionLanguageOptions.contains {
            $0.label.contains("English + Russian")
        } == false)
    }

    @Test("Auto language set matches every fixed language offered in Settings")
    func automaticLanguageSet() {
        let fixed = Set(Config.transcriptionLanguageOptions.dropFirst().map { $0.code })
        #expect(Config.automaticTranscriptionLanguageCodes == fixed)
        #expect(fixed.contains("en"))
        #expect(fixed.contains("ru"))
        #expect(fixed.count > 2)
    }

    @Test("transcription factories snapshot language for one recording")
    func factoryLanguageSnapshot() async throws {
        let key = "transcription.language"
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        Config.transcriptionLanguage = "en"
        let firstLocal = try #require(
            TranscriptionFactory.make(engine: .local) as? LocalWhisperTranscription
        )
        let firstCloud = try #require(
            TranscriptionFactory.make(engine: .whisper) as? WhisperAPITranscription
        )
        let firstServer = try #require(
            TranscriptionFactory.make(engine: .server) as? ServerFallbackTranscription
        )

        Config.transcriptionLanguage = "ru"
        let nextLocal = try #require(
            TranscriptionFactory.make(engine: .local) as? LocalWhisperTranscription
        )
        let nextCloud = try #require(
            TranscriptionFactory.make(engine: .whisper) as? WhisperAPITranscription
        )
        let nextServer = try #require(
            TranscriptionFactory.make(engine: .server) as? ServerFallbackTranscription
        )

        #expect(await firstLocal.languageSnapshot() == "en")
        #expect(firstCloud.languageSnapshot() == "en")
        #expect(firstServer.languageSnapshot() == "en")
        #expect(await nextLocal.languageSnapshot() == "ru")
        #expect(nextCloud.languageSnapshot() == "ru")
        #expect(nextServer.languageSnapshot() == "ru")

        await firstLocal.shutdown()
        await nextLocal.shutdown()
    }
}

@Suite("Connected-app grounding preference", .serialized)
struct ConnectedAppsGroundingConfigTests {
    @Test("a split legacy preference migrates to one conservative off switch")
    func migratesSplitLegacyState() {
        let defaults = UserDefaults.standard
        let keys = ["grounding.connectedApps", "grounding.apps", "grounding.team"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.removeObject(forKey: "grounding.connectedApps")
        defaults.set(true, forKey: "grounding.apps")
        defaults.set(false, forKey: "grounding.team")

        #expect(Config.connectedAppsGroundingEnabled == false)
        #expect(defaults.object(forKey: "grounding.connectedApps") as? Bool == false)

        Config.connectedAppsGroundingEnabled = true
        #expect(Config.groundAppsEnabled)
        #expect(Config.groundTeamEnabled)
    }
}

// Serialized: these cases mutate the global "llm.selectedProvider" /
// "llm.selectedVersion" defaults keys.
@Suite("Config two-tier model selection", .serialized)
struct ConfigModelSelectionTests {
    private let providers: [LLMProvider] = [
        .openAI, .anthropic, .google, .deepSeek, .qwen, .zhipu, .moonshot,
    ]

    private func preservingSelection(_ body: () -> Void) {
        let savedProvider = Config.selectedProvider
        let savedVersion = Config.selectedVersion
        defer {
            Config.selectedProvider = savedProvider
            Config.selectedVersion = savedVersion
        }
        body()
    }

    @Test("Auto and a concrete model round-trip through both representations")
    func autoAndConcrete() {
        preservingSelection {
            // Start with stale values so each setter must replace both keys.
            Config.selectedProvider = LLMProvider.anthropic.rawValue
            Config.selectedVersion = "stale-version"
            Config.selectedModelID = LLMCatalog.autoID
            #expect(Config.selectedProvider == LLMCatalog.autoID)
            #expect(Config.selectedVersion == LLMCatalog.autoID)
            #expect(Config.selectedModelID == LLMCatalog.autoID)
            #expect(Config.selectedModel.id == LLMCatalog.autoID)
            #expect(Config.selectedRequestModel.id == LLMCatalog.autoID)
            #expect(Config.selectedRequestModel.requestSelectionID == LLMCatalog.autoID)

            let concrete = "gpt-5.4-mini"
            Config.selectedModelID = concrete
            #expect(Config.selectedProvider == LLMProvider.openAI.rawValue)
            #expect(Config.selectedVersion == concrete)
            #expect(Config.selectedModelID == concrete)
            #expect(Config.selectedRequestModel.requestSelectionID == concrete)
        }
    }

    @Test("every provider-pinned Auto sentinel round-trips and preserves affinity")
    func providerPinnedAuto() {
        preservingSelection {
            for provider in providers {
                let selection = "auto:\(provider.rawValue)"
                Config.selectedProvider = LLMCatalog.autoID
                Config.selectedVersion = "stale-version"

                Config.selectedModelID = selection

                #expect(Config.selectedProvider == provider.rawValue)
                #expect(Config.selectedVersion == LLMCatalog.autoID)
                #expect(Config.selectedModelID == selection)
                #expect(Config.selectedRequestModel.id == LLMCatalog.autoID)
                #expect(Config.selectedRequestModel.provider == provider)
                #expect(Config.selectedRequestModel.requestSelectionID == selection)
            }
        }
    }

    @Test("both jurisdiction councils round-trip through the legacy setter")
    func councilPresets() {
        preservingSelection {
            for selection in [LLMCatalog.councilUS, LLMCatalog.councilCN] {
                Config.selectedProvider = LLMProvider.google.rawValue
                Config.selectedVersion = "stale-version"

                Config.selectedModelID = selection

                #expect(Config.selectedProvider == selection)
                #expect(Config.selectedVersion == LLMCatalog.autoID)
                #expect(Config.selectedModelID == selection)
                #expect(Config.selectedModel.id == LLMCatalog.autoID)
                #expect(Config.selectedRequestModel.id == LLMCatalog.autoID)
                #expect(Config.selectedRequestModel.requestSelectionID == selection)
            }
        }
    }

    @Test("every orchestration level round-trips through the legacy setter")
    func orchestrationLevelSelection() {
        preservingSelection {
            for level in OrchestrationLevel.allCases {
                Config.selectedProvider = LLMProvider.deepSeek.rawValue
                Config.selectedVersion = "stale-version"

                Config.selectedModelID = level.selectionID

                #expect(Config.selectedProvider == level.selectionID)
                #expect(Config.selectedVersion == LLMCatalog.autoID)
                #expect(Config.selectedModelID == level.selectionID)
                #expect(Config.selectedModel.id == LLMCatalog.autoID)
                #expect(Config.selectedRequestModel.id == LLMCatalog.autoID)
                #expect(Config.selectedRequestModel.requestSelectionID == level.selectionID)
            }
        }
    }

    @Test("invalid sentinel lookalikes leave the persisted selection atomic")
    func invalidSentinelsAreIgnored() {
        preservingSelection {
            Config.selectedModelID = "gpt-5.4-mini"
            let expectedProvider = Config.selectedProvider
            let expectedVersion = Config.selectedVersion

            for invalid in [
                "auto:not-a-provider", "auto:", "council:eu",
                "orchestrate:impossible", "not-a-model",
            ] {
                Config.selectedModelID = invalid
                #expect(Config.selectedProvider == expectedProvider)
                #expect(Config.selectedVersion == expectedVersion)
                #expect(Config.selectedModelID == "gpt-5.4-mini")
            }
        }
    }

    @Test("AppState and Config retain the same sentinel after Settings writes")
    @MainActor
    func appStateAndConfigStayEqual() {
        preservingSelection {
            Config.selectedModelID = LLMCatalog.autoID
            let state = AppState(credentialStore: InMemoryKeychain())
            let selections = [
                LLMCatalog.autoID,
                "auto:\(LLMProvider.anthropic.rawValue)",
                LLMCatalog.councilUS,
                OrchestrationLevel.ultra.selectionID,
                "gpt-5.4-mini",
            ]

            for selection in selections {
                state.selectedModelID = selection
                #expect(state.selectedModelID == selection)
                #expect(Config.selectedModelID == state.selectedModelID)
            }
        }
    }
}
