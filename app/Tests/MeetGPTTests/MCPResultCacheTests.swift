import Foundation
import Testing
@testable import MeetGPT

/// Connected apps go down, rate-limit, and hang. The cache decides what the
/// co-pilot does about it, so its behaviour is pinned against a clock we
/// control rather than the wall clock.
@Suite("MCP result cache")
struct MCPResultCacheTests {

    /// A movable clock. TTL and breaker cooldown are the whole point of the
    /// type and neither is testable by waiting.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_800_000_000)
        var read: @Sendable () -> Date { { self.lock.lock(); defer { self.lock.unlock() }; return self.now } }
        func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
    }

    private func key() -> String {
        MCPResultCache.key(sourceID: "mcp:notion", tool: "notion-search", query: "July pricing")
    }

    // MARK: - Freshness

    @Test("a fresh answer is served without calling the app again")
    func freshHitSkipsTheCall() async {
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)
        await cache.store(key(), text: "Pricing page v4", serverID: "notion")

        clock.advance(60)
        let hit = await cache.fresh(key())

        #expect(hit?.text == "Pricing page v4")
        #expect(hit?.isStale == false)
        #expect(hit?.age == 60)
    }

    @Test("past the TTL it is not fresh — the app gets asked again")
    func staleEntriesAreNotFresh() async {
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)
        await cache.store(key(), text: "Pricing page v4", serverID: "notion")

        clock.advance(MCPResultCache.defaultTTL + 1)

        #expect(await cache.fresh(key()) == nil)
    }

    @Test("the query is part of the key — two goals are two answers")
    func queriesDoNotCollide() async {
        // Collapsing them would serve one call's evidence to another meeting.
        let cache = MCPResultCache()
        let pricing = MCPResultCache.key(sourceID: "mcp:notion", tool: "search", query: "July pricing")
        let hiring = MCPResultCache.key(sourceID: "mcp:notion", tool: "search", query: "hiring plan")
        await cache.store(pricing, text: "prices", serverID: "notion")

        #expect(await cache.fresh(pricing) != nil)
        #expect(await cache.fresh(hiring) == nil)
    }

    @Test("the key ignores case and surrounding whitespace")
    func keyIsNormalized() {
        #expect(MCPResultCache.key(sourceID: "mcp:notion", tool: "search", query: " July Pricing ")
                == MCPResultCache.key(sourceID: "mcp:notion", tool: "search", query: "july pricing"))
    }

    @Test("the key reuses harmless whitespace and terminal-punctuation variants")
    func canonicalQueryVariantsShareCache() async {
        let cache = MCPResultCache()
        let first = MCPResultCache.key(
            sourceID: "MCP:Notion", tool: " SEARCH ", query: "July   pricing?")
        let variant = MCPResultCache.key(
            sourceID: "mcp:notion", tool: "search", query: " july pricing ")
        await cache.store(first, text: "Pricing page v4", serverID: "notion")

        #expect(first == variant)
        #expect(await cache.fresh(variant)?.text == "Pricing page v4")
    }

    // MARK: - Stale-on-failure

    @Test("when the app is unreachable the last good answer is offered, labelled")
    func staleServedOnFailure() async {
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)
        await cache.store(key(), text: "Pricing page v4", serverID: "notion")

        clock.advance(11 * 60)   // past TTL, inside the stale window
        let hit = await cache.stale(key())

        #expect(hit?.text == "Pricing page v4")
        #expect(hit?.isStale == true)
        #expect(hit?.age == 660)
    }

    @Test("beyond the stale window nothing is offered at all")
    func veryOldEntriesAreDropped() async {
        // A tracker's state half an hour ago is a different meeting's evidence.
        // Silence is the honest answer.
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)
        await cache.store(key(), text: "Pricing page v4", serverID: "notion")

        clock.advance(MCPResultCache.defaultMaxStale + 60)

        #expect(await cache.stale(key()) == nil)
    }

    // MARK: - Breaker

    @Test("a server that keeps failing is left alone for a cooldown")
    func breakerOpensAfterRepeatedFailures() async {
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)

        for _ in 0..<(MCPResultCache.breakerThreshold - 1) {
            await cache.recordFailure(serverID: "asana")
        }
        #expect(await cache.isOpen(serverID: "asana") == false)

        await cache.recordFailure(serverID: "asana")
        #expect(await cache.isOpen(serverID: "asana"))
    }

    @Test("after the cooldown exactly one call is let through to test recovery")
    func breakerHalfOpensAfterCooldown() async {
        // Recovery can only be observed by calling, so the breaker has to open
        // the door once rather than wait for a signal that cannot arrive.
        let clock = Clock()
        let cache = MCPResultCache(now: clock.read)
        for _ in 0..<MCPResultCache.breakerThreshold { await cache.recordFailure(serverID: "asana") }

        clock.advance(MCPResultCache.breakerCooldown + 1)
        #expect(await cache.isOpen(serverID: "asana") == false)

        // Still one failure short of tripping again, so a single relapse
        // reopens it immediately rather than granting three more attempts.
        await cache.recordFailure(serverID: "asana")
        #expect(await cache.isOpen(serverID: "asana"))
    }

    @Test("a success closes the breaker outright")
    func successResetsTheBreaker() async {
        let cache = MCPResultCache()
        for _ in 0..<MCPResultCache.breakerThreshold { await cache.recordFailure(serverID: "asana") }
        #expect(await cache.isOpen(serverID: "asana"))

        await cache.store(key(), text: "back", serverID: "asana")

        #expect(await cache.isOpen(serverID: "asana") == false)
        #expect(await cache.consecutiveFailures(serverID: "asana") == 0)
    }

    @Test("clearing drops entries and breaker state together")
    func clearResetsEverything() async {
        let cache = MCPResultCache()
        await cache.store(key(), text: "x", serverID: "notion")
        await cache.recordFailure(serverID: "asana")

        await cache.clear()

        #expect(await cache.fresh(key()) == nil)
        #expect(await cache.consecutiveFailures(serverID: "asana") == 0)
    }

    // MARK: - Deadline

    @Test("a hung app costs one source, not the whole grounding round")
    func deadlineReturnsNil() async {
        let result: String? = await withMCPDeadline(seconds: 0.2) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }

        #expect(result == nil)
    }

    @Test("a fast app is not penalised by the deadline")
    func deadlineLetsFastCallsThrough() async {
        let result: String? = await withMCPDeadline(seconds: 5) { "Pricing page v4" }

        #expect(result == "Pricing page v4")
    }

    // MARK: - What the model is told

    @Test("a cached source announces its age in the prompt")
    func stalenessReachesThePrompt() {
        // The failure this prevents: the model reconciles the transcript
        // against half-hour-old tracker state and reports the difference as a
        // contradiction in the call.
        let fresh = GroundingSnippet(serverName: "Notion", toolName: "search",
                                     text: "Pricing v4", sourceID: "mcp:notion", readFor: "prior terms")
        let cached = GroundingSnippet(serverName: "Asana", toolName: "search",
                                      text: "Task open", sourceID: "mcp:asana",
                                      readFor: "open work", staleAge: 11 * 60)

        let rendered = PromptWorkflows.renderGrounding([fresh, cached])

        #expect(rendered.contains("[Notion · read for: prior terms]"))
        #expect(rendered.contains("CACHED 11 minutes ago, app unreachable"))
        #expect(!rendered.contains("[Notion · read for: prior terms · CACHED"))
    }

    @Test("a just-cached source never reads as zero minutes old")
    func minutesLabelFloorsAtOne() {
        #expect(PromptWorkflows.minutesLabel(20) == "1 minute")
        #expect(PromptWorkflows.minutesLabel(120) == "2 minutes")
    }
}
