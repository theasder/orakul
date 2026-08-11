import Testing
import Foundation
@testable import MeetGPT

private final class BlindSpotSuspensionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    /// Resumed the moment the paused task begins.
    ///
    /// Two earlier shapes both measured the scheduler instead of the product.
    /// Polling `hasStarted` for a second lost whenever ~2,500 tests were queued
    /// on the MainActor ahead of it. Replacing that with a DispatchSemaphore
    /// waited off the MainActor but BLOCKED a cooperative-pool thread to do it —
    /// and a blocked pool thread is exactly what stops the @MainActor task it is
    /// waiting for from ever being scheduled. Under a full run that deadlocked
    /// against itself until the 30-second backstop expired, so the suite failed
    /// on a test whose subject had behaved correctly all along.
    ///
    /// Continuations suspend instead of blocking: no thread is held, no clock is
    /// consulted, and the waiter resumes when the event happens.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        // Resume OUTSIDE the lock — resuming a continuation can run the waiter
        // synchronously, and doing that under the lock invites a deadlock.
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            started = true
            defer { startWaiters.removeAll() }
            return startWaiters
        }
        waiting.forEach { $0.resume() }
    }

    func markFinished() { lock.withLock { finished = true } }
    var hasStarted: Bool { lock.withLock { started } }
    var hasFinished: Bool { lock.withLock { finished } }

    /// Suspends — never blocks — until the paused task starts.
    ///
    /// No timeout parameter on purpose. A timeout here could only ever be a
    /// guess about how busy the machine is, and every value that has been tried
    /// was eventually wrong. If the task genuinely never starts, the test hangs
    /// and Swift Testing's own time limit reports it, which is the honest
    /// signal: "never happened", not "did not happen within my guess".
    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyStarted: Bool = lock.withLock {
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }
}

/// The measured problem: one hour of Pro conversation spent 204 compute credits
/// against a 250-credit MONTHLY allowance, so Pro ran dry after ~74 minutes — two
/// calls. Blind spots were 120 of that, and the three 300s watches another 72.
@Suite("Background spend policy")
struct BackgroundSpendPolicyTests {
    // MARK: New-material gate

    @Test("the first run of a call always proceeds")
    func firstRunProceeds() {
        // No baseline yet, and waiting would leave the panel silent through the
        // opening minutes — the part of a call where framing matters most.
        #expect(BackgroundSpendPolicy.shouldRun(totalCharacters: 50, charactersAtLastRun: nil))
    }

