import Foundation
import MCP

/// One piece of background pulled from a connected work app during research.
struct GroundingSnippet: Identifiable, Sendable {
    let id = UUID()
    /// Stable workflow source id (`mcp:notion`, `team:slack`, …). This lets the
    /// activity ledger update the correct preplanned row even when display names
    /// collide. It is never sent to the model.
    let sourceID: String?
    let serverName: String
    let toolName: String
    let text: String
    /// What this source is evidence OF, from `ConnectorProbeStrategy`. Without it
    /// a HubSpot result reads as "some notes about a customer"; with it, as "the
    /// objections this buyer raised last time, which nobody has mentioned today".
    /// The difference decides whether the model uses the snippet or skims past it.
    let readFor: String?
    /// How old this material is, when it was served from cache after the live
    /// call failed. nil for a fresh read.
    ///
    /// It reaches the prompt. A connected app being unreachable is a fact about
    /// the answer, and a half-hour-old CRM note offered as current is worse than
    /// no note at all — the model would reconcile the transcript against stale
    /// state and report the difference as a contradiction in the call.
    let staleAge: TimeInterval?

    init(serverName: String, toolName: String, text: String,
         sourceID: String? = nil, readFor: String? = nil, staleAge: TimeInterval? = nil) {
        self.sourceID = sourceID
        self.serverName = serverName
        self.toolName = toolName
        self.text = text
        self.readFor = readFor
        self.staleAge = staleAge
    }
}

/// Goal-driven research across connected apps: the only input is the call's
/// target. Each connected server is asked through its own search-ish tool
/// (Notion search, Fireflies keyword search, Linear/Jira issue search, …),
/// in parallel; per-server failures are skipped, never fatal.
extension MCPConnectionManager {
    /// Servers worth querying: live session or silently reconnectable, MINUS the
    /// ones the user has muted.
    ///
    /// The filter belongs here rather than at each call site because this is the
    /// single choke point every consumer of connected-app data already goes
    /// through — grounding, workflow routing, the answer-action planner, task
    /// writeback. Filtering once means a new consumer inherits the mute instead
    /// of having to remember it, and "muted" cannot come to mean different
    /// things in different places.
    var researchableServers: [MCPServerDescriptor] {
        let muted = Config.mutedConnectedApps
        return researchableServersIncludingMuted
            .filter { !muted.contains(Config.mutedAppID(mcpServer: $0.id)) }
    }

    /// Every server that COULD be queried, mute included. Distinct from
    /// `connectedServers`, which is only the ones with a live session THIS
    /// launch — a silently reconnectable server is still usable.
    ///
    /// Display uses this: an app that vanished from the strip when muted would
    /// leave no way to unmute it.
    var researchableServersIncludingMuted: [MCPServerDescriptor] {
        servers.filter { prefersMCP($0.id) }
    }

    /// The read-only search capability discovered during the verified MCP
    /// connection. Workflow design uses its name/description to route custom
    /// servers and user-created prompts without ever selecting write tools.
    func researchTool(for serverID: String) -> Tool? {
        let available = tools(for: serverID)
        for name in Self.searchToolPreferences[serverID] ?? [] {
            if let tool = available.first(where: {
                $0.name == name && MCPImportToolPolicy.isSafeForImport($0)
            }) { return tool }
        }
        return available.first { tool in
            guard MCPImportToolPolicy.isSafeForImport(tool) else { return false }
            return tool.stringArgumentKey(
                preferring: ["query", "keyword", "q", "search", "term", "text"]) != nil
        }
    }

    func researchCapabilityText(for serverID: String) -> [String] {
        guard let tool = researchTool(for: serverID) else { return [] }
        return [tool.name, tool.description ?? ""]
    }

