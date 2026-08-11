import Foundation
import Testing
@testable import MeetGPT

/// Behavior of the recording → transcript path in `AppState` — the layer that
/// broke the reported bug (a blank transcript with no feedback while the
/// on-device model loaded). Drives it with an injected mock engine.
@MainActor
@Suite("AppState transcription behavior")
struct AppStateTranscriptionTests {
    @Test("a transcribed chunk appends a transcript entry and marks ready")
    func appendsEntry() async {
        let mock = MockTranscriptionService(text: "the crux")
        let state = AppState(transcriber: mock)
        await state.dispatchTranscription(wav: AudioFixtures.wav(), source: .mic)
        #expect(state.transcript.count == 1)
        #expect(state.transcript.first?.text == "the crux")
        #expect(state.transcript.first?.source == .mic)
        #expect(state.transcriptionState == .ready)
    }

    @Test("blank recognition adds no transcript line")
    func blankSkipped() async {
        let mock = MockTranscriptionService(text: "   ")
        let state = AppState(transcriber: mock)
        await state.dispatchTranscription(wav: AudioFixtures.wav(), source: .system)
        #expect(state.transcript.isEmpty)
    }

    @Test("a recording chunk stays bound to its own transcriber")
    func sessionTranscriberBinding() async {
        let defaultMock = MockTranscriptionService(text: "wrong backend")
        let recordingMock = MockTranscriptionService(text: "recording backend")
        let state = AppState(transcriber: defaultMock)

        await state.dispatchTranscription(
            wav: AudioFixtures.wav(), source: .mic,
            using: recordingMock, engine: .local
        )

        #expect(state.transcript.first?.text == "recording backend")
        #expect(await recordingMock.transcribeCount == 1)
        #expect(await defaultMock.transcribeCount == 0)
    }

    @Test("a stale chunk is rejected before any transcription provider call")
    func staleChunkRejectedBeforeProvider() async {
        let mock = MockTranscriptionService(text: "must not run")
        let state = AppState(transcriber: mock)
        state.clearAll() // generation 0 is now stale

        await state.dispatchTranscription(
            wav: AudioFixtures.wav(), source: .system,
            generation: 0, using: mock, engine: .local
        )

        #expect(await mock.transcribeCount == 0)
        #expect(state.transcript.isEmpty)
    }

    @Test("clearAll invalidates an in-flight chunk so it can't resurrect a line")
    func generationGuard() async {
        let mock = MockTranscriptionService(text: "stale")
        await mock.setPause(true)
        let state = AppState(transcriber: mock)
        let task = Task { await state.dispatchTranscription(wav: AudioFixtures.wav(), source: .mic) }

        var waited = 0
        while await mock.transcribeCount == 0, waited < 2000 {
            try? await Task.sleep(nanoseconds: 10_000_000); waited += 10
        }
        state.clearAll()          // bumps the chunk generation
        await mock.releaseGate()  // let the stale transcription finish
        await task.value
        #expect(state.transcript.isEmpty)
        #expect(state.transcriptionState == .idle)
    }

    @Test("restoring History rejects a late final chunk from the stopped meeting")
    func restoreInvalidatesLateFinalChunk() async {
        let mock = MockTranscriptionService(text: "late words from old meeting")
        await mock.setPause(true)
        let state = AppState(transcriber: mock)
        let task = Task {
            await state.dispatchTranscription(wav: AudioFixtures.wav(), source: .mic)
        }

        var waited = 0
        while await mock.transcribeCount == 0, waited < 2000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }

        let restoredEntry = TranscriptEntry(source: .system, text: "restored meeting")
        let restored = SavedSession(
            id: UUID(), title: "History", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedAt: Date(), goal: "", entries: [restoredEntry], aiResponse: "", digest: ""
        )
        state.restoreSession(restored)
        await mock.releaseGate()
        await task.value

        #expect(state.currentSessionID == restored.id)
        #expect(state.transcript == [restoredEntry])
        #expect(state.transcriptionState == .idle)
    }

    @Test("prepareLocalModel warms the model and reports ready")
    func prewarmReady() async {
        let mock = MockTranscriptionService()
        let state = AppState(transcriber: mock)
        state.prepareLocalModel()
        await waitUntil { state.transcriptionState == .ready }
        #expect(state.transcriptionState == .ready)
        #expect(await mock.prewarmCount == 1)
    }

    @Test("prepareLocalModel surfaces a model-load failure instead of a blank transcript")
    func prewarmFails() async {
        let mock = MockTranscriptionService()
        await mock.setPrewarmError(testError("no network"))
        let state = AppState(transcriber: mock)
        state.prepareLocalModel()
        await waitUntil { if case .failed = state.transcriptionState { return true } else { return false } }
        if case .failed(let message) = state.transcriptionState {
            #expect(message.contains("no network"))
        } else {
            Issue.record("expected .failed, got \(state.transcriptionState)")
        }
        #expect(state.lastError != nil)
    }

    @Test("prepareLocalModel is idempotent once the model is ready")
    func prewarmIdempotent() async {
        let mock = MockTranscriptionService()
        let state = AppState(transcriber: mock)
        state.transcriptionState = .ready
        state.prepareLocalModel()
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(await mock.prewarmCount == 0)
    }

    @Test("a transcribe failure on the local engine surfaces as failed")
    func dispatchErrorFailsLocal() async {
        guard Config.transcriptionEngineValue == .local else { return }
        let mock = MockTranscriptionService()
        await mock.setTranscribeError(testError("model gone"))
        let state = AppState(transcriber: mock)
        // Regression: a successful prewarm left the state ready, and runtime
        // Core ML failures were swallowed behind "Listening to the room".
        state.transcriptionState = .ready
        await state.dispatchTranscription(
            wav: AudioFixtures.wav(), source: .mic, engine: .local)
        #expect(state.lastError != nil)
        if case .failed = state.transcriptionState {} else {
            Issue.record("expected .failed, got \(state.transcriptionState)")
        }

        // Dismissing a circuit-broken recording's toast must stick; the next
        // queued chunk reports the same failure but does not republish it.
        state.lastError = nil
        await state.dispatchTranscription(
            wav: AudioFixtures.wav(), source: .mic, engine: .local)
        #expect(state.lastError == nil)
    }

    @Test("an error from a cleared recording cannot fail the current UI")
    func staleErrorSkipped() async {
        guard Config.transcriptionEngineValue == .local else { return }
        let mock = MockTranscriptionService()
        await mock.setTranscribeError(testError("old model error"))
        await mock.setPause(true)
        let state = AppState(transcriber: mock)
        let task = Task { await state.dispatchTranscription(wav: AudioFixtures.wav(), source: .mic) }

        var waited = 0
        while await mock.transcribeCount == 0, waited < 2000 {
            try? await Task.sleep(nanoseconds: 10_000_000); waited += 10
        }
        state.clearAll()
        await mock.releaseGate()
        await task.value

        #expect(state.lastError == nil)
        #expect(state.transcriptionState == .idle)
    }
}
