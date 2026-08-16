import Foundation
import Testing
@testable import MeetGPT

/// Nothing spoken after Stop may reach the transcript.
///
/// Reported and reproduced: Stop was pressed, a YouTube video was watched, and
/// its narration appeared in the transcript. Two mechanisms combined to allow
/// it. `stopRecording` bumps `chunkGeneration` and then RETAGS the recording
/// token to the new value — which is what preserves the final partial buffers,
/// but it also makes the streamer callbacks' `chunkGeneration == token` guard
/// pass again, so it rejects nothing. And `ingestStreamedLine` deliberately
/// persists when `status != .recording`, to catch the trailing final Deepgram
/// sends after its socket closes.
///
/// Each is reasonable alone; together they accepted a line arriving at ANY
/// later time. This is a privacy boundary, not a tidiness one: the transcript
/// is written to disk and fed to a model, so audio the user believes was never
/// recorded must not enter it.
@Suite("Post-stop capture boundary")
@MainActor
struct PostStopCaptureTests {

    private func recordingState() -> AppState {
        let app = AppState(credentialStore: InMemoryKeychain())
        app.applyTestWorkspace(recording: true)
        return app
    }

    @Test("while recording, lines are accepted")
    func acceptsWhileRecording() {
        let app = recordingState()
        app.ingestStreamedLine(text: "something said during the meeting", source: .system)
        #expect(app.transcript.count == 1)
    }

    @Test("a trailing final just after Stop is still kept")
    func keepsTheTrailingFinal() {
        // The legitimate case the window exists for: Deepgram holds its socket
        // open briefly to deliver the last utterance. Dropping it clips the end
        // of every meeting.
        let app = recordingState()
        app.applyTestStopInstant(Date())
        app.applyTestWorkspace(recording: false)
        app.ingestStreamedLine(text: "the last thing anyone actually said", source: .system)
        #expect(app.transcript.count == 1)
    }

    @Test("a line arriving well after Stop is dropped")
    func dropsLateLines() {
        // The reported bug, at the boundary that separates the two cases.
        let app = recordingState()
        app.applyTestStopInstant(Date().addingTimeInterval(-(AppState.postStopGraceWindow + 1)))
        app.applyTestWorkspace(recording: false)
        app.ingestStreamedLine(text: "narration from a video watched after stopping", source: .system)
        #expect(app.transcript.isEmpty, "post-stop audio reached the transcript")
    }

    @Test("the boundary holds for both capture tracks")
    func dropsLateLinesFromEitherSource() {
        // The system track is the one that caught the video, but the microphone
        // is the more sensitive of the two — a conversation in the room after
        // the meeting ended.
        for source in [TranscriptSource.system, .mic] {
            let app = recordingState()
            app.applyTestStopInstant(Date().addingTimeInterval(-60))
            app.applyTestWorkspace(recording: false)
            app.ingestStreamedLine(text: "said long after the meeting ended", source: source)
            #expect(app.transcript.isEmpty, "\(source) leaked past the boundary")
        }
    }

    @Test("a long gap after Stop never reopens the window")
    func windowDoesNotReopen() {
        // Minutes and hours later must behave exactly like seconds later. The
        // old guard passed forever, so "how late" was never bounded at all.
        for age in [10.0, 300.0, 3_600.0, 86_400.0] {
            let app = recordingState()
            app.applyTestStopInstant(Date().addingTimeInterval(-age))
            app.applyTestWorkspace(recording: false)
            app.ingestStreamedLine(text: "audio captured \(age)s after stop", source: .system)
            #expect(app.transcript.isEmpty, "accepted a line \(age)s after Stop")
        }
    }

    @Test("starting a new recording clears the stop instant")
    func newRecordingReopensCapture() {
        // Otherwise the first recording's Stop would permanently suppress the
        // NEXT meeting — the same bug with the sign flipped.
        let app = recordingState()
        app.applyTestStopInstant(Date().addingTimeInterval(-3_600))
        app.applyTestWorkspace(recording: false)
        app.ingestStreamedLine(text: "should be dropped", source: .system)
        #expect(app.transcript.isEmpty)

        app.applyTestStopInstant(nil)
        app.applyTestWorkspace(recording: true)
        app.ingestStreamedLine(text: "a new meeting begins", source: .system)
        #expect(app.transcript.count == 1, "a new recording must capture again")
    }

    @Test("with no recording ever started, ingestion is not blocked")
    func noStopInstantIsNotABlock() {
        // Restoring a session and importing a transcript both ingest lines with
        // no recording in play; a nil stop instant must not be read as "late".
        let app = AppState(credentialStore: InMemoryKeychain())
        app.ingestStreamedLine(text: "an imported line", source: .system)
        #expect(app.transcript.count == 1)
    }

    @Test("streamed-final drain is bounded and test-overridable")
    func streamedFinalDrainDelay() {
        let retiredAt = Date(timeIntervalSinceReferenceDate: 100)
        let stop = retiredAt.addingTimeInterval(60)
        #expect(AppState.streamedFinalDrainBoundaryAtStop(
            hadActiveStream: false,
            previouslyRetiredAt: retiredAt,
            stopBoundary: stop) == stop)
        #expect(AppState.streamedFinalDrainBoundaryAtStop(
            hadActiveStream: false,
            previouslyRetiredAt: nil,
            stopBoundary: stop) == nil)
        #expect(AppState.remainingStreamedFinalDrainDelay(
            retiredAt: retiredAt,
            now: retiredAt.addingTimeInterval(1)) == 2)
        #expect(AppState.remainingStreamedFinalDrainDelay(
            retiredAt: retiredAt,
            now: retiredAt.addingTimeInterval(4)) == 0)
        AppState.$streamedFinalDrainGraceWindow.withValue(0) {
            #expect(AppState.remainingStreamedFinalDrainDelay(
                retiredAt: retiredAt,
                now: retiredAt) == 0)
        }
    }
}
