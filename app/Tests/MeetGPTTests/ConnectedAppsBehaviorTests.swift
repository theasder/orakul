import Foundation
import Testing
import MCP
@testable import MeetGPT

/// Behavior once work apps are actually CONNECTED — the counts, token
/// potential, and grounding surface the UI and prompt pipeline read. A server
/// with a cached token is "authorized" (prefersMCP), which is the deterministic
/// stand-in for a live session (no network in tests).
@Suite("Connected apps behavior")
struct ConnectedAppsBehaviorTests {
    /// Build an AppState whose MCP manager has `ids` authorized via seeded
    /// tokens. Returns the manager too so the caller keeps it alive (AppState
    /// holds it weakly).
    @MainActor
    private func stateWithAuthorized(_ ids: [String]) async throws
        -> (AppState, MCPConnectionManager) {
        let keychain = InMemoryKeychain()
        for id in ids {
            let server = try #require(MCPCatalog.builtIn.first { $0.id == id })
            keychain.set(Data("cached-token".utf8), for: "mcp.token.\(server.id)")
        }
        let manager = MCPConnectionManager(tokenStore: keychain)
        await manager.loadPersistedAuthorization()
        let state = AppState(llm: MockLLMGateway(response: "ok"),
                             credentialStore: InMemoryKeychain())
        state.groundApps = true
        state.mcp = manager
        return (state, manager)
    }

    @Test("an authorized app is a researchable, counted source with non-zero token potential")
    @MainActor
    func authorizedAppIsCounted() async throws {
        let (state, manager) = try await stateWithAuthorized(["linear"])
        #expect(manager.researchableServers.contains { $0.id == "linear" })
        #expect(state.connectedAppSourceCount >= 1)
        // Potential is tokens(sources × per-source budget) — strictly positive
        // once at least one app is connected.
        #expect(state.connectedAppsTokenPotential > 0)
        _ = manager
    }

    @Test("token potential scales with the number of connected apps")
    @MainActor
    func potentialScalesWithCount() async throws {
        let (one, m1) = try await stateWithAuthorized(["linear"])
        let onePotential = one.connectedAppsTokenPotential
        let oneCount = one.connectedAppSourceCount

        let (two, m2) = try await stateWithAuthorized(["linear", "notion"])
        #expect(two.connectedAppSourceCount == oneCount + 1)
        // Team-connector contribution (env-coupled) is constant across both, so
        // the DELTA is deterministic even if the absolute value includes it.
        #expect(two.connectedAppsTokenPotential > onePotential)
        #expect(two.connectedAppsTokenPotential - onePotential
                == TokenEstimate.tokens(TokenEstimate.connectedSourceCharacterBudget))

        // Exact cross-boundary constants exercised by the API tariff matrix:
        // a grounded research cycle asks at most two sources, whose combined
        // prompt potential remains below the fixed 6k-token price boundary.
        #expect(TokenEstimate.connectedSourceCharacterBudget == 3_000)
        #expect(CopilotCadence.maxGroundingSources == 2)
        let groundedPotential = TokenEstimate.tokens(
            CopilotCadence.maxGroundingSources * TokenEstimate.connectedSourceCharacterBudget)
        #expect(groundedPotential == 1_500)
        #expect(groundedPotential < TokenEstimate.baseCreditInputTokens)
        _ = (m1, m2)
    }

    @Test("a connected Google account adds its granted services to the source count")
    @MainActor
    func googleServicesCounted() async throws {
        let (state, manager) = try await stateWithAuthorized([])   // no MCP apps
        let baseline = state.connectedAppSourceCount

        let savedServices = Config.googleGrantedServices
        let savedVersion = Config.googleScopeVersion
        defer {
            Config.googleGrantedServices = savedServices
            Config.googleScopeVersion = savedVersion
        }
        Config.googleScopeVersion = GoogleAuth.scopeVersion   // current-scope grant
        Config.googleGrantedServices = ["calendar", "docs"]
        state.googleConnected = true

        #expect(state.connectedAppSourceCount == baseline + 2)
        _ = manager
    }

    @Test("unknown or stale Google scope ids cannot inflate source tokens")
    @MainActor
    func unknownGoogleServicesAreIgnored() async throws {
        let (state, manager) = try await stateWithAuthorized([])
        let savedServices = Config.googleGrantedServices
        let savedVersion = Config.googleScopeVersion
        defer {
            Config.googleGrantedServices = savedServices
            Config.googleScopeVersion = savedVersion
        }
        Config.googleScopeVersion = GoogleAuth.scopeVersion
        Config.googleGrantedServices = ["calendar", "gmail", "retired-service"]
        state.googleConnected = true

        #expect(state.connectedAppSourceCount == 1)
        #expect(state.connectedAppsTokenPotential
                == TokenEstimate.tokens(TokenEstimate.connectedSourceCharacterBudget
                    * (1 + state.connectedTeamSourceCount)))
        _ = manager
    }

    @Test("a connected app reaches a prompt's grounding sources")
    @MainActor
    func connectedAppGroundsAPrompt() async throws {
        let (state, manager) = try await stateWithAuthorized(["linear"])
        let id = "connected-apps-grounds-\(UUID().uuidString)"
        let prompt = QuickPrompt.custom(
            id: id, icon: "✅", title: "Ticket status",
            prompt: "Find open Linear issues and the sprint backlog.")
        state.saveCustomPrompt(prompt)

        #expect(state.promptWorkflowSources[id]?.contains { $0.id == "mcp:linear" } == true)
        state.deleteCustomPrompt(id: id)
        _ = manager
    }

    @Test("with nothing connected the app source count is zero")
    @MainActor
    func nothingConnectedIsZero() async throws {
        let (state, manager) = try await stateWithAuthorized([])
        let savedVersion = Config.googleScopeVersion
        defer { Config.googleScopeVersion = savedVersion }
        Config.googleScopeVersion = 0   // no current-scope Google grant
        state.googleConnected = false
        // connectedAppSourceCount counts MCP + Google only (team is separate).
        #expect(state.connectedAppSourceCount == 0)
        _ = manager
    }
}
