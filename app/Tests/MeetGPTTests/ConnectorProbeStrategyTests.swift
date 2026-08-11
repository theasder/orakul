import Testing
import Foundation
@testable import MeetGPT

/// Per-connector probe strategies. Before these, `researchOne(server:goal:)` sent
/// the call's goal verbatim to every connector — Notion, Sentry, HubSpot and
/// PostHog all received the same string — which throws away the only advantage a
/// connector has: it knows something specific the room does not.
@Suite("Connector probe strategies")
struct ConnectorProbeStrategyTests {
    @Test("every strategy declares both a query bias and a reason to read it")
    func strategiesAreComplete() {
        let all = ConnectorProbeStrategy.byServerID.merging(
            ConnectorProbeStrategy.byTeamService, uniquingKeysWith: { a, _ in a })
        #expect(!all.isEmpty)
        for (id, probe) in all {
            #expect(!probe.queryHint.isEmpty, "\(id) has no query hint")
            #expect(!probe.readFor.isEmpty, "\(id) has no readFor — its result is just more background text")
        }
    }

    @Test("no two connectors are asked the same question")
    func hintsAreDistinct() {
        // Identical hints mean the per-connector work is decorative.
        let hints = ConnectorProbeStrategy.byServerID.values.map(\.queryHint)
        #expect(Set(hints).count == hints.count)
    }

    @Test("the query leads with the goal and then biases toward the connector")
    func queryShape() {
        let query = ConnectorProbeStrategy.query(goal: "Close the Acme renewal", serverID: "hubspot")
        #expect(query.hasPrefix("Close the Acme renewal"))
        #expect(query.contains("objections"))
    }

    @Test("a bug tracker and a CRM receive different queries for the same call")
    func differentConnectorsDifferentQueries() {
        let goal = "Ship the export rewrite"
        let linear = ConnectorProbeStrategy.query(goal: goal, serverID: "linear")
        let hubspot = ConnectorProbeStrategy.query(goal: goal, serverID: "hubspot")
        #expect(linear != hubspot)
        #expect(linear.contains("open issues"))
        #expect(hubspot.contains("stalled deals"))
    }

    @Test("an unmapped connector still gets the plain goal, never an empty query")
    func unmappedFallsBackToGoal() {
        // A connector with no strategy must degrade to today's behaviour rather
        // than being silently skipped or sent a hint-only query.
        let query = ConnectorProbeStrategy.query(goal: "Ship the rewrite", serverID: "some-custom-server")
        #expect(query == "Ship the rewrite")
    }

    @Test("an empty goal does not produce a query that is only punctuation")
    func emptyGoalUsesHintAlone() {
        let query = ConnectorProbeStrategy.query(goal: "   ", serverID: "sentry")
        #expect(!query.hasPrefix("—"))
        #expect(query.contains("error rate"))
    }

    @Test("queries are bounded — long ones make connector search match stray terms")
    func queryIsBounded() {
        let long = String(repeating: "renewal negotiation ", count: 200)
        let query = ConnectorProbeStrategy.query(goal: long, serverID: "hubspot", maxChars: 120)
        #expect(query.count <= 120)
    }

    @Test("analytics connectors are told to contradict the room, not agree with it")
    func analyticsContradicts() {
        // The whole point of an analytics probe: a discovery call will happily
        // conclude users love a feature, and the usage number is not in the
        // transcript. If the readFor does not license disagreement, it will not.
        for id in ["posthog", "amplitude", "mixpanel"] {
            let probe = try? #require(ConnectorProbeStrategy.probe(forServerID: id))
            let readFor = probe?.readFor.lowercased() ?? ""
            #expect(readFor.contains("not") || readFor.contains("versus"),
                    "\(id) never licenses contradicting the room")
        }
    }

    @Test("the field decides which connectors are probed first")
    func prioritizationFollowsTheField() {
        // A tier that affords only two probes should spend them where the field
        // says the answer lives — a product call asks analytics before a CRM.
        let ids = ["hubspot", "posthog", "sentry"]
        let forProduct = ConnectorProbeStrategy.prioritized(ids, for: .product)
        #expect(forProduct.first == "posthog")

        let forSales = ConnectorProbeStrategy.prioritized(ids, for: .sales)
        #expect(forSales.first == "hubspot")
    }

    @Test("prioritization keeps every connector and never reorders within a group")
    func prioritizationIsStableAndLossless() {
        // Dropping a connector would silently narrow research; an unstable order
        // would make two wakes on the same call probe different things.
        let ids = ["notion", "hubspot", "posthog", "linear", "unmapped"]
        let out = ConnectorProbeStrategy.prioritized(ids, for: .sales)
        #expect(Set(out) == Set(ids))
        #expect(out.count == ids.count)
        #expect(ConnectorProbeStrategy.prioritized(ids, for: .sales) == out)
    }

    @Test("a connector strong for nothing in particular is never promoted")
    func neutralConnectorsStayPut() {
        // Notion and Fireflies are relevant to every field, so they declare no
        // strongFor — that must not be read as "strong for all".
        for id in ["notion", "fireflies"] {
            #expect(ConnectorProbeStrategy.probe(forServerID: id)?.strongFor.isEmpty == true)
        }
        let out = ConnectorProbeStrategy.prioritized(["notion", "hubspot"], for: .sales)
        #expect(out == ["hubspot", "notion"])
    }
}

@Suite("Analytics connectors in the catalog")
struct AnalyticsCatalogTests {
    @Test("the three probed analytics servers are present and keyless")
    func analyticsServersArePresent() {
        // Live-probed 2026-07: all three answer 401 + WWW-Authenticate with
        // resource_metadata, PKCE S256, and an OPEN registration endpoint — so
        // they need no pre-registered app and no credentials in mac/.env.
        for id in ["posthog", "amplitude", "mixpanel"] {
            let server = MCPCatalog.builtIn.first { $0.id == id }
            #expect(server != nil, "\(id) missing from the built-in catalog")
            #expect(server?.fixedClientID == nil, "\(id) must connect keyless via DCR")
            #expect(server?.endpoint.scheme == "https")
        }
    }

    @Test("every built-in connector has a probe strategy")
    func everyBuiltInHasAStrategy() {
        // A connector with no strategy still works — it falls back to the plain
        // goal — but it is the weaker path, so a new catalog entry should not
        // quietly land there.
        for server in MCPCatalog.builtIn {
            #expect(ConnectorProbeStrategy.probe(forServerID: server.id) != nil,
                    "\(server.id) has no probe strategy, so it gets the generic query")
        }
    }
}
