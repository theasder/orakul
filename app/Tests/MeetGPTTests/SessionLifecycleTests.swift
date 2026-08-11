import Foundation
import Testing
@testable import MeetGPT

/// Session lifecycle: a new recording must start a clean meeting so History
/// doesn't fill with tracks that each re-contain every earlier un-cleared
/// meeting. `resetForNewRecording()` is what `startRecording()` runs once
/// capture has actually begun (the audio path itself needs hardware, so we
/// drive the reset directly).
@MainActor
@Suite("Session lifecycle")
struct SessionLifecycleTests {
    private func meetingState() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.transcript = [
            TranscriptEntry(source: .mic, text: "meeting one, first line"),
            TranscriptEntry(source: .system, text: "meeting one, second line")
        ]
        state.meetingTitle = "Meeting One"
        state.callGoal = "close the Q3 renewal"
        state.suggestions = [Suggestion(title: "old idea", detail: "d", kind: .advice)]
        return state
    }

    @Test("a new recording does NOT inherit the prior meeting's transcript")
    func doesNotInheritTranscript() {
        let state = meetingState()
        let firstID = state.currentSessionID

        state.resetForNewRecording()

        #expect(state.transcript.isEmpty)          // the merge bug: prior lines are gone
        #expect(state.currentSessionID != firstID) // its own History file
        #expect(state.meetingTitle == "")
        #expect(state.callGoal == "")
        #expect(state.suggestions.isEmpty)
        #expect(state.followUpPrompts.isEmpty)
    }

    @Test("calendar metadata names the meeting without duplicating it as the visible goal")
    func appliesCalendarMeetingName() {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.callGoal = "Дизайн-синк"

        state.applyCalendarAgenda(CalendarAgenda(
            title: "Дизайн-синк",
            summary: "Review the new flow",
            attendeeCount: 3
        ))

        #expect(state.meetingTitle == "Дизайн-синк")
        #expect(state.callGoal.isEmpty)
        #expect(state.suggestedGoal != "Дизайн-синк")
        #expect(state.effectiveCallGoal == "Дизайн-синк")

        state.meetingTitle = "Название пользователя"
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Calendar overwrite",
            summary: "",
            attendeeCount: 2
        ))
        #expect(state.meetingTitle == "Название пользователя")
    }

    @Test("a new recording drops prior research results but keeps reusable context")
    func dropsEphemeralResearchContext() {
        let state = meetingState()
        state.contextFiles = [
            ImportedContextFile(name: "Research · Notion", text: "Old meeting"),
            ImportedContextFile(name: "Customer brief.pdf", text: "Reusable context"),
        ]

        state.resetForNewRecording()

        #expect(state.contextFiles.map(\.name) == ["Customer brief.pdf"])
    }

    @Test("persistCurrentSession is a no-op for a workspace that was never recorded")
    func skipsUnrecordedScratch() {
        let state = AppState(llm: MockLLMGateway(response: ""))
        // A transcript with no recordingStartedAt = AI-only scratch, not a meeting.
        state.transcript = [TranscriptEntry(source: .mic, text: "scratch")]
        state.savedSessions = []

        state.persistCurrentSession()

        // Nothing was written back into the published list.
        #expect(state.savedSessions.isEmpty)
    }

    @Test("stopping keeps session provenance for History; clearing removes it")
    func stopRetainsStartUntilClear() async {
        let state = AppState(
            transcriber: MockTranscriptionService(),
            llm: MockLLMGateway(response: "")
        )
        let startedAt = Date()
        let session = SavedSession(
            id: UUID(), title: "", startedAt: startedAt, savedAt: startedAt,
            goal: "", entries: [], aiResponse: "", digest: ""
        )
        state.restoreSession(session)

        // Exercise the real stop path without hardware capture. An empty
        // transcript also keeps this test away from SessionStore.shared.
        state.status = .recording
        state.toggleRecording()
        await waitUntil { state.status == .idle }

        #expect(state.recordingStartedAt == startedAt)
        state.clearAll()
        #expect(state.recordingStartedAt == nil)
    }

    @Test("restoring History synchronously releases a running AI and Fact Check")
    func restoreCancelsAIState() {
        let state = meetingState()
        state.aiStreaming = true
        state.factChecking = true
        state.showFactCheck = true
        state.aiStage = "Verify factual claims"
        state.aiTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        let saved = SavedSession(
            id: UUID(), title: "Saved", startedAt: Date(), savedAt: Date(),
            goal: "Review", entries: [], aiResponse: "Prior answer",
            aiResponsePrompt: "What did we decide?",
            aiResponseExportTitle: "Prior Decision",
            digest: "")

        state.restoreSession(saved)

        #expect(!state.aiStreaming)
        #expect(!state.factChecking)
        #expect(!state.showFactCheck)
        #expect(state.aiTask == nil)
        #expect(state.workflowSteps.isEmpty)
        #expect(state.aiResponse == "Prior answer")
        #expect(state.aiResponsePrompt == "What did we decide?")
        #expect(state.aiResponseExportTitle == "Prior Decision")
    }

    @Test("Clear releases a canceled Fact Check so it can be run again")
    func clearCancelsFactCheckState() {
        let state = meetingState()
        state.aiStreaming = true
        state.factChecking = true
        state.showFactCheck = true
        state.aiStage = "Verify factual claims"
        state.aiTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }

        state.clearAll()

        #expect(!state.aiStreaming)
        #expect(!state.factChecking)
        #expect(!state.showFactCheck)
        #expect(state.aiTask == nil)
        #expect(state.workflowSteps.isEmpty)
        #expect(state.aiResponsePrompt.isEmpty)
        #expect(state.aiResponseExportTitle == nil)
    }
}
