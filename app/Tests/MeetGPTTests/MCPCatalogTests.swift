import Testing
import Foundation
import MCP
@testable import MeetGPT

/// The built-in MCP catalog is a hand-curated list of hosted work-app servers,
/// each live-verified to speak keyless OAuth. Pin the shape of the catalog and
/// the credential-gated pre-registered servers.
@Suite("MCP catalog")
struct MCPCatalogTests {
    // Analytics (posthog / amplitude / mixpanel) live-probed 2026-07: 401 +
    // WWW-Authenticate with resource_metadata, PKCE S256, open DCR — so they
    // belong in builtIn rather than the credential-gated pre-registered lane.
    private let expectedBuiltInIDs = ["notion", "fireflies", "linear",
                                      "atlassian", "intercom", "sentry", "zapier", "attio",
                                      "posthog", "amplitude", "mixpanel"]

    private struct ExpectedContract {
        let endpoint: String
        let registration: MCPProviderContract.Registration
    }

    /// Deliberately explicit: adding, removing, renaming or repointing any
    /// provider is a contract change that must be reviewed in this inventory.
    private var expectedContracts: [String: ExpectedContract] {[
        "notion": .init(endpoint: "https://mcp.notion.com/mcp", registration: .dynamicClientRegistration),
        "fireflies": .init(endpoint: "https://api.fireflies.ai/mcp", registration: .dynamicClientRegistration),
        "linear": .init(endpoint: "https://mcp.linear.app/mcp", registration: .dynamicClientRegistration),
        "asana": .init(endpoint: "https://mcp.asana.com/v2/mcp", registration: .preRegistered(loopbackPort: 52703)),
        "atlassian": .init(endpoint: "https://mcp.atlassian.com/v1/mcp/authv2", registration: .dynamicClientRegistration),
        "intercom": .init(endpoint: "https://mcp.intercom.com/mcp", registration: .dynamicClientRegistration),
        "sentry": .init(endpoint: "https://mcp.sentry.dev/mcp", registration: .dynamicClientRegistration),
        "zapier": .init(endpoint: "https://mcp.zapier.com/api/mcp/mcp", registration: .dynamicClientRegistration),
        "attio": .init(endpoint: "https://mcp.attio.com/mcp", registration: .dynamicClientRegistration),
        "posthog": .init(endpoint: "https://mcp.posthog.com/mcp", registration: .dynamicClientRegistration),
        "amplitude": .init(endpoint: "https://mcp.amplitude.com/mcp", registration: .dynamicClientRegistration),
        "mixpanel": .init(endpoint: "https://mcp.mixpanel.com/mcp", registration: .dynamicClientRegistration),
        "hubspot": .init(endpoint: "https://mcp.hubspot.com/", registration: .preRegistered(loopbackPort: 52700)),
        "affinity": .init(endpoint: "https://mcp.affinity.co/mcp", registration: .preRegistered(loopbackPort: 52701)),
        "zoom": .init(endpoint: "https://mcp-us.zoom.us/mcp/zoom/streamable", registration: .preRegistered(loopbackPort: 52702)),
        "gmail": .init(endpoint: "https://gmailmcp.googleapis.com/mcp/v1", registration: .preRegistered(loopbackPort: nil)),
        "google-analytics": .init(endpoint: "https://analyticsdata.googleapis.com/mcp/v1", registration: .preRegistered(loopbackPort: nil)),
    ]}

    @Test("built-in catalog carries exactly the expected server ids")
    func builtInIDs() {
        let ids = MCPCatalog.builtIn.map(\.id)
        #expect(Set(ids) == Set(expectedBuiltInIDs))
        #expect(ids.count == expectedBuiltInIDs.count)
    }

