import Foundation

/// Elapsed recording time, with paused spans excluded.
///
/// The clock is what the user reads to know how long the meeting has run, and
/// it is also what the co-pilot hour meter bills against. Those must agree: if
/// the displayed time counts a paused span, someone who paused for lunch comes
/// back to an hour of billed silence.
///
/// Kept as a value type with no clock of its own so every case — paused across
/// a resume, stopped while paused, resumed twice — is testable without waiting
/// for real seconds to pass.
struct RecordingElapsed: Equatable {
    /// When the recording began. nil means nothing has started.
    private(set) var startedAt: Date?
    /// When the current pause began, if paused right now.
    private(set) var pausedAt: Date?
    /// Total time already spent paused, across every completed pause.
    private(set) var accumulatedPause: TimeInterval

    init(startedAt: Date? = nil, pausedAt: Date? = nil, accumulatedPause: TimeInterval = 0) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.accumulatedPause = max(0, accumulatedPause)
    }

    var isPaused: Bool { pausedAt != nil }
    var hasStarted: Bool { startedAt != nil }

    mutating func start(at now: Date) {
        startedAt = now
        pausedAt = nil
        accumulatedPause = 0
    }

    /// Pausing twice is a no-op rather than an error: the second press of a
    /// toggle should not restart the pause and lose the first span.
    mutating func pause(at now: Date) {
        guard startedAt != nil, pausedAt == nil else { return }
        pausedAt = now
    }

    /// Resuming while not paused is likewise a no-op.
    mutating func resume(at now: Date) {
        guard let began = pausedAt else { return }
        accumulatedPause += max(0, now.timeIntervalSince(began))
        pausedAt = nil
    }

    mutating func stop() {
        startedAt = nil
        pausedAt = nil
        accumulatedPause = 0
    }

    /// Seconds of ACTIVE recording — wall time since start, minus every paused
    /// span including one in progress.
    func activeSeconds(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let wall = max(0, now.timeIntervalSince(startedAt))
        let pausedNow = pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        // Clamped at zero: a clock that jumps backwards (NTP correction, manual
        // change) must not produce a negative duration in the UI or the meter.
        return max(0, wall - accumulatedPause - pausedNow)
    }

    /// Wall-clock span of the whole session, paused time included. Used where
    /// the question is "when did this meeting happen", not "how long was it
    /// live" — the saved session's start time, for instance.
    func wallSeconds(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }
}
