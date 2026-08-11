import Foundation

/// Cost-control gate for the background LLM "watch" loops (brainstorm, agenda,
/// fact-check, rhetoric, facilitation). Every loop wakes on its own timer, but
/// they share ONE of these so the app never spends more than it must:
///
/// - **Coalesce / skip-unchanged**: a loop only runs when its input *signature*
///   (the live transcript entry count) changed since its last accepted run. An
///   unchanged transcript would produce the same answer — so it's skipped, not
///   re-billed.
/// - **Single-flight**: at most one run per key is in flight; a second wake for
///   a key whose previous run hasn't finished is dropped.
/// - **Backpressure**: at most `maxConcurrent` background runs happen at once
///   across *all* loops, so aligned timers can't stack a burst of paid calls.
///
/// Deliberately a gate, not a runner: the caller keeps executing its own work on
/// its own actor (AppState is `@MainActor`); only the arbitration crosses here.
/// A `true` from `reserve(key:signature:)` obliges the caller to call
/// `finish(key:)` once, when its run completes.
actor BackgroundLLMQueue {
    private var lastSignature: [String: Int] = [:]
    private var inFlight: Set<String> = []
    private var activeCount = 0
    private let maxConcurrent: Int

    /// - Parameter maxConcurrent: cap on simultaneous background runs across all
    ///   keys. Two lets a slow call overlap a fast one without letting all five
    ///   loops fire at once.
    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Try to claim a run slot for `key` at input `signature`. Returns `true`
    /// only when the input changed since the last accepted run for `key`, no run
    /// for `key` is already in flight, and we're under the concurrency cap. On
    /// `true` the caller MUST later call `finish(key:)` exactly once. On `false`
    /// the caller skips this cycle and retries on its next tick.
    func reserve(key: String, signature: Int) -> Bool {
        guard lastSignature[key] != signature else { return false }  // coalesce
        guard !inFlight.contains(key) else { return false }          // single-flight
        guard activeCount < maxConcurrent else { return false }      // backpressure
        lastSignature[key] = signature
        inFlight.insert(key)
        activeCount += 1
        return true
    }

    /// Release the slot claimed by a `true` `reserve`. Idempotent: a duplicate or
    /// unmatched call is a no-op, so it can't drive `activeCount` negative.
    func finish(key: String) {
        if inFlight.remove(key) != nil {
            activeCount -= 1
        }
    }

    /// Forget all coalesce signatures and in-flight state — call when a new
    /// meeting starts so its first cycles run fresh and no leaked slot lingers.
    func reset() {
        lastSignature.removeAll()
        inFlight.removeAll()
        activeCount = 0
    }
}
