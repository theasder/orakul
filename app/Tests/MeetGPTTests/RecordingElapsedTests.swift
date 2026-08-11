import Foundation
import Testing
@testable import MeetGPT

/// Elapsed time with paused spans excluded.
///
/// This number is read twice: by the person watching the clock, and by the
/// co-pilot hour meter that bills against it. They have to agree. If the
/// displayed time counts a paused span, someone who paused for lunch returns to
/// an hour of billed silence — which is why every test here checks the ACTIVE
/// figure rather than wall time.
@Suite("Recording elapsed")
struct RecordingElapsedTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test("nothing started means nothing elapsed")
    func nothingStarted() {
        let elapsed = RecordingElapsed()
        #expect(elapsed.activeSeconds(at: at(500)) == 0)
        #expect(!elapsed.hasStarted)
        #expect(!elapsed.isPaused)
    }

    @Test("counts wall time while running")
    func countsWhileRunning() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        #expect(elapsed.activeSeconds(at: at(60)) == 60)
    }

    @Test("stops counting the moment it is paused")
    func stopsCountingWhilePaused() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(60))

        // Ten more minutes pass, none of it recorded.
        #expect(elapsed.activeSeconds(at: at(660)) == 60)
        #expect(elapsed.isPaused)
    }

    @Test("resumes from where it stopped, not from zero")
    func resumesWhereItStopped() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(60))
        elapsed.resume(at: at(660))

        #expect(!elapsed.isPaused)
        #expect(elapsed.activeSeconds(at: at(660)) == 60)
        // Thirty more active seconds.
        #expect(elapsed.activeSeconds(at: at(690)) == 90)
    }

    @Test("excludes every pause, not just the last one")
    func excludesEveryPause() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(10));  elapsed.resume(at: at(110))   // 100s paused
        elapsed.pause(at: at(120)); elapsed.resume(at: at(320))   // 200s paused

        // 320s wall, 300s paused, 20s active.
        #expect(elapsed.activeSeconds(at: at(320)) == 20)
        #expect(elapsed.wallSeconds(at: at(320)) == 320)
    }

    @Test("pausing twice does not lose the first span")
    func doublePauseIsIdempotent() {
        // A toggle pressed twice, or a pause arriving from two places at once.
        // Restarting the pause here would silently discard the elapsed pause.
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(10))
        elapsed.pause(at: at(50))
        elapsed.resume(at: at(110))

        #expect(elapsed.activeSeconds(at: at(110)) == 10)
    }

    @Test("resuming when not paused changes nothing")
    func resumeWithoutPauseIsNoop() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.resume(at: at(60))
        #expect(elapsed.activeSeconds(at: at(60)) == 60)
    }

    @Test("pausing before anything started does nothing")
    func pauseBeforeStart() {
        var elapsed = RecordingElapsed()
        elapsed.pause(at: t0)
        #expect(!elapsed.isPaused)
        #expect(elapsed.activeSeconds(at: at(60)) == 0)
    }

    @Test("starting again clears a previous session's pauses")
    func startResets() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(10))
        elapsed.resume(at: at(110))

        elapsed.start(at: at(200))
        // The new recording must not inherit 100s of someone else's pause.
        #expect(elapsed.activeSeconds(at: at(260)) == 60)
    }

    @Test("stopping clears everything")
    func stopClears() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(10))
        elapsed.stop()

        #expect(!elapsed.hasStarted)
        #expect(!elapsed.isPaused)
        #expect(elapsed.activeSeconds(at: at(500)) == 0)
    }

    @Test("stopping while paused is allowed and still ends the session")
    func stopWhilePaused() {
        // The acceptance criterion: stop from paused behaves like stop from
        // recording. Nothing may be left half-suspended.
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(60))
        elapsed.stop()
        #expect(!elapsed.hasStarted)
    }

    @Test("a clock that jumps backwards never yields negative time")
    func clockGoingBackwards() {
        // NTP correction or a manual clock change. A negative duration would
        // render as "-3:00" and, worse, could underflow the hour meter.
        var elapsed = RecordingElapsed()
        elapsed.start(at: at(100))
        #expect(elapsed.activeSeconds(at: t0) == 0)

        var paused = RecordingElapsed()
        paused.start(at: t0)
        paused.pause(at: at(60))
        paused.resume(at: at(30))   // resumed "before" it paused
        #expect(paused.activeSeconds(at: at(60)) >= 0)
    }

    @Test("a negative accumulated pause is refused at construction")
    func refusesNegativeAccumulation() {
        let elapsed = RecordingElapsed(startedAt: nil, pausedAt: nil, accumulatedPause: -500)
        #expect(elapsed.activeSeconds(at: t0) == 0)
    }

    @Test("wall time and active time diverge by exactly the paused span")
    func wallVersusActive() {
        var elapsed = RecordingElapsed()
        elapsed.start(at: t0)
        elapsed.pause(at: at(100))
        elapsed.resume(at: at(400))

        let now = at(500)
        #expect(elapsed.wallSeconds(at: now) - elapsed.activeSeconds(at: now) == 300)
    }
}
