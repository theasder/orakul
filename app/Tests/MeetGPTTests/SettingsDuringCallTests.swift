import Foundation
import Testing
@testable import MeetGPT

private final class SettingsBarrierGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var recordedModels: [String] = []
    private var recordedSelections: [String] = []

    var models: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedModels
    }

    var selections: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedSelections
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let call = lock.withLock {
            recordedModels.append(model.id)
            recordedSelections.append(model.requestSelectionID ?? model.id)
            return recordedModels.count
        }
        if call == 1 {
            await withCheckedContinuation { pending in
                lock.lock()
                if releaseRequested {
                    lock.unlock()
                    pending.resume()
                } else {
                    continuation = pending
                    lock.unlock()
                }
            }
        }
        let answer = call == 1 ? "Draft grounded in the call." : "Audited grounded answer."
        onDelta(answer)
        return answer
    }

    func releaseFirst() {
        lock.lock()
        releaseRequested = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

@Suite("Co-pilot active interval accounting")
struct CopilotActiveIntervalTests {
    private let origin = Date(timeIntervalSince1970: 1_000)

    @Test("enable/disable segments bill their union rather than final state")
    func segmentedCall() {
        var meter = CopilotActiveTimeMeter()
        meter.begin(enabled: false, at: origin)
        meter.transition(to: true, at: origin.addingTimeInterval(10))
        meter.transition(to: false, at: origin.addingTimeInterval(25))
        meter.transition(to: true, at: origin.addingTimeInterval(40))
        #expect(meter.finish(at: origin.addingTimeInterval(55)) == 30)
    }

    @Test("last-second changes cannot charge or erase the whole call")
    func boundaryChanges() {
        var disabledAtStop = CopilotActiveTimeMeter()
        disabledAtStop.begin(enabled: true, at: origin)
        disabledAtStop.transition(to: false, at: origin.addingTimeInterval(59))
        #expect(disabledAtStop.finish(at: origin.addingTimeInterval(60)) == 59)

        var enabledAtStop = CopilotActiveTimeMeter()
        enabledAtStop.begin(enabled: false, at: origin)
        enabledAtStop.transition(to: true, at: origin.addingTimeInterval(59))
        #expect(enabledAtStop.finish(at: origin.addingTimeInterval(60)) == 1)
    }

    @Test("idempotent writes and backwards clocks never double bill")
    func idempotenceAndClockBoundary() {
        var meter = CopilotActiveTimeMeter()
        meter.begin(enabled: true, at: origin)
        meter.transition(to: true, at: origin.addingTimeInterval(5))
        meter.transition(to: false, at: origin.addingTimeInterval(10))
        meter.transition(to: false, at: origin.addingTimeInterval(20))
        #expect(meter.finish(at: origin.addingTimeInterval(30)) == 10)

        meter.begin(enabled: true, at: origin)
        #expect(meter.finish(at: origin.addingTimeInterval(-5)) == 0)
    }
}

@MainActor
@Suite("Settings during a call", .serialized)
struct SettingsDuringCallTests {
    enum Watch: CaseIterable {
        case brainstorm, agenda, factCheck, rhetoric, facilitation
    }

    private struct SavedFlags {
        let brainstorm = Config.brainstormEnabled
        let agenda = Config.agendaCheckerEnabled
        let factCheck = Config.factCheckDuringCallsEnabled
        let rhetoric = Config.rhetoricDuringCallsEnabled
        let facilitation = Config.facilitationDuringCallsEnabled

        func restore() {
            Config.brainstormEnabled = brainstorm
            Config.agendaCheckerEnabled = agenda
            Config.factCheckDuringCallsEnabled = factCheck
            Config.rhetoricDuringCallsEnabled = rhetoric
            Config.facilitationDuringCallsEnabled = facilitation
        }
    }

    private func configureAll(_ enabled: Bool) {
        Config.brainstormEnabled = enabled
        Config.agendaCheckerEnabled = enabled
        Config.factCheckDuringCallsEnabled = enabled
        Config.rhetoricDuringCallsEnabled = enabled
        Config.facilitationDuringCallsEnabled = enabled
    }

    private func set(_ watch: Watch, _ enabled: Bool, on state: AppState) {
        switch watch {
        case .brainstorm: state.setBlindSpotsEnabled(enabled)
        case .agenda: state.setAgendaCheckingEnabled(enabled)
        case .factCheck: state.setFactCheckDuringCallsEnabled(enabled)
        case .rhetoric: state.setRhetoricDuringCallsEnabled(enabled)
        case .facilitation: state.setFacilitationDuringCallsEnabled(enabled)
        }
    }

    private func pair(_ watch: Watch, in activity: AppState.LiveWatchActivity) -> (Bool, Bool) {
        switch watch {
        case .brainstorm: return (activity.brainstormConfigured, activity.brainstormTaskActive)
        case .agenda: return (activity.agendaConfigured, activity.agendaTaskActive)
        case .factCheck: return (activity.factCheckConfigured, activity.factCheckTaskActive)
        case .rhetoric: return (activity.rhetoricConfigured, activity.rhetoricTaskActive)
        case .facilitation: return (activity.facilitationConfigured, activity.facilitationTaskActive)
        }
    }

    @Test("every co-pilot switch reconciles exactly its own task in every call state")
    func everyWatchTransition() {
        let saved = SavedFlags()
        defer { saved.restore() }

        for recording in [false, true] {
            for watch in Watch.allCases {
                configureAll(false)
                let state = AppState(credentialStore: InMemoryKeychain())
                state.applyTestWorkspace(recording: recording)

                set(watch, true, on: state)
                var activity = state.liveWatchActivity()
                #expect(pair(watch, in: activity).0)
                #expect(pair(watch, in: activity).1 == recording)

                // Repeating the same value must not create a second task or
                // affect another watch.
                set(watch, true, on: state)
                activity = state.liveWatchActivity()
                for other in Watch.allCases where other != watch {
                    #expect(pair(other, in: activity) == (false, false))
                }

                set(watch, false, on: state)
                #expect(pair(watch, in: state.liveWatchActivity()) == (false, false))
            }
        }
    }

    @Test("all 120 rapid enable orders converge and can be stopped cleanly")
    func rapidOrders() {
        let saved = SavedFlags()
        defer { saved.restore() }

        func permutations(_ items: [Watch]) -> [[Watch]] {
            guard !items.isEmpty else { return [[]] }
            return items.enumerated().flatMap { index, item in
                var rest = items
                rest.remove(at: index)
                return permutations(rest).map { [item] + $0 }
            }
        }

        for order in permutations(Watch.allCases) {
            configureAll(false)
            let state = AppState(credentialStore: InMemoryKeychain())
            state.applyTestWorkspace(recording: true)
            for watch in order { set(watch, true, on: state) }
            let allOn = state.liveWatchActivity()
            for watch in Watch.allCases { #expect(pair(watch, in: allOn) == (true, true)) }
            for watch in order.reversed() { set(watch, false, on: state) }
            let allOff = state.liveWatchActivity()
            for watch in Watch.allCases { #expect(pair(watch, in: allOff) == (false, false)) }
        }
    }

    @Test("engine switch-away and revert report pending state honestly")
    func pendingEngineRevert() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let active = RecordingSettingsSnapshot(
            engine: .local, language: "en", localModel: "base",
            microphoneNoiseSuppression: false, glossary: "Falcon",
            assemblyDiarization: false)
        state.applyTestActiveRecordingSettings(active)
        state.applyTestWorkspace(recording: true)

        state.notePendingEngineChange(.whisper)
        #expect(state.pendingEngineChange == .whisper)
        #expect(state.liveTranscriptionConfiguration().active == active)

        state.notePendingEngineChange(.local)
        #expect(state.pendingEngineChange == nil)
        #expect(state.liveTranscriptionConfiguration().active == active)
    }

    @Test("revoking consent during a call affects only the next recording")
    func consentRevocationIsDeferred() {
        let saved = Config.recordingConsentAccepted
        defer { Config.recordingConsentAccepted = saved }

        Config.recordingConsentAccepted = true
        let active = AppState(credentialStore: InMemoryKeychain())
        active.applyTestWorkspace(recording: true)
        Config.recordingConsentAccepted = false
        #expect(active.isRecording)
        #expect(!active.showRecordingConsent)

        let nextCall = AppState(credentialStore: InMemoryKeychain())
        nextCall.toggleRecording()
        #expect(nextCall.showRecordingConsent)
        #expect(!nextCall.isRecording)
    }

    @Test("a model change during generation applies only to the next answer")
    func answerModelSnapshot() async throws {
        LLMCatalog.resetHydration()
        let savedModel = Config.selectedModelID
        defer { Config.selectedModelID = savedModel }
        let modelA = try #require(LLMCatalog.fallback.first { $0.id == "gpt-5.4-mini" })
        let modelB = try #require(LLMCatalog.fallback.first { $0.id == "gemini-3.5-flash" })
        Config.selectedModelID = modelA.id
        let gateway = SettingsBarrierGateway()
        let state = AppState(llm: gateway, credentialStore: InMemoryKeychain())
        state.selectedModelID = modelA.id
        state.transcript = [
            TranscriptEntry(source: .system,
                            text: "We committed to ship Falcon on Friday after the SLA review.")
        ]
        // A custom prompt deliberately skips the 1,188-skill relevance index;
        // this test isolates Settings/model synchronization rather than catalog
        // warmup. Its silent follow-up is the second model call.
        let prompt = QuickPrompt.custom(
            id: "custom-model-snapshot", icon: "✨", title: "Model snapshot",
            prompt: "Summarize the Falcon commitment.")

        state.runPrompt(prompt)
        // Other prompt suites intentionally contend for the process-wide
        // bundled-skill worker. Wait for the observable provider boundary,
        // rather than treating five seconds of unrelated catalog work as a
        // model-selection failure under the full parallel test run.
        for _ in 0..<45_000 {
            if !gateway.models.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(gateway.models.first == modelA.id)
        state.selectedModelID = modelB.id
        gateway.releaseFirst()
        await state.aiTask?.value
        for _ in 0..<45_000 {
            if gateway.models.count >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let expectedAudit = LLMCatalog.fastAudit(for: modelA).id
        #expect(gateway.models.count >= 2)
        #expect(gateway.models[0] == modelA.id)
        #expect(gateway.models[1] == expectedAudit)
        #expect(gateway.selections[0] == modelA.id)
        #expect(state.aiResponseModelID == modelA.id)
        #expect(state.selectedModelID == modelB.id)
    }

    @Test("provider-pinned Auto selection is immutable while an answer starts")
    func providerPinnedAutoSnapshot() async throws {
        LLMCatalog.resetHydration()
        let savedProvider = Config.selectedProvider
        let savedVersion = Config.selectedVersion
        defer {
            Config.selectedProvider = savedProvider
            Config.selectedVersion = savedVersion
        }
        Config.selectedProvider = LLMProvider.anthropic.rawValue
        Config.selectedVersion = LLMCatalog.autoID
        let pinnedSelection = Config.selectedModelID
        #expect(pinnedSelection == "auto:anthropic")

        let gateway = SettingsBarrierGateway()
        let state = AppState(llm: gateway, credentialStore: InMemoryKeychain())
        state.transcript = [TranscriptEntry(
            source: .system,
            text: "The Falcon rollout needs an SLA decision before Friday.")]
        let prompt = QuickPrompt.custom(
            id: "auto-provider-snapshot", icon: "✨", title: "Snapshot",
            prompt: "What should we decide next?")

        state.runPrompt(prompt)
        for _ in 0..<45_000 {
            if !gateway.selections.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(gateway.selections.first == pinnedSelection)
        #expect(state.aiResponseModelID == pinnedSelection)

        Config.selectedModelID = "gpt-5.4-mini"
        state.selectedModelID = "gpt-5.4-mini"
        gateway.releaseFirst()
        await state.aiTask?.value
        #expect(gateway.selections.first == pinnedSelection)
        #expect(state.aiResponseModelID == pinnedSelection)
        #expect(state.selectedModelID == "gpt-5.4-mini")
    }
}

@Suite("Recording settings isolation", .serialized)
struct RecordingSettingsIsolationTests {
    @Test("configured values are immutable for one recording")
    func immutableSnapshot() {
        // Writes transcription Config keys that LocalWhisperModelTests reads.
        // Same process-wide UserDefaults, different suites, so `.serialized`
        // does not cover it.
        SharedDefaults.withExclusiveAccess { immutableSnapshotBody() }
    }

    private func immutableSnapshotBody() {
        let savedEngine = Config.transcriptionEngineValue
        let savedLanguage = Config.transcriptionLanguage
        let savedModel = Config.localWhisperModel
        let savedAEC = Config.micNoiseSuppressionEnabled
        let savedGlossary = Config.transcriptionGlossary
        let savedDiarization = Config.assemblyAIDiarizationEnabled
        defer {
            Config.transcriptionEngineValue = savedEngine
            Config.transcriptionLanguage = savedLanguage
            Config.localWhisperModel = savedModel
            Config.micNoiseSuppressionEnabled = savedAEC
            Config.transcriptionGlossary = savedGlossary
            Config.assemblyAIDiarizationEnabled = savedDiarization
        }

        Config.transcriptionEngineValue = .local
        Config.transcriptionLanguage = "en"
        Config.localWhisperModel = "base"
        Config.micNoiseSuppressionEnabled = false
        Config.transcriptionGlossary = "Falcon, Kubernetes"
        Config.assemblyAIDiarizationEnabled = false
        let active = RecordingSettingsSnapshot.configured()

        Config.transcriptionEngineValue = .whisper
        Config.transcriptionLanguage = "ru"
        Config.localWhisperModel = "small"
        Config.micNoiseSuppressionEnabled = true
        Config.transcriptionGlossary = "Orion"
        Config.assemblyAIDiarizationEnabled = true

        #expect(active.engine == .local)
        #expect(active.language == "en")
        #expect(active.localModel == "base")
        #expect(!active.microphoneNoiseSuppression)
        #expect(active.glossaryTerms == ["Falcon", "Kubernetes"])
        #expect(!active.assemblyDiarization)
        #expect(RecordingSettingsSnapshot.configured().language == "ru")
        #expect(RecordingSettingsSnapshot.configured().microphoneNoiseSuppression)
        #expect(RecordingSettingsSnapshot.configured().glossaryTerms == ["Orion"])
    }

    @Test("all streamers retain glossary A after Config changes to B")
    func glossarySnapshots() async {
        let saved = Config.transcriptionGlossary
        defer { Config.transcriptionGlossary = saved }
        Config.transcriptionGlossary = "Falcon, Kubernetes"

        let local = LocalWhisperTranscription(glossary: Config.transcriptionGlossary)
        let whisper = WhisperAPITranscription(glossary: Config.transcriptionGlossary)
        let server = ServerWhisperTranscription(glossary: Config.transcriptionGlossary)
        let deepgram = DeepgramStreamer(
            apiKey: "test", diarize: false, keyterms: Config.glossaryTerms)

        Config.transcriptionGlossary = "Orion"
        #expect(await local.glossarySnapshot() == "Falcon, Kubernetes")
        #expect(whisper.glossarySnapshot() == "Falcon, Kubernetes")
        #expect(server.glossarySnapshot() == "Falcon, Kubernetes")
        #expect(deepgram.keytermsSnapshot() == ["Falcon", "Kubernetes"])
    }
}
