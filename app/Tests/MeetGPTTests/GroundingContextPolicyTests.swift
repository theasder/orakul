import Foundation
import MCP
import Testing
@testable import MeetGPT

@Suite("Grounding context economy")
struct GroundingContextPolicyTests {
    @Test("tariff budgets are bounded and increase only with funded tiers")
    func tariffBudgets() {
        #expect([Tier.free, .pro, .premium, .ultra].map {
            GroundingContextPolicy.defaultRetrievalSourceLimit(for: $0)
        } == [2, 2, 3, 4])
        #expect([Tier.free, .pro, .premium, .ultra].map {
            GroundingContextPolicy.attachmentCharacterLimit(for: $0)
        } == [2_000, 3_200, 4_500, 6_000])
        for tier in Tier.allCases {
            let estimatedTokens = TokenEstimate.tokens(
                GroundingContextPolicy.attachmentCharacterLimit(for: tier))
            #expect(estimatedTokens < TokenEstimate.baseCreditInputTokens)
        }
    }

    @Test("one default cap is shared by ledger, connectors, and Google")
    func oneCrossLayerSourceBudget() {
        let freeCap = GroundingContextPolicy.defaultRetrievalSourceLimit(for: .free)
        let afterLedger = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: freeCap, ledgerResults: 1, connectorResults: 0)
        #expect(afterLedger.ledger == 1)
        #expect(afterLedger.connectors == 1)
        #expect(afterLedger.google == 1)

        let afterConnector = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: freeCap, ledgerResults: 1, connectorResults: 1)
        #expect(afterConnector.google == 0)
        #expect(afterConnector.ledger + 1 + afterConnector.google == freeCap)

        // An empty connector search gives its unused slot to Google; it does
        // not make the total larger.
        let emptyConnector = GroundingContextPolicy.sourceSlotPlan(
            totalLimit: freeCap, ledgerResults: 1, connectorResults: 0)
        #expect(emptyConnector.google == 1)
    }

    @Test("source relevance is decided before fan-out")
    func sourceSelection() {
        let candidates = [
            GroundingContextPolicy.SourceCandidate(
                id: "mcp:notion", searchableText: "docs wiki specifications"),
            GroundingContextPolicy.SourceCandidate(
                id: "mcp:hubspot",
                searchableText: "CRM renewal pricing objections close date",
                strongFor: [.sales, .customerSuccess]),
            GroundingContextPolicy.SourceCandidate(
                id: "mcp:sentry", searchableText: "errors incidents crashes",
                strongFor: [.engineering]),
        ]

        let selected = GroundingContextPolicy.selectSources(
            candidates,
            query: "Close the Acme renewal and resolve pricing objections",
            tier: .free,
            requestedLimit: 1)

        #expect(selected.map(\.id) == ["mcp:hubspot"])
    }

    @Test("empty and boilerplate-only queries never manufacture connector searches")
    func skipsContentFreeQueries() {
        #expect(!GroundingContextPolicy.retrievalIsWorthwhile(query: ""))
        #expect(!GroundingContextPolicy.retrievalIsWorthwhile(query: "Please help with this meeting"))
        #expect(GroundingContextPolicy.retrievalIsWorthwhile(query: "CRX-42"))
        #expect(GroundingContextPolicy.retrievalIsWorthwhile(query: "renewal pricing"))
    }

    @Test("duplicate facts are attached once while distinct sources survive")
    func deduplicatesFactsAcrossSources() {
        let snippets = [
            GroundingSnippet(
                serverName: "Linear", toolName: "search",
                text: "CRX-42 blocks the launch migration. Owner is Ana.",
                sourceID: "mcp:linear", readFor: "open blockers"),
            GroundingSnippet(
                serverName: "Slack", toolName: "search",
                text: "CRX-42 blocks the launch migration.",
                sourceID: "team:slack", readFor: "team concerns"),
            GroundingSnippet(
                serverName: "Notion", toolName: "search",
                text: "The rollback plan requires a canary release.",
                sourceID: "mcp:notion", readFor: "prior decisions"),
        ]

        let optimized = GroundingContextPolicy.optimizedSnippets(
            snippets,
            query: "launch migration rollback",
            tier: .premium,
            characterLimit: 500,
            sourceLimit: 3)
        let body = optimized.map(\.text).joined(separator: "\n")

        #expect(body.components(separatedBy: "CRX-42 blocks the launch migration").count == 2)
        #expect(body.contains("Owner is Ana"))
        #expect(body.contains("canary release"))
        #expect(body.count <= 500)
    }

    @Test("packing is source-diverse, bounded, and never cuts a word")
    func boundedFairPacking() {
        let snippets = (0..<4).map { index in
            GroundingSnippet(
                serverName: "Source \(index)", toolName: "search",
                text: "Distinct fact \(index) " + String(repeating: "evidence ", count: 80),
                sourceID: "mcp:\(index)")
        }
        let optimized = GroundingContextPolicy.optimizedSnippets(
            snippets, tier: .ultra, characterLimit: 220, sourceLimit: 4)

        #expect(optimized.count == 4)
        #expect(optimized.map(\.text).reduce(0) { $0 + $1.count } <= 220)
        #expect(optimized.allSatisfy { $0.text.hasSuffix("…") || $0.text.hasSuffix("evidence ") })
    }

    @Test("cache-query canonicalization reuses harmless formatting variants")
    func canonicalQuery() {
        #expect(GroundingContextPolicy.canonicalQuery("  July   Pricing?  ") == "july pricing")
        #expect(GroundingContextPolicy.canonicalQuery("CRX-42") !=
                GroundingContextPolicy.canonicalQuery("CRX-43"))
    }

    @Test("automatic queries combine bounded goal and recent speech without an LLM")
    func deterministicBackgroundQuery() {
        let query = GroundingContextPolicy.backgroundQuery(
            goal: "Resolve the Project Falcon migration blocker",
            recentTranscript: String(repeating: "context ", count: 100)
                + "CRX-42 is still blocked by legal approval",
            maxChars: 180)

        #expect(query.count <= 180)
        #expect(query.contains("Project Falcon"))
        #expect(query.contains("CRX-42"))
    }
}

