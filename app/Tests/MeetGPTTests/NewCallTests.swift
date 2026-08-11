import Foundation
import Testing
@testable import MeetGPT

/// Leaving a past call for a fresh one, and saying something useful when the
/// backend cannot be reached.
@MainActor
@Suite("Новый звонок")
struct NewCallTests {

    private func loadedState() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        state.transcript = [
            TranscriptEntry(source: .mic, text: "We agreed on usage-based pricing.",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        state.meetingTitle = "Pricing review"
        state.callGoal = "Agree the pricing model"
        state.aiResponse = "Here is the summary."
        state.contextFiles = [ImportedContextFile(name: "memo.pdf", text: "…")]
        state.contextNotes = "Bring up the renewal."
        return state
    }

    @Test("a loaded call can be left for a blank one")
    func offeredWhenLoaded() {
        #expect(loadedState().canStartNewCall)
    }

    @Test("an already-blank workspace does not offer it")
    func notOfferedWhenBlank() {
        #expect(!AppState(llm: MockLLMGateway(response: "unused")).canStartNewCall)
    }

    @Test("never offered mid-recording")
    func notOfferedWhileRecording() {
        let state = loadedState()
        state.status = .recording
        #expect(!state.canStartNewCall)
    }

    @Test("starting a new call empties the workspace")
    func clearsWorkspace() {
        let state = loadedState()
        state.startNewCall()

        #expect(state.transcript.isEmpty)
        #expect(state.meetingTitle.isEmpty)
        #expect(state.callGoal.isEmpty)
        #expect(state.aiResponse.isEmpty)
        #expect(state.aiHistory.isEmpty)
        #expect(!state.canStartNewCall)
    }

    @Test("the previous call's documents do not silently ground the new one")
    func clearsContext() {
        let state = loadedState()
        state.startNewCall()

        // resetForNewRecording deliberately KEEPS context (a new recording
        // usually wants the same documents). An explicitly blank call must not.
        #expect(state.contextFiles.isEmpty)
        #expect(state.contextNotes.isEmpty)
        #expect(state.composedContext.isEmpty)
    }

    @Test("the new call gets its own session id, so History keeps both")
    func newSessionIdentity() {
        let state = loadedState()
        let before = state.currentSessionID
        state.startNewCall()
        #expect(state.currentSessionID != before)
    }

    @Test("transient UI from the old call does not leak into the new one")
    func clearsTransientState() {
        let state = loadedState()
        state.updateTranscriptSelection("[09:00:00] Ana: something")
        state.lastError = "an old failure"
        state.startNewCall()

        #expect(!state.hasTranscriptSelection)
        #expect(state.pendingClarification == nil)
        #expect(state.answerActions.isEmpty)
        #expect(state.lastError == nil)
    }

    @Test("is a no-op while recording rather than discarding the meeting")
    func refusesWhileRecording() {
        let state = loadedState()
        state.status = .recording
        state.startNewCall()
        // Wiping a live transcript mid-call would lose the recording outright.
        #expect(!state.transcript.isEmpty)
        #expect(state.meetingTitle == "Pricing review")
    }
}

/// "Could not connect to the server." names neither the server nor the fix.
/// When answers route through the backend and it is not running, every prompt
/// fails with that sentence and nothing says the backend is why.
@MainActor
@Suite("Backend failure messages")
struct BackendErrorMessageTests {

    private func state() -> AppState {
        AppState(llm: MockLLMGateway(response: "unused"))
    }

    @Test("a refused connection names the backend and what to do")
    func namesTheBackend() {
        let message = state().explain(URLError(.cannotConnectToHost))
        guard Config.llmViaBackend, !Config.backendBaseURL.isEmpty else { return }

        #expect(message.contains(Config.backendBaseURL))
        #expect(message.contains("LLM_GATEWAY=backend"))
        #expect(!message.contains("Could not connect to the server."))
    }

    @Test("no network is reported as no network, not as a backend problem")
    func offlineIsDistinct() {
        let message = state().explain(URLError(.notConnectedToInternet))
        guard Config.llmViaBackend else { return }
        #expect(message.lowercased().contains("network"))
    }

    @Test("errors that are not connection failures keep their own text")
    func passesThroughOtherErrors() {
        struct Odd: LocalizedError { var errorDescription: String? { "Model refused the request." } }
        let message = state().explain(Odd())
        #expect(message == "Error: Model refused the request.")
    }

    @Test("every explanation still reads as an error")
    func alwaysPrefixed() {
        // canExportAssistantAnswer keys off the "Error:" prefix — an explanation
        // that dropped it would offer to export a failure as a document.
        for error in [URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.notConnectedToInternet)] {
            #expect(state().explain(error).hasPrefix("Error:"))
        }
    }
}