    @Test("a tick after one sentence does not spend")
    func tinyIncrementSkipped() {
        // This is what `transcript.count` allowed: one new line unblocked a
        // full-price call.
        #expect(BackgroundSpendPolicy.shouldRun(
            totalCharacters: 4_000, charactersAtLastRun: 3_950) == false)
    }

    @Test("a tick after real conversation spends")
    func realIncrementRuns() {
        #expect(BackgroundSpendPolicy.shouldRun(
            totalCharacters: 4_400, charactersAtLastRun: 4_000))
    }

    @Test("blind spots use a lower bar than the ambient watches")
    func blindSpotsAreMoreEager() {
        // They are the user-visible loop; the others are ambient notes.
        #expect(BackgroundSpendPolicy.minimumNewCharactersForBlindSpots
                < BackgroundSpendPolicy.minimumNewCharacters)
        let delta = BackgroundSpendPolicy.minimumNewCharactersForBlindSpots + 1
        #expect(BackgroundSpendPolicy.shouldRun(
            totalCharacters: delta, charactersAtLastRun: 0,
            minimumNew: BackgroundSpendPolicy.minimumNewCharactersForBlindSpots))
    }

    @Test("higher tiers accept smaller funded transcript deltas")
    func tieredBlindSpotMaterialGate() {
        let values = [Tier.free, .pro, .premium, .ultra]
            .map(BackgroundSpendPolicy.blindSpotMinimumNewCharacters(for:))
        #expect(values == [180, 150, 120, 90])
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test("a goal edit bypasses only the new-material gate")
    func goalEditRefreshesBlindSpot() {
        #expect(!BackgroundSpendPolicy.shouldRunBlindSpot(
            totalCharacters: 4_010,
            charactersAtLastRun: 4_000,
            tier: .ultra,
            goalChanged: false))
        #expect(BackgroundSpendPolicy.shouldRunBlindSpot(
            totalCharacters: 4_010,
            charactersAtLastRun: 4_000,
            tier: .ultra,
            goalChanged: true))
    }

    @Test("provider latency is subtracted from start-to-start cadence")
    func providerLatencyDoesNotStretchCadence() {
        #expect(BackgroundSpendPolicy.blindSpotWaitSeconds(
            cadence: 90, lastAttemptUptime: nil, nowUptime: 1_000) == 90)
        #expect(BackgroundSpendPolicy.blindSpotWaitSeconds(
            cadence: 90, lastAttemptUptime: 1_000, nowUptime: 1_020) == 70)
        #expect(BackgroundSpendPolicy.blindSpotWaitSeconds(
            cadence: 90, lastAttemptUptime: 1_000, nowUptime: 1_095) == 0)
    }

    @Test("elapsed Blind Spot cadence yields while no new material is eligible")
    @MainActor
    func ineligibleBlindSpotPollIsCooperative() async {
        #expect(BackgroundSpendPolicy.blindSpotIneligiblePollNanoseconds > 0)
        #expect(BackgroundSpendPolicy.blindSpotIneligiblePollNanoseconds <= 1_000_000_000)

        let probe = BlindSpotSuspensionProbe()
        let pause = Task { @MainActor in
            probe.markStarted()
            // Thirty seconds, cancelled the moment the proof lands. The window
            // only has to outlast the gap between the task starting and this
            // test regaining the MainActor. It is deliberately far longer than
            // that gap could plausibly be: the window is a backstop, and the
            // proof itself no longer depends on beating a clock.
            await BackgroundSpendPolicy.pauseBeforeBlindSpotReevaluation(
                nanoseconds: 30_000_000_000)
            probe.markFinished()
        }
        await probe.waitUntilStarted()

        #expect(probe.hasStarted)
        // Reaching this MainActor line before the pause finishes is the
        // behavioral regression proof. A synchronous sleep reaches it only
        // after two bounded seconds and fails, without hanging the suite.
        #expect(!probe.hasFinished)
        pause.cancel()
        await pause.value
        #expect(probe.hasFinished)
    }

    // MARK: Rotation

    @Test("exactly one watch fires per period")
    func oneWatchPerPeriod() {
        // The bug this replaced: a shared counter incremented once per WATCH, so
        // every watch bumped it before testing its own name and all three matched.
        for period in 1...9 {
            let chosen = BackgroundSpendPolicy.rotatedWatches
                .filter { BackgroundSpendPolicy.watch(forTick: period) == $0 }
            #expect(chosen.count == 1, "period \(period) selected \(chosen.count) watches")
        }
    }

    @Test("the rotation covers every watch and repeats")
    func rotationIsFair() {
        let sequence = (1...6).map { BackgroundSpendPolicy.watch(forTick: $0) }
        #expect(Set(sequence) == Set(BackgroundSpendPolicy.rotatedWatches))
        #expect(Array(sequence.prefix(3)) == Array(sequence.suffix(3)))
    }

    @Test("a zero or negative period does not crash or skip everything")
    func rotationHandlesEdges() {
        #expect(BackgroundSpendPolicy.rotatedWatches.contains(BackgroundSpendPolicy.watch(forTick: 0)))
        #expect(BackgroundSpendPolicy.rotatedWatches.contains(BackgroundSpendPolicy.watch(forTick: -5)))
    }

    // MARK: Blind-spot backoff

    @Test("a productive scan keeps the base cadence")
    func productiveKeepsBase() {
        #expect(BackgroundSpendPolicy.blindSpotInterval(consecutiveEmptyScans: 0)
                == BackgroundSpendPolicy.baseBlindSpotSeconds)
    }

    @Test("consecutive empty scans back off, and the cap holds")
    func emptyScansBackOff() {
        let one = BackgroundSpendPolicy.blindSpotInterval(consecutiveEmptyScans: 1)
        let two = BackgroundSpendPolicy.blindSpotInterval(consecutiveEmptyScans: 2)
        let many = BackgroundSpendPolicy.blindSpotInterval(consecutiveEmptyScans: 50)
        #expect(one == BackgroundSpendPolicy.baseBlindSpotSeconds)
        #expect(two > one)
        #expect(many == BackgroundSpendPolicy.maxBlindSpotSeconds)
        // Never below the base — backing off must not accidentally speed it up.
        for n in 0...10 {
            #expect(BackgroundSpendPolicy.blindSpotInterval(consecutiveEmptyScans: n)
                    >= BackgroundSpendPolicy.baseBlindSpotSeconds)
        }
    }

    @Test("the backoff meaningfully cuts the hourly tick count")
    func backoffCutsSpend() {
        // The whole point is arithmetic, so assert the arithmetic.
        let base = Double(BackgroundSpendPolicy.baseBlindSpotSeconds)
        let capped = Double(BackgroundSpendPolicy.maxBlindSpotSeconds)
        let ticksAtBase = 3600 / base
        let ticksAtCap = 3600 / capped
        #expect(ticksAtBase == 40)
        #expect(ticksAtCap <= 15)
    }

    @Test("paid backoff caps recover faster by tier without exceeding base cadence")
    func tieredBackoffCaps() {
        let caps = [Tier.pro, .premium, .ultra]
            .map(BackgroundSpendPolicy.blindSpotBackoffCap(for:))
        #expect(caps == [180, 150, 120])
        #expect(caps.allSatisfy { $0 >= BackgroundSpendPolicy.baseBlindSpotSeconds })
    }

    @Test("a new call clears transcript-relative spend memory")
    func perCallSpendStateResets() {
        var state = BackgroundSpendSessionState(
            charactersAtLastRun: ["brainstorm": 5_000, "agenda": 4_000],
            consecutiveEmptyBlindSpotScans: 8,
            paidProbeTick: 6,
            lastBlindSpotAttemptUptime: 42)
        #expect(!BackgroundSpendPolicy.shouldRun(
            totalCharacters: 300,
            charactersAtLastRun: state.charactersAtLastRun["brainstorm"],
            minimumNew: 90))

        state.reset()

        #expect(state.charactersAtLastRun.isEmpty)
        #expect(state.consecutiveEmptyBlindSpotScans == 0)
        #expect(state.paidProbeTick == 0)
        #expect(state.lastBlindSpotAttemptUptime == nil)
        #expect(BackgroundSpendPolicy.shouldRun(
            totalCharacters: 300,
            charactersAtLastRun: state.charactersAtLastRun["brainstorm"],
            minimumNew: 90))
    }
}
