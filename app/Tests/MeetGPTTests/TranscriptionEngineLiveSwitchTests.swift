import AVFoundation
import Foundation
import Testing
@testable import MeetGPT

@MainActor
@Suite("Live transcription engine switching", .serialized)
struct TranscriptionEngineLiveSwitchTests {
    private func snapshot(engine: TranscriptionEngine) -> RecordingSettingsSnapshot {
        RecordingSettingsSnapshot(
            engine: engine,
            language: "en",
            localModel: "base",
            microphoneNoiseSuppression: false,
            glossary: "Falcon-SLA, Kubernetes",
            assemblyDiarization: false)
    }

    @Test("choosing Instant replaces the active Local engine during the call")
    func localToInstantUpdatesActiveRuntimeState() {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local
        var handoffs: [TranscriptionEngine] = []
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionEngineSwitchOverride: { engine in
                handoffs.append(engine)
                return true
            })
        state.applyTestActiveRecordingSettings(snapshot(engine: .local))
        state.applyTestWorkspace(recording: true)

        #expect(state.selectTranscriptionEngine(.deepgram))
        #expect(handoffs == [.deepgram])
        #expect(state.liveTranscriptionConfiguration().active?.engine == .deepgram)
        #expect(state.selectedTranscriptionEngine == .deepgram)
        #expect(state.pendingEngineChange == nil)
    }

    @Test("a failed Instant handoff keeps Local active and reports the failure")
    func failedInstantHandoffIsHonest() {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionEngineSwitchOverride: { _ in false })
        state.applyTestActiveRecordingSettings(snapshot(engine: .local))
        state.applyTestWorkspace(recording: true)

        #expect(!state.selectTranscriptionEngine(.deepgram))
        #expect(state.liveTranscriptionConfiguration().active?.engine == .local)
        #expect(state.selectedTranscriptionEngine == .local)
        #expect(state.pendingEngineChange == nil)
        #expect(Config.transcriptionEngineValue == .local)
        // Сообщение собирается из названия движка: «Он продолжается на
        // «Приватно — считается на этом компьютере»».
        #expect(state.lastError?.contains("продолжается на «Приватно") == true)
    }

    @Test("rapid switches converge for streaming and every chunked engine")
    func rapidCrossEngineSwitchesConverge() {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local
        var handoffs: [TranscriptionEngine] = []
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionEngineSwitchOverride: { engine in
                handoffs.append(engine)
                return true
            })
        state.applyTestActiveRecordingSettings(snapshot(engine: .local))
        state.applyTestWorkspace(recording: true)

        let order: [TranscriptionEngine] = [.deepgram, .server, .whisper, .local]
        for engine in order {
            #expect(state.selectTranscriptionEngine(engine))
            #expect(state.liveTranscriptionConfiguration().active?.engine == engine)
            #expect(state.pendingEngineChange == nil)
        }
        #expect(handoffs == order)
    }

    @Test("an asynchronous Instant rollback updates the Settings selection model")
    func asynchronousRollbackUpdatesPublishedSelection() {
        let savedEngine = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = savedEngine }
        Config.transcriptionEngineValue = .local
        let local = snapshot(engine: .local)
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            transcriptionEngineSwitchOverride: { _ in true })
        state.applyTestActiveRecordingSettings(local)
        state.applyTestWorkspace(recording: true)

        #expect(state.selectTranscriptionEngine(.deepgram))
        #expect(state.selectedTranscriptionEngine == .deepgram)
        state.applyTestTranscriptionEngineRollback(local)

        #expect(state.selectedTranscriptionEngine == .local)
        #expect(state.liveTranscriptionConfiguration().active?.engine == .local)
        #expect(Config.transcriptionEngineValue == .local)
    }

    @Test("pre-ready Deepgram failure is one-shot; a healthy stream no longer rolls back")
    func deepgramHandoffResolution() {
        let failed = DeepgramHandoffState()
        #expect(failed.claimPreReadyFailure() == .claimedRollback)
        #expect(failed.claimPreReadyFailure() == .rollbackAlreadyClaimed)

        let oneTrackOnly = DeepgramHandoffState()
        #expect(!oneTrackOnly.markRoutesCutOver())
        #expect(!oneTrackOnly.markReady(.system))
        // This is the state observed by the production startup deadline: one
        // healthy socket must not strand the other track in reconnect forever.
        #expect(oneTrackOnly.claimPreReadyFailure() == .claimedRollback)

        let ready = DeepgramHandoffState()
        #expect(!ready.markRoutesCutOver())
        #expect(!ready.markReady(.system))
        #expect(ready.markReady(.microphone))
        #expect(!ready.markReady(.system))
        #expect(ready.claimPreReadyFailure() == .healthyStream)
        #expect(DeepgramHandoffState.readinessTimeoutNanoseconds > 0)
    }

    @Test("handoff flushes partial audio once to the old engine and routes only future samples")
    func bufferHandoffPreservesPartialAudioWithoutReplay() {
        var localChunks = 0
        var instantChunks = 0
        var streamedSamples = 0
        let buffer = AudioChunkBuffer(chunkSeconds: 1) { _, _ in localChunks += 1 }

        // Leave a voiced partial chunk in the Local accumulator.
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.6))
        #expect(localChunks == 0)

        buffer.reconfigure(
            onChunk: { _, _ in instantChunks += 1 },
            onSamples: { streamedSamples += $0.count },
            flushBufferedSamplesToPreviousHandler: true)
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 1.2))

        #expect(localChunks == 1)
        #expect(instantChunks == 1)
        #expect(streamedSamples >= 16_000)
    }
}