    @Test("provider contract inventory pins every known id, endpoint and OAuth mode")
    func providerContractInventoryIsExhaustive() throws {
        let contracts = MCPCatalog.providerContracts
        #expect(Set(contracts.map(\.id)) == Set(expectedContracts.keys))
        #expect(contracts.count == expectedContracts.count)

        for contract in contracts {
            let expected = try #require(expectedContracts[contract.id])
            #expect(contract.descriptor.endpoint.absoluteString == expected.endpoint,
                    "\(contract.id) endpoint changed")
            #expect(contract.registration == expected.registration,
                    "\(contract.id) OAuth registration contract changed")
            #expect(contract.descriptor.endpoint.scheme == "https")
            #expect(contract.descriptor.fixedClientID == nil)
            #expect(contract.descriptor.fixedClientSecret == nil)
        }
    }

    @Test("every provider id has a connector-specific research contract")
    func everyProviderHasAProbeContract() {
        for contract in MCPCatalog.providerContracts {
            let probe = ConnectorProbeStrategy.probe(forServerID: contract.id)
            #expect(probe != nil, "\(contract.id) would receive only a generic query")
            #expect(probe?.queryHint.isEmpty == false, "\(contract.id) has no query contract")
            #expect(probe?.readFor.isEmpty == false, "\(contract.id) has no evidence-reading contract")
        }
    }

    @Test("credential-gated descriptors cannot drift from their audited contracts")
    func configuredDescriptorsMatchInventory() throws {
        for descriptor in MCPCatalog.preRegistered {
            let contract = try #require(
                MCPCatalog.providerContracts.first(where: { $0.id == descriptor.id }))
            #expect(descriptor.endpoint == contract.descriptor.endpoint)
            #expect(descriptor.name == contract.descriptor.name)
            #expect(descriptor.symbol == contract.descriptor.symbol)
            #expect(descriptor.keywords == contract.descriptor.keywords)
            #expect(descriptor.fixedLoopbackPort == contract.descriptor.fixedLoopbackPort)
            #expect(descriptor.fixedClientID?.isEmpty == false)
            #expect(descriptor.fixedClientSecret?.isEmpty == false)
        }
    }

    @Test("built-in ids are unique")
    func idsAreUnique() {
        let ids = MCPCatalog.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every built-in endpoint is a valid https URL")
    func endpointsAreHTTPS() {
        for descriptor in MCPCatalog.builtIn {
            #expect(descriptor.endpoint.scheme == "https", "\(descriptor.id) is not https")
            #expect(descriptor.endpoint.host?.isEmpty == false, "\(descriptor.id) has no host")
        }
    }

    @Test("Atlassian uses the current browser-OAuth endpoint and names Confluence")
    func atlassianOAuthEndpoint() throws {
        let atlassian = try #require(MCPCatalog.builtIn.first { $0.id == "atlassian" })
        #expect(atlassian.endpoint.absoluteString == "https://mcp.atlassian.com/v1/mcp/authv2")
        #expect(atlassian.name.contains("Confluence"))
    }

    @Test("no built-in is marked custom, and each has a name and symbol")
    func builtInsAreNotCustom() {
        for descriptor in MCPCatalog.builtIn {
            #expect(descriptor.isCustom == false, "\(descriptor.id) is flagged custom")
            #expect(!descriptor.name.isEmpty, "\(descriptor.id) has an empty name")
            #expect(!descriptor.symbol.isEmpty, "\(descriptor.id) has an empty symbol")
        }
    }

    @Test("built-in descriptors carry no fixed OAuth client (open DCR)")
    func builtInsUseOpenRegistration() {
        for descriptor in MCPCatalog.builtIn {
            #expect(descriptor.fixedClientID == nil, "\(descriptor.id) unexpectedly has a fixed client id")
            #expect(descriptor.fixedClientSecret == nil, "\(descriptor.id) unexpectedly has a fixed secret")
            #expect(descriptor.fixedLoopbackPort == nil, "\(descriptor.id) unexpectedly has a fixed port")
        }
    }

    @Test("pre-registered servers are gated on Config credentials")
    func preRegisteredGating() {
        // The pre-registered apps (Asana, HubSpot, Affinity, Zoom, Gmail,
        // Google Analytics) only surface
        // when their client credentials are baked into the build. In the
        // default build (empty Secrets) the list is empty.
        let credsPresent = !Config.asanaClientID.isEmpty && !Config.asanaClientSecret.isEmpty
            || !Config.hubSpotClientID.isEmpty && !Config.hubSpotClientSecret.isEmpty
            || !Config.affinityClientID.isEmpty && !Config.affinityClientSecret.isEmpty
            || !Config.zoomClientID.isEmpty && !Config.zoomClientSecret.isEmpty
            || !Config.gmailClientID.isEmpty && !Config.gmailClientSecret.isEmpty
            || !Config.googleAnalyticsClientID.isEmpty && !Config.googleAnalyticsClientSecret.isEmpty

        if !credsPresent {
            #expect(MCPCatalog.preRegistered.isEmpty)
        } else {
            #expect(!MCPCatalog.preRegistered.isEmpty)
        }
    }

    @Test("Asana V2 is credential-gated and pins its OAuth audience")
    @MainActor
    func asanaV2Contract() {
        let hasCreds = !Config.asanaClientID.isEmpty && !Config.asanaClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.asana == nil)
        } else {
            #expect(MCPCatalog.asana?.id == "asana")
            #expect(MCPCatalog.asana?.fixedLoopbackPort == 52703)
        }
        #expect(MCPConnectionManager.tokenStorageID(for: "asana") == "asana-v2")
        #expect(MCPConnectionManager.oauthEndpointOverrides(for: "asana").resource?.absoluteString
                == "https://mcp.asana.com/v2")
        #expect(MCPConnectionManager.oauthEndpointOverrides(for: "linear").resource == nil)
    }

    @Test("Asana research prefers universal task search on every workspace tier")
    @MainActor
    func asanaSearchContract() throws {
        #expect(MCPConnectionManager.searchToolPreferences["asana"]?.first == "search_objects")
        let properties: Value = .object([
            "query": .object(["type": .string("string")]),
            "resource_type": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer")]),
        ])
        let tool = Tool(
            name: "search_objects", description: nil,
            inputSchema: .object(["properties": properties]))
        let args = try #require(MCPConnectionManager.researchArguments(
            tool: tool, serverID: "asana", query: "launch"))
        #expect(args["query"] == .string("launch"))
        #expect(args["resource_type"] == .string("task"))
        #expect(args["limit"] == .int(3))
    }

    @Test("hubSpot descriptor is nil without both credentials")
    func hubSpotGating() {
        let hasCreds = !Config.hubSpotClientID.isEmpty && !Config.hubSpotClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.hubSpot == nil)
        } else {
            #expect(MCPCatalog.hubSpot?.id == "hubspot")
        }
    }

    @Test("affinity descriptor is nil without both credentials")
    func affinityGating() {
        let hasCreds = !Config.affinityClientID.isEmpty && !Config.affinityClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.affinity == nil)
        } else {
            #expect(MCPCatalog.affinity?.id == "affinity")
        }
    }

    @Test("zoom descriptor is nil without both credentials")
    func zoomGating() {
        let hasCreds = !Config.zoomClientID.isEmpty && !Config.zoomClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.zoom == nil)
        } else {
            #expect(MCPCatalog.zoom?.id == "zoom")
        }
    }

    @Test("MCPServerDescriptor survives a Codable round-trip")
    func codableRoundTrip() throws {
        let original = MCPServerDescriptor(
            id: "custom", name: "Custom Server",
            endpoint: URL(string: "https://example.com/mcp")!,
            symbol: "server.rack", isCustom: true,
            fixedClientID: "abc", fixedClientSecret: "shhh", fixedLoopbackPort: 52700)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: data)

        #expect(decoded == original)
    }

    @Test("Codable round-trip preserves nil fixed-client fields")
    func codableRoundTripNilFields() throws {
        let original = MCPCatalog.builtIn[0]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPServerDescriptor.self, from: data)

        #expect(decoded == original)
        #expect(decoded.fixedClientID == nil)
        #expect(decoded.fixedLoopbackPort == nil)
    }
}
