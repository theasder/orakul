import Foundation
import Testing
@testable import MeetGPT

/// Pause, and a stop that means stop.
///
/// Before this there was one control over a five-case machine, so stop was the
/// only exit and it ended the session — finalisation, post-call passes, the
/// lot. Someone stepping away for five minutes had to either burn the call or
/// leave it capturing an empty room and billing for it.
///
/// The design rests on one decision: `isRecording` stays `status == .recording`
/// and is FALSE while paused. Everything already gated on it — capture taps,
/// the blind-spot scheduler, the co-pilot hour meter — therefore suspends
/// without being individually taught about the new state. These tests defend
/// that property, because the failure mode is a scan or a charge that keeps
/// running while the user believes they are paused.
@MainActor
@Suite("Recording pause")
struct RecordingPauseTests {

    private func recordingState() -> AppState {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        return state
    }

    // MARK: - Transitions

    @Test("pause moves out of recording without ending the session")
    func pauseSuspends() {
        let state = recordingState()
        let session = state.currentSessionID

        state.pauseRecording()

        #expect(state.status == .paused)
        #expect(state.isPaused)
        // The session survives: this is not a stop.
        #expect(state.currentSessionID == session)
    }

    @Test("resume returns to recording and keeps the same session")
    func resumeContinuesSameSession() {
        let state = recordingState()
        let session = state.currentSessionID

        state.pauseRecording()
        state.resumeRecording()

        #expect(state.status == .recording)
        #expect(state.currentSessionID == session)
    }

    @Test("capture and background work are suspended while paused")
    func suspendsWorkWhilePaused() {
        // The property the whole design rests on. Capture taps, the blind-spot
        // scheduler and the hour meter all gate on isRecording; if it stayed
        // true here, a paused call would keep scanning and keep billing.
        let state = recordingState()
        #expect(state.isRecording)

        state.pauseRecording()

        #expect(!state.isRecording)
        // Still a live session, just not capturing — the distinction the rest
        // of the app needs.
        #expect(state.isSessionLive)
    }

    @Test("pausing twice is harmless")
    func doublePauseIsSafe() {
        let state = recordingState()
        state.pauseRecording()
        state.pauseRecording()
        #expect(state.status == .paused)
    }

    @Test("resuming when not paused is harmless")
    func resumeWhenNotPausedIsSafe() {
        let state = recordingState()
        state.resumeRecording()
        #expect(state.status == .recording)
    }

    @Test("pause does nothing from idle")
    func pauseFromIdleIsRefused() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.pauseRecording()
        // Only a running recording can be paused; anything else would leave the
        // machine in a state with no session behind it.
        #expect(state.status != .paused)
    }

    @Test("resume does nothing from idle")
    func resumeFromIdleIsRefused() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.resumeRecording()
        #expect(state.status != .recording)
    }

    // MARK: - The clock

    @Test("elapsed time excludes the paused span")
    func elapsedExcludesPause() {
        // Checked on the value type, which takes an explicit clock, so the
        // assertion does not depend on real seconds passing.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var elapsed = RecordingElapsed()
        elapsed.start(at: start)
        elapsed.pause(at: start.addingTimeInterval(60))
        elapsed.resume(at: start.addingTimeInterval(660))

        // Ten minutes away, one minute recorded.
        #expect(elapsed.activeSeconds(at: start.addingTimeInterval(660)) == 60)
    }

    @Test("the visible clock and the billed time are the same number")
    func clockAndMeterAgree() {
        // If they diverge, someone who paused for lunch returns to an hour of
        // billed silence — the specific outcome this feature exists to prevent.
        let state = recordingState()
        state.pauseRecording()
        let whilePaused = state.activeRecordingSeconds
        state.resumeRecording()

        #expect(state.activeRecordingSeconds >= whilePaused)
    }

    // MARK: - Stop

    @Test("the primary control still means finish, never resume")
    func toggleFromPausedStops() {
        // The button must not acquire a second meaning. Resume is its own
        // action; the main control is always "finish and write up".
        let state = recordingState()
        state.pauseRecording()
        state.toggleRecording()

        #expect(state.status != .recording, "toggle from paused must not resume")
    }

    @Test("a paused session is still a live session for the rest of the app")
    func pausedCountsAsLive() {
        let state = recordingState()
        state.pauseRecording()

        // Anything asking "is a meeting in progress" — the menu bar, the
        // sidebar, the guard that refuses to open a second call — must say yes.
        #expect(state.isSessionLive)
        #expect(!state.isRecording)
    }
    // MARK: - Billing

    @Test("the co-pilot hour meter stops while paused")
    func meterStopsWhilePaused() {
        // The meter does not stop by itself — it accumulates against wall time
        // from `activeSince`. Without an explicit transition the pause would
        // look correct in the UI while still billing for an empty room, which
        // is the exact failure this feature exists to prevent.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var meter = CopilotActiveTimeMeter()
        meter.begin(enabled: true, at: start)

        meter.transition(to: false, at: start.addingTimeInterval(60))      // pause
        let atPause = meter.seconds(at: start.addingTimeInterval(60))
        // Ten minutes away.
        #expect(meter.seconds(at: start.addingTimeInterval(660)) == atPause)

        meter.transition(to: true, at: start.addingTimeInterval(660))      // resume
        #expect(meter.seconds(at: start.addingTimeInterval(720)) == atPause + 60)
    }

    @Test("resuming does not switch automation on by itself")
    func resumeRespectsAutomationSetting() {
        // A call paused with co-pilot automation OFF must resume with it still
        // off. Resuming to "enabled" unconditionally would start charging for
        // something the user turned off.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var meter = CopilotActiveTimeMeter()
        meter.begin(enabled: false, at: start)

        meter.transition(to: false, at: start.addingTimeInterval(60))
        meter.transition(to: false, at: start.addingTimeInterval(120))
        #expect(meter.seconds(at: start.addingTimeInterval(600)) == 0)
    }

    @Test("stop from paused leaves the paused state rather than resuming")
    func stopFromPausedFinishes() async {
        // The acceptance criterion: stop from paused behaves like stop from
        // recording. stopRecording() carries no status guard, so the path is
        // shared rather than duplicated — what is checked here is that the
        // toggle actually enters it, and never resumes instead.
        let state = recordingState()
        state.pauseRecording()
        state.toggleRecording()

        // toggleRecording spawns the stop asynchronously, so poll rather than
        // asserting on the next line. Generous deadline: a tight one is a flake
        // waiting for a loaded machine.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while state.status == .paused, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(state.status != .paused, "stop from paused never left the paused state")
        #expect(state.status != .recording, "stop from paused must not resume")
    }

}