    /// Ask connected apps — MCP servers AND token connectors (Slack,
    /// Confluence) — for material related to the goal.
    /// - Parameters:
    ///   - limitTo: restrict to these catalog server ids (nil = all connected).
    ///     Per-button workflows pass their relevant subset so, e.g., a Tasks run
    ///     queries trackers but not Sentry.
    ///   - includeTeam: whether the token connectors are queried too.
    func groundingSnippets(goal: String,
                           limitTo: Set<String>? = nil,
                           includeTeam: Bool = true,
                           maxCharsPerSource: Int = 4000,
                           maxSources: Int? = nil) async -> [GroundingSnippet] {
        let allTargets = researchableServers.filter { limitTo?.contains($0.id) ?? true }
        let allTeamServices = includeTeam ? TeamConnectors.configured : []
        let mcpCandidates = allTargets.map { server -> GroundingContextPolicy.SourceCandidate in
            let probe = ConnectorProbeStrategy.probe(forServerID: server.id)
            return GroundingContextPolicy.SourceCandidate(
                id: "mcp:\(server.id)",
                searchableText: ([server.id, server.name] + server.keywords
                    + [probe?.queryHint ?? "", probe?.readFor ?? ""])
                    .joined(separator: " "),
                strongFor: probe?.strongFor ?? [])
        }
        let teamCandidates = allTeamServices.map { service -> GroundingContextPolicy.SourceCandidate in
            let probe = ConnectorProbeStrategy.probe(forTeamService: service.rawValue)
            return GroundingContextPolicy.SourceCandidate(
                id: "team:\(service.rawValue)",
                searchableText: [service.rawValue, service.label,
                                 probe?.queryHint ?? "", probe?.readFor ?? ""]
                    .joined(separator: " "),
                strongFor: probe?.strongFor ?? [])
        }
        let selected = GroundingContextPolicy.selectSources(
            mcpCandidates + teamCandidates,
            query: goal,
            tier: Config.currentTier,
            requestedLimit: maxSources)
        // Selection happens before task creation: a one-source Blind Spot run
        // creates one connector request, rather than fetching everything and
        // discarding all but the first response afterward.
        let targets: [MCPServerDescriptor] = selected.compactMap {
            candidate -> MCPServerDescriptor? in
            guard candidate.id.hasPrefix("mcp:") else { return nil }
            let id = String(candidate.id.dropFirst("mcp:".count))
            return allTargets.first { $0.id == id }
        }
        let teamServices: [TeamService] = selected.compactMap {
            candidate -> TeamService? in
            guard candidate.id.hasPrefix("team:") else { return nil }
            let id = String(candidate.id.dropFirst("team:".count))
            return allTeamServices.first { $0.rawValue == id }
        }
        guard !targets.isEmpty || !teamServices.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, GroundingSnippet?).self) { group in
            for (index, server) in targets.enumerated() {
                group.addTask { @MainActor in
                    (index, await self.researchOne(
                        server: server, goal: goal, cap: maxCharsPerSource))
                }
            }
            for (offset, service) in teamServices.enumerated() {
                let index = targets.count + offset
                group.addTask {
                    let query = ConnectorProbeStrategy.query(goal: goal, serverID: service.rawValue)
                    guard let text = await TeamConnectors.search(service, query: query, cap: maxCharsPerSource),
                          !text.isEmpty else { return (index, nil) }
                    return (index, GroundingSnippet(
                        serverName: service.label, toolName: "search", text: text,
                        sourceID: "team:\(service.rawValue)",
                        readFor: ConnectorProbeStrategy.probe(
                            forTeamService: service.rawValue)?.readFor))
                }
            }
            var snippets: [(Int, GroundingSnippet)] = []
            for await (index, snippet) in group {
                if let snippet { snippets.append((index, snippet)) }
            }
            return snippets.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Per-server research

    /// Known-good search tools per catalog server; anything else falls back to
    /// the first tool whose name contains "search".
    private static let searchToolPreferences: [String: [String]] = [
        "notion": ["notion-search"],
        "fireflies": ["fireflies_get_transcripts", "fireflies_search"],
        // Not optional for Gmail. `list_drafts` also exposes a `query`
        // argument and is listed BEFORE `search_threads`, so the generic
        // readable-tool fallback picks it and researches the user's own
        // unsent drafts instead of their mail.
        "gmail": ["search_threads"],
        // GA4 exposes get_metadata and check_compatibility, which describe the
        // property rather than report on it — the readable-tool heuristic would
        // happily pick one and return a schema instead of a number.
        "google-analytics": ["run_report", "run_realtime_report"],
    ]

    private func researchOne(server: MCPServerDescriptor, goal: String, cap: Int) async -> GroundingSnippet? {
        guard let tool = await findSearchTool(server: server) else { return nil }

        // Capture provenance after connection. Disconnect, reconnect, or a
        // Cruxwing account transition advances this synchronously. Every await
        // below revalidates it so an old-account hit/network response cannot be
        // returned or stored after the boundary changes underneath the task.
        let cacheScope = groundingCacheScope

        // The goal rides in whichever string property the schema declares — but
        // biased per connector. Sending the raw goal to every server asked a bug
        // tracker and a CRM the same question and got a generic answer from both.
        guard let key = tool.stringArgumentKey(
            preferring: ["query", "keyword", "q", "search", "term", "text"]) else { return nil }
        let query = ConnectorProbeStrategy.query(goal: goal, serverID: server.id)
        var arguments: [String: Value] = [key: .string(query)]
        // Schema-driven extras (verified live on Fireflies): cap results, search
        // titles+content, and prefer the compact JSON shape.
        if tool.hasArgument("limit") { arguments["limit"] = .int(3) }
        if tool.hasArgument("scope") { arguments["scope"] = .string("all") }
        if tool.hasArgument("format") { arguments["format"] = .string("json") }

        let sourceID = "mcp:\(server.id)"
        let breakerID = "\(cacheScope)|\(server.id)"
        let cacheKey = MCPResultCache.key(
            sourceID: sourceID, tool: tool.name, query: query, scope: cacheScope)
        let telemetryRequestID = makeConnectorTelemetryRequestID()
        let retryCount = await groundingCache.consecutiveFailures(serverID: breakerID)
        let callArguments = arguments
        let readFor = ConnectorProbeStrategy.probe(forServerID: server.id)?.readFor

        func snippet(_ text: String, staleAge: TimeInterval?) -> GroundingSnippet {
            GroundingSnippet(serverName: server.name, toolName: tool.name,
                             text: String(text.prefix(cap)), sourceID: sourceID,
                             readFor: readFor, staleAge: staleAge)
        }

        // Still fresh: the same goal is re-queried every tick of a five-minute
        // loop, and a tracker does not change between two of them.
        if let hit = await groundingCache.fresh(cacheKey) {
            guard cacheScope == groundingCacheScope else { return nil }
            recordConnectorCacheTelemetry(
                server: server,
                toolName: tool.name,
                requestID: telemetryRequestID,
                result: .freshHit,
                age: hit.age,
                retryCount: retryCount)
            return snippet(hit.text, staleAge: nil)
        }

        // This server has been failing; do not dial it again yet. Its last good
        // answer still counts, labelled.
        if await groundingCache.isOpen(serverID: breakerID) {
            let stale = await groundingCache.stale(cacheKey)
            guard cacheScope == groundingCacheScope else { return nil }
            recordConnectorCacheTelemetry(
                server: server,
                toolName: tool.name,
                requestID: telemetryRequestID,
                result: .circuitOpen,
                age: stale?.age,
                retryCount: retryCount,
                status: .offline)
            return stale.map { snippet($0.text, staleAge: $0.age) }
        }

        // A deadline, so one wedged app costs one source instead of the run.
        let text = await withMCPDeadline(seconds: Self.groundingDeadline) { [weak self] in
            try await self?.callToolText(
                server: server,
                tool: tool.name,
                arguments: callArguments,
                telemetryContext: ConnectorTelemetryContext(
                    requestID: telemetryRequestID,
                    cacheResult: .miss,
                    retryCount: retryCount))
        } ?? nil

        guard cacheScope == groundingCacheScope else { return nil }

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await groundingCache.recordFailure(serverID: breakerID)
            let stale = await groundingCache.stale(cacheKey)
            guard cacheScope == groundingCacheScope else { return nil }
            if let stale {
                recordConnectorCacheTelemetry(
                    server: server,
                    toolName: tool.name,
                    requestID: telemetryRequestID,
                    result: .staleFallback,
                    age: stale.age,
                    retryCount: retryCount)
            }
            return stale.map { snippet($0.text, staleAge: $0.age) }
        }
        await groundingCache.store(cacheKey, text: text, serverID: breakerID)
        guard cacheScope == groundingCacheScope else { return nil }
        return snippet(text, staleAge: nil)
    }

    /// How long one connected app may hold up a grounding round. Chosen against
    /// the loop it blocks, not against the app: a blind-spot tick that arrives
    /// after the moment it described is worth less than a tick with one source
    /// missing.
    ///
    /// Stored rather than computed so tests can stop racing it. A test driving
    /// grounding through an instant in-process stub is not exercising this
    /// deadline at all — but on a saturated machine the eight seconds can still
    /// elapse before the stub is even scheduled, at which point the deadline
    /// fires, grounding correctly returns nothing, and the test reports a
    /// product failure that never happened. Production never assigns this.
    static var groundingDeadline: TimeInterval = 8

    private func findSearchTool(server: MCPServerDescriptor) async -> Tool? {
        if !isConnected(server.id) { await connect(server) }
        return researchTool(for: server.id)
    }
}
