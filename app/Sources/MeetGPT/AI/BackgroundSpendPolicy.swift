import Foundation

/// When a background watch is worth paying for.
///
/// Measured against the tariff, one hour of Pro conversation spent 204 compute
/// credits against a 250-credit MONTHLY allowance — so a Pro plan ran dry after
/// about 74 minutes of calls. Three things made that worse than it needed to be,
/// and this type addresses two of them:
///
///  1. The coalescing signature was `transcript.count`. Any single new line
///     unblocked a full-price tick, so a tick after one sentence cost exactly what
///     a tick after fifty did.
///  2. All three 300-second watches (agenda, rhetoric, facilitation) fired on the
///     same tick, three separate calls over the same recent transcript.
///
/// Pure and injectable so the arithmetic is testable without a live call.
enum BackgroundSpendPolicy {
    /// New recognised characters required before a watch is worth re-running.
    ///
    /// Roughly a couple of sentences. Below this the model is being asked to
    /// re-read what it already read, and it reliably returns what it already said.
    static let minimumNewCharacters = 280

    /// Blind spots run more often than the other watches and cost the most, so
    /// they get a lower bar — but not zero, which is what `transcript.count` was.
    static let minimumNewCharactersForBlindSpots = 180

    /// Paid plans provision a bounded Blind Spot wake throughout their active
    /// co-pilot allowance. Higher tiers can use more of that already-funded
    /// ceiling when transcription arrives in smaller chunks; the cadence gate
    /// still prevents this from increasing the tariffed calls per hour.
    static func blindSpotMinimumNewCharacters(for tier: Tier) -> Int {
        switch tier {
        case .free: return minimumNewCharactersForBlindSpots
        case .pro: return 150
        case .premium: return 120
        case .ultra: return 90
        }
    }

    /// Should a watch spend a call, given how much NEW material exists?
    ///
    /// `charactersAtLastRun` is the transcript length when this watch last ran.
    /// The first run of a call always proceeds — there is no prior baseline, and
    /// waiting would leave the panel silent through the opening minutes.
    static func shouldRun(totalCharacters: Int,
                          charactersAtLastRun: Int?,
                          minimumNew: Int = minimumNewCharacters) -> Bool {
        guard let last = charactersAtLastRun else { return true }
        return totalCharacters - last >= minimumNew
    }

    static func shouldRunBlindSpot(totalCharacters: Int,
                                   charactersAtLastRun: Int?,
                                   tier: Tier,
                                   goalChanged: Bool) -> Bool {
        goalChanged || shouldRun(
            totalCharacters: totalCharacters,
            charactersAtLastRun: charactersAtLastRun,
            minimumNew: blindSpotMinimumNewCharacters(for: tier))
    }

    /// Remaining start-to-start delay. Request latency is subtracted rather
    /// than added to the cadence, while a Settings restart cannot reset the
    /// clock and manufacture an extra scan.
    static func blindSpotWaitSeconds(cadence: UInt64,
                                     lastAttemptUptime: TimeInterval?,
                                     nowUptime: TimeInterval) -> UInt64 {
        guard let lastAttemptUptime else { return cadence }
        return UInt64(ceil(max(0, Double(cadence) - (nowUptime - lastAttemptUptime))))
    }

    // MARK: - Rotation

    /// The 300-second watches, rotated so ONE fires per tick instead of all three.
    ///
    /// They are ambient background notes, not findings the user is waiting on, and
    /// three of them per five minutes was 72 credits an hour on Pro — a third of
    /// the entire burn. Rotating gives each a 15-minute effective cadence for a
    /// third of the cost, which is the right trade for an ambient nudge.
    static let rotatedWatches = ["agenda", "rhetoric", "facilitation"]

    /// Which watch this tick belongs to. `tick` is 1-based.
    static func watch(forTick tick: Int) -> String {
        let count = rotatedWatches.count
        guard count > 0 else { return "agenda" }
        let index = ((tick - 1) % count + count) % count
        return rotatedWatches[index]
    }

    // MARK: - Blind-spot backoff

    /// Blind spots cost the most and are now judged server-side, so a stretch of
    /// conversation that yields nothing the judge keeps is a stretch we are paying
    /// full price to discard. Back off after consecutive empty scans, and snap back
    /// the moment one lands.
    static let baseBlindSpotSeconds: UInt64 = 90
    static let maxBlindSpotSeconds: UInt64 = 240
    /// Once a start-to-start cadence has elapsed, the scheduler still has to
    /// wait for enough new speech, a goal, quota, or background-queue room.
    /// A positive cooperative poll prevents those no-work states from becoming
    /// a MainActor busy loop while keeping new material responsive.
    static let blindSpotIneligiblePollNanoseconds: UInt64 = 500_000_000

    /// Cooperatively suspend the actor that owns the ambient scheduler. Keep
    /// the sleep beside its policy duration so a future cadence refactor cannot
    /// accidentally replace it with a synchronous delay and freeze the UI.
    /// The override is an internal test seam; production always uses the
    /// bounded half-second policy value above.
    static func pauseBeforeBlindSpotReevaluation(
        nanoseconds: UInt64 = blindSpotIneligiblePollNanoseconds
    ) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Empty-result backoff remains above the budget-derived base cadence, so
    /// these caps can only spend within (never above) the funded hourly ceiling.
    /// Higher tiers recover sooner from a quiet stretch because responsiveness
    /// is part of the deeper co-pilot they fund.
    static func blindSpotBackoffCap(for tier: Tier) -> UInt64 {
        switch tier {
        case .free: return maxBlindSpotSeconds
        case .pro: return 180
        case .premium: return 150
        case .ultra: return 120
        }
    }

    /// Doubling per empty scan, capped. Two empty scans in a row is a quiet patch;
    /// backing off is the correct response, and a real blind spot resets it.
    static func blindSpotInterval(consecutiveEmptyScans: Int,
                                  base: UInt64 = baseBlindSpotSeconds,
                                  cap: UInt64 = maxBlindSpotSeconds) -> UInt64 {
        guard consecutiveEmptyScans > 0 else { return base }
        // Shift rather than pow: exact, and cannot overflow before the cap bites.
        let doublings = min(consecutiveEmptyScans, 4)
        let scaled = base << UInt64(doublings - 1)
        return min(scaled, cap)
    }
}

/// Spend memory belongs to one transcript. Carrying the previous call's length
/// into a new call makes every new-material delta negative and can suppress
/// Blind Spot until the new meeting grows longer than the old one.
struct BackgroundSpendSessionState: Equatable {
    var charactersAtLastRun: [String: Int] = [:]
    var consecutiveEmptyBlindSpotScans = 0
    var paidProbeTick = 0
    var lastBlindSpotAttemptUptime: TimeInterval?

    mutating func reset() {
        charactersAtLastRun.removeAll(keepingCapacity: true)
        consecutiveEmptyBlindSpotScans = 0
        paidProbeTick = 0
        lastBlindSpotAttemptUptime = nil
    }
}