/// This is the network-boundary proof for the Blind Spot fix: source limiting
/// is applied before task-group creation, so discarded sources are never called.
@MainActor
@Suite("MCP grounding pre-fetch budget", .serialized)
struct MCPGroundingBudgetTests {
    private func searchTool() -> Tool {
        Tool(
            name: "search",
            description: "Search records",
            inputSchema: .object([
                "properties": .object([
                    "query": .object(["type": .string("string")])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false))
    }

    @Test("maxSources one performs exactly one connector transport call")
    func capPrecedesFetch() async throws {
        var called: [String] = []
        let tool = searchTool()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in [tool] },
            toolCallOverride: { server, _, _ in
                called.append(server.id)
                return "\(server.name) evidence"
            })
        let ids = ["notion", "linear", "sentry"]
        let servers = try ids.map { id in
            try #require(MCPCatalog.builtIn.first { $0.id == id })
        }
        for server in servers { await manager.connect(server) }

        let snippets = await manager.groundingSnippets(
            goal: "CRX-42 migration ticket",
            includeTeam: false,
            maxSources: 1)

        #expect(called.count == 1)
        #expect(called == ["linear"])
        #expect(snippets.count == 1)
        #expect(snippets.first?.sourceID == "mcp:linear")
    }

    @Test("Blind Spot grounding skips query-derivation gateway while interactive grounding retains it")
    func blindSpotSkipsDerivationSpend() async throws {
        let savedGrounding = Config.connectedAppsGroundingEnabled
        defer { Config.connectedAppsGroundingEnabled = savedGrounding }
        let tool = searchTool()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in [tool] },
            toolCallOverride: { _, _, _ in "CRX-42 remains open" })
        let linear = try #require(MCPCatalog.builtIn.first { $0.id == "linear" })
        await manager.connect(linear)

        // Both tool calls below are instant in-process stubs, so this test does
        // not exercise the grounding deadline — but on a saturated machine the
        // real eight seconds can elapse before a stub is scheduled, the deadline
        // fires, and grounding correctly returns nothing. The test then reports
        // an empty result as a product failure. Take the clock out of it.
        let realDeadline = MCPConnectionManager.groundingDeadline
        MCPConnectionManager.groundingDeadline = 600
        defer { MCPConnectionManager.groundingDeadline = realDeadline }

        let gateway = MockLLMGateway(response: "CRX-42, migration blocker")
        let state = AppState(
            llm: gateway,
            credentialStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter())
        state.mcp = manager
        state.useConnectedAppsInPrompts = true
        let transcriptText = String(repeating:
            "The Project Falcon migration remains blocked by CRX-42 and legal review. ",
            count: 8)
        state.transcript = [TranscriptEntry(source: .system, text: transcriptText)]
        let workflow = PromptWorkflow(
            servers: ["linear"],
            queryStrategy: .topics,
            sourceIntents: [.tasks])

        let automatic = await state.groundingSnippetsForTesting(
            workflow: workflow,
            promptID: "blind-spot-economy",
            query: GroundingContextPolicy.backgroundQuery(
                goal: "Unblock Project Falcon",
                recentTranscript: transcriptText),
            maxSources: 1,
            deriveQuery: false)
        #expect(!automatic.isEmpty)
        #expect(gateway.calls.isEmpty)

        let interactive = await state.groundingSnippetsForTesting(
            workflow: workflow,
            promptID: "interactive-grounding",
            query: "Unblock Project Falcon",
            maxSources: 1,
            deriveQuery: true)
        #expect(!interactive.isEmpty)
        #expect(gateway.calls.count == 1)
        #expect(gateway.calls.first?.system.contains("searchable") == true)
    }
}
