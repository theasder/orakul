import Foundation

/// Keeps connected-app results usable when the app behind them is not.
///
/// Grounding fans out to every connected server on a task group and awaits all
/// of them with no deadline, so one slow or wedged connector held up the blind
/// spot tick or prompt run that was waiting on the group. And a connector that
/// is merely down for a minute took its evidence out of the answer entirely,
/// which the user reads as the co-pilot getting worse rather than as Notion
/// being unreachable.
///
/// Three behaviours, in the order they matter:
///
///  1. A DEADLINE, so a hung app costs one source and not the whole run.
///  2. STALE-ON-FAILURE — the last good answer is better than nothing, but only
///     if it is labelled: an eleven-minute-old CRM note presented as current is
///     worse than no note, so age travels with the snippet and reaches the
///     prompt.
///  3. A BREAKER, so a server that has failed repeatedly is skipped for a
///     while instead of being dialled — and re-dialled — every tick.
///
/// An actor: the fan-out is concurrent, and this is shared mutable state.
actor MCPResultCache {

    struct Entry: Equatable, Sendable {
        let text: String
        let storedAt: Date
    }

    struct Hit: Equatable, Sendable {
        let text: String
        /// How old the answer is. Zero for a fresh call; non-zero means it was
        /// served from cache and the prompt must say so.
        let age: TimeInterval
        /// True when it was served because the live call failed, rather than
        /// because it was still fresh.
        let isStale: Bool
    }

    /// Fresh enough to skip the call. Connected-app state moves in minutes, not
    /// seconds, and the same goal is re-queried every tick of a 5-minute loop.
    static let defaultTTL: TimeInterval = 5 * 60
    /// Past this, a cached answer is not worth showing even as a fallback — a
    /// tracker's state half an hour ago is a different meeting's evidence.
    static let defaultMaxStale: TimeInterval = 30 * 60
    /// Consecutive failures before a server is left alone.
    static let breakerThreshold = 3
    /// How long it is left alone. Long enough to outlast a rate-limit window,
    /// short enough that a recovered app rejoins the same meeting.
    static let breakerCooldown: TimeInterval = 5 * 60

    private var entries: [String: Entry] = [:]
    private var failures: [String: Int] = [:]
    private var openUntil: [String: Date] = [:]
    private let now: @Sendable () -> Date

    /// Injectable clock — TTL and breaker behaviour are the whole point of this
    /// type, and neither is testable against the wall clock.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Cache key. The query is part of it: two goals asking Notion different
    /// questions are different answers, and collapsing them would serve one
    /// call's evidence to another.
    nonisolated static func key(sourceID: String, tool: String, query: String,
                                scope: UInt64 = 0) -> String {
        "\(scope)|\(sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|" +
            "\(tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|" +
            GroundingContextPolicy.canonicalQuery(query)
    }

    // MARK: - Reads

    /// A still-fresh answer, or nil.
    func fresh(_ key: String, ttl: TimeInterval = defaultTTL) -> Hit? {
        guard let entry = entries[key] else { return nil }
        let age = now().timeIntervalSince(entry.storedAt)
        guard age <= ttl else { return nil }
        return Hit(text: entry.text, age: age, isStale: false)
    }

    /// The last good answer, however old, up to `maxStale`. Only for the path
    /// where the live call already failed.
    func stale(_ key: String, maxStale: TimeInterval = defaultMaxStale) -> Hit? {
        guard let entry = entries[key] else { return nil }
        let age = now().timeIntervalSince(entry.storedAt)
        guard age <= maxStale else { return nil }
        return Hit(text: entry.text, age: age, isStale: true)
    }

    // MARK: - Writes

    func store(_ key: String, text: String, serverID: String) {
        entries[key] = Entry(text: text, storedAt: now())
        // A success is what closes the breaker. Decaying instead of resetting
        // would keep a recovered server one failure away from being cut off.
        failures[serverID] = 0
        openUntil[serverID] = nil
    }

    func recordFailure(serverID: String) {
        let count = (failures[serverID] ?? 0) + 1
        failures[serverID] = count
        if count >= Self.breakerThreshold {
            openUntil[serverID] = now().addingTimeInterval(Self.breakerCooldown)
        }
    }

    /// Whether this server should be skipped entirely this round.
    func isOpen(serverID: String) -> Bool {
        guard let until = openUntil[serverID] else { return false }
        if now() >= until {
            // Cooldown elapsed: let exactly one call through to find out whether
            // it recovered, rather than waiting for a signal that can only come
            // from a call.
            openUntil[serverID] = nil
            failures[serverID] = Self.breakerThreshold - 1
            return false
        }
        return true
    }

    func consecutiveFailures(serverID: String) -> Int { failures[serverID] ?? 0 }

    /// Drop everything. Used when connections change underneath the cache —
    /// a reconnect or a disconnect makes prior answers unattributable.
    func clear() {
        entries.removeAll()
        failures.removeAll()
        openUntil.removeAll()
    }
}

/// Runs `work`, giving up after `seconds`.
///
/// The MCP client has no deadline of its own, so without this a connector that
/// accepts the connection and never answers blocks its task-group slot until
/// the process dies. Returns nil on timeout; the caller decides whether that
/// means "use stale" or "skip this source".
func withMCPDeadline<T: Sendable>(seconds: TimeInterval,
                                  _ work: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
