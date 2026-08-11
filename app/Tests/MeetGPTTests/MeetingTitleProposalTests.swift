import Foundation
import Testing
@testable import MeetGPT

/// Untitled meeting, five minutes in → propose a name from the transcript.
@Suite("Meeting title proposal")
struct MeetingTitleProposalTests {
    @Test("proposes only while recording, untitled, with some transcript")
    func policyMatrix() {
        // The one state that proposes:
        #expect(MeetingTitleProposal.shouldPropose(
            title: "", transcriptCharacters: 80, isRecording: true))
        #expect(MeetingTitleProposal.shouldPropose(
            title: "   ", transcriptCharacters: 1, isRecording: true))
        // Everything else stays quiet:
        #expect(!MeetingTitleProposal.shouldPropose(
            title: "Weekly sync", transcriptCharacters: 500, isRecording: true))
        #expect(!MeetingTitleProposal.shouldPropose(
            title: "", transcriptCharacters: 0, isRecording: true))   // no transcript → invention
        #expect(!MeetingTitleProposal.shouldPropose(
            title: "", transcriptCharacters: 500, isRecording: false))
    }

    @Test("accept applies the proposal once; dismiss discards it")
    @MainActor
    func acceptAndDismiss() {
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        state.suggestedMeetingTitle = "Falcon budget planning"
        state.acceptSuggestedMeetingTitle()
        #expect(state.meetingTitle == "Falcon budget planning")
        #expect(state.suggestedMeetingTitle == nil)

        state.suggestedMeetingTitle = "Another name"
        state.dismissSuggestedMeetingTitle()
        #expect(state.meetingTitle == "Falcon budget planning")   // untouched
        #expect(state.suggestedMeetingTitle == nil)
    }

    @Test("a new recording clears a stale proposal")
    @MainActor
    func resetClearsProposal() {
        let state = AppState(llm: MockLLMGateway(response: ""),
                             credentialStore: InMemoryKeychain())
        state.suggestedMeetingTitle = "Stale title"
        state.resetForNewRecording()
        #expect(state.suggestedMeetingTitle == nil)
    }
}
