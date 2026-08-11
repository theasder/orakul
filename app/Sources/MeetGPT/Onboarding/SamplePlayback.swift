import Foundation

/// Time, as the sample replay needs it.
///
/// The seam exists because the playback is the one piece of onboarding whose
/// correctness is entirely about *when* things appear — and a test that has to
/// wait eleven real seconds to find that out is a test nobody runs.
protocol SampleClock: AnyObject {
    /// Monotonic seconds. Only differences between readings are meaningful.
    var now: Double { get }
    func sleep(seconds: Double) async
}

/// System uptime rather than wall time: changing the clock, or crossing a
/// daylight-saving boundary mid-sample, must not rewind the transcript.
final class SystemSampleClock: SampleClock {
    var now: Double { ProcessInfo.processInfo.systemUptime }

    func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Drives the sample call's replay: which lines have been spoken, and which
/// co-pilot cards have landed.
///
/// Elapsed time is READ FROM THE CLOCK rather than accumulated a frame at a
/// time. `Task.sleep` guarantees a minimum and never an exact duration, so
/// adding a fixed step per frame makes the on-screen clock drift behind the
/// transcript and the sample outlast the duration it just told the user.
@MainActor
final class SamplePlayback: ObservableObject {
    @Published private(set) var elapsed: Double = 0

    /// How often the replay redraws. Fast enough to read as live, slow enough
    /// that it is not redrawing a sheet sixty times a second.
    static let frameSeconds: Double = 0.12

    private let script: SampleCall
    private let clock: any SampleClock
    private var startedAt: Double?
    private var running = false

    /// Nonisolated so a SwiftUI view can build one in its own (nonisolated)
    /// initializer — `@StateObject` needs the value up front. It only assigns
    /// stored properties, before the object is visible to anything else.
    nonisolated init(sample: SampleCall = .mobileBeta,
                     clock: any SampleClock = SystemSampleClock()) {
        self.script = sample
        self.clock = clock
    }

    // MARK: What the view renders

    var visibleLines: [SampleCall.Line] { script.lines(throughWallClock: elapsed) }
    var isSuggestionVisible: Bool { elapsed >= script.suggestionAtWallClock }
    var isDecisionVisible: Bool { elapsed >= script.decisionAtWallClock }
    var isFinished: Bool { elapsed >= script.wallClockSeconds }

    /// Position within the fictional call, for the "0:38 / 1:30" readout.
    var callSeconds: Double {
        min(script.durationSeconds, elapsed * SampleCall.playbackSpeed)
    }

    var totalCallSeconds: Double { script.durationSeconds }

    // MARK: Driving it

    /// Marks the start. Separate from `play()` so a test — or a paused view —
    /// can advance the clock by hand without racing a loop.
    func begin() {
        guard startedAt == nil else { return }
        startedAt = clock.now
        running = true
    }

    /// Recomputes elapsed from the clock, clamped at the end of the call, so a
    /// stalled frame catches up instead of overrunning.
    func sample(now: Double) {
        guard running, let startedAt else { return }
        elapsed = min(script.wallClockSeconds, now - startedAt)
    }

    /// Runs the replay to completion. `onFrame` fires after every update, which
    /// is what lets a test assert an invariant on every frame rather than only
    /// at the end.
    func play(onFrame: ((SamplePlayback) -> Void)? = nil) async {
        begin()
        onFrame?(self)
        while running, !isFinished {
            await clock.sleep(seconds: Self.frameSeconds)
            guard running else { return }
            sample(now: clock.now)
            onFrame?(self)
        }
    }

    func stop() { running = false }

    /// Reduced motion: the content is the point, the streaming is not.
    func completeImmediately() {
        startedAt = clock.now - script.wallClockSeconds
        running = false
        elapsed = script.wallClockSeconds
    }
}
