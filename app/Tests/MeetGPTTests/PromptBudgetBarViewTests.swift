import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
private final class ControlledCreditFetch {
    private(set) var callCount = 0
    private var continuations: [Int: CheckedContinuation<PaywallUsage?, Error>] = [:]

    func fetch() async throws -> PaywallUsage? {
        let id = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PaywallUsage?, Error>) in
            continuations[id] = continuation
        }
    }

    func resolve(_ id: Int, with usage: PaywallUsage?) {
        continuations.removeValue(forKey: id)?.resume(returning: usage)
    }
}

/// View-logic coverage for the connected-app strip under the prompt buttons.
/// Authorization and prompt usage are deliberately separate: switching usage
/// off must never remove the cached OAuth credential.
@MainActor
@Suite("PromptBudgetBar view", .serialized)
struct PromptBudgetBarViewTests {
    private func freshState() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.googleConnected = false
        return state
    }

    private func bar(state: AppState, mcp: MCPConnectionManager) -> some View {
        state.mcp = mcp
        return PromptBudgetBar()
            .environmentObject(state)
            .environmentObject(mcp)
    }

    private func usage(remaining: Int) -> PaywallUsage {
        PaywallUsage(
            tier: "pro",
            allowances: .init(copilotHours: 20, computeCredits: 250, groundedCycles: 20),
            used: .init(computeCredits: 250 - remaining),
            remaining: .init(computeCredits: remaining),
            periodStart: "2026-07-01"
        )
    }

    @Test("shows real connected app names and removes old category controls")
    func rendersConnectedApps() async throws {
        let state = freshState()
        let keychain = InMemoryKeychain()
        let servers = MCPCatalog.builtIn.filter { ["notion", "linear"].contains($0.id) }
        #expect(servers.count == 2)
        for server in servers {
            keychain.set(Data("cached-token".utf8), for: "mcp.token.\(server.id)")
        }
        let mcp = MCPConnectionManager(tokenStore: keychain)
        await mcp.loadPersistedAuthorization()
        let view = bar(state: state, mcp: mcp)

        #expect(throws: Never.self) { try view.inspect().find(text: "Notion") }
        #expect(throws: Never.self) { try view.inspect().find(text: "Linear") }
        #expect(throws: Never.self) { try view.inspect().find(text: "Добавить приложения") }
        #expect(throws: (any Error).self) { try view.inspect().find(text: "Work apps") }
        #expect(throws: (any Error).self) { try view.inspect().find(text: "Team chat") }
        #expect(throws: (any Error).self) { try view.inspect().find(text: "Decisions") }
    }

    @Test("empty state still offers the direct add-apps action")
    func emptyState() throws {
        let state = freshState()
        let mcp = MCPConnectionManager(tokenStore: InMemoryKeychain())
        let inspected = try bar(state: state, mcp: mcp).inspect()

        #expect(throws: Never.self) { try inspected.find(text: "No apps connected") }
        #expect(throws: Never.self) { try inspected.find(text: "Добавить приложения") }
        let toggle = try inspected.find(ViewType.Toggle.self)
        #expect(toggle.isDisabled())
        #expect(try toggle.isOn() == false)
    }

    @Test("usage switch stops grounding without disconnecting apps")
    func usageSwitchDoesNotDisconnect() async throws {
        let state = freshState()
        let originalApps = state.groundApps
        let originalTeam = state.groundTeam
        defer {
            state.groundApps = originalApps
            state.groundTeam = originalTeam
        }
        state.groundApps = true
        state.groundTeam = true

        let keychain = InMemoryKeychain()
        let server = try #require(MCPCatalog.builtIn.first { $0.id == "notion" })
        keychain.set(Data("cached-token".utf8), for: "mcp.token.\(server.id)")
        let mcp = MCPConnectionManager(tokenStore: keychain)
        await mcp.loadPersistedAuthorization()
        let toggle = try bar(state: state, mcp: mcp).inspect().find(ViewType.Toggle.self)
        let before = state.promptTokenEstimate.totalTokens
        let expectedSavings = TokenEstimate.tokens(
            (1 + TeamConnectors.configured.count) * TokenEstimate.connectedSourceCharacterBudget)

        #expect(try toggle.isOn())
        #expect(toggle.isDisabled() == false)
        #expect(state.connectedAppsTokenPotential == expectedSavings)
        try toggle.tap()

        #expect(state.groundApps == false)
        #expect(state.groundTeam == false)
        #expect(before - state.promptTokenEstimate.totalTokens == expectedSavings)
        #expect(mcp.isAuthorized(server.id))
    }

    @Test("Google renders as one app with its granted services in metadata")
    func googleIsOneApp() throws {
        let savedVersion = Config.googleScopeVersion
        let savedServices = Config.googleGrantedServices
        defer {
            Config.googleScopeVersion = savedVersion
            Config.googleGrantedServices = savedServices
        }
        Config.googleScopeVersion = GoogleAuth.scopeVersion
        Config.googleGrantedServices = Set(GoogleService.allCases.map(\.rawValue))

        let state = freshState()
        state.googleConnected = true
        let mcp = MCPConnectionManager(tokenStore: InMemoryKeychain())
        let inspected = try bar(state: state, mcp: mcp).inspect()

        #expect(throws: Never.self) { try inspected.find(text: "Google") }
        #expect(throws: (any Error).self) { try inspected.find(text: "Calendar") }
        #expect(throws: (any Error).self) { try inspected.find(text: "Docs") }
        #expect(throws: (any Error).self) { try inspected.find(text: "Sheets") }
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityLabel:
                "Google, connected, Calendar, Docs, Sheets, Drive")
        }
    }

    @Test("many connections fold into a bounded overflow badge")
    func capsConnectedApps() async throws {
        let state = freshState()
        let keychain = InMemoryKeychain()
        for server in MCPCatalog.builtIn {
            let storageID = MCPConnectionManager.tokenStorageID(for: server.id)
            keychain.set(Data("cached-token".utf8), for: "mcp.token.\(storageID)")
        }
        let mcp = MCPConnectionManager(tokenStore: keychain)
        await mcp.loadPersistedAuthorization()
        let total = mcp.researchableServers.count + TeamConnectors.configured.count
        let hidden = max(0, total - 5)
        #expect(hidden > 0)

        let inspected = try bar(state: state, mcp: mcp).inspect()
        #expect(throws: Never.self) { try inspected.find(text: "+\(hidden)") }
    }

    @Test("Add apps routes Settings to Connected Apps")
    func addAppsRoutesSettings() throws {
        let state = freshState()
        state.selectedSettingsTab = .general
        let mcp = MCPConnectionManager(tokenStore: InMemoryKeychain())
        let button = try bar(state: state, mcp: mcp).inspect().find(button: "Добавить приложения")

        try button.tap()

        #expect(state.selectedSettingsTab == .connectedApps)
    }

    /// The rail speaks two different languages depending on how chat is served,
    /// and this test used to assume the direct-key one. `creditBadge` is
    /// `.notApplicable` exactly when `!Config.llmViaBackend`, so the branch below
    /// mirrors `summaryRow` rather than depending on whatever `BACKEND_URL`
    /// happens to be baked into this build — that coupling is what broke it when
    /// the keyless build started pointing at a real backend by default.
    @Test("budget rail renders the right summary for the serving mode, plus disclosure")
    func budgetShowsInput() throws {
        let state = freshState()
        let mcp = MCPConnectionManager(tokenStore: InMemoryKeychain())
        let inspected = try bar(state: state, mcp: mcp).inspect()

        if Config.llmViaBackend {
            // Credit-led: credits lead and the token detail moves to the popover.
            let status = try inspected.find(textWhere: { string, _ in
                string.contains("base input rate") || string.contains("extra credits")
                    || string.contains("credits") || string.contains("· base")
            })
            #expect(!(try status.string().isEmpty))
        } else {
            // Direct-key/dev: the token estimate is the only honest number.
            let estimate = try inspected.find(textWhere: { string, _ in
                string.contains("input") && string.contains("~")
            })
            #expect(try estimate.string().contains("~"))
            #expect(try estimate.string().contains("Current partial"))
        }

        // The disclosure control is mode-independent.
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityLabel: "Prompt input budget")
        }
    }

    @Test("credit loader exposes loading and rejects an older late response")
    func creditLoaderRejectsLateResponse() async {
        let fetch = ControlledCreditFetch()
        let loader = CreditUsageLoader(fetch: { try await fetch.fetch() })

        loader.refresh(enabled: true)
        for _ in 0..<100 where fetch.callCount < 1 { await Task.yield() }
        #expect(loader.phase == .loading)

        loader.refresh(enabled: true)
        for _ in 0..<100 where fetch.callCount < 2 { await Task.yield() }
        fetch.resolve(1, with: usage(remaining: 170))
        for _ in 0..<100 where loader.phase != .fresh { await Task.yield() }
        #expect(loader.usage?.remaining.computeCredits == 170)

        loader.refresh(enabled: true)
        #expect(loader.phase == .stale)
        for _ in 0..<100 where fetch.callCount < 3 { await Task.yield() }

        // The first request deliberately finishes last and ignores cancellation.
        fetch.resolve(0, with: usage(remaining: 220))
        for _ in 0..<20 { await Task.yield() }
        #expect(loader.usage?.remaining.computeCredits == 170)
        #expect(loader.phase == .stale)

        fetch.resolve(2, with: usage(remaining: 160))
        for _ in 0..<100 where loader.phase != .fresh { await Task.yield() }
        #expect(loader.usage?.remaining.computeCredits == 160)
    }

    @Test("every compact credit state has an explicit label")
    func compactCreditLabels() {
        #expect(CreditBadge.loading.label(compact: true) == "· cr…")
        #expect(CreditBadge.remaining(42).label(compact: true) == "· 42 cr")
        #expect(CreditBadge.stale.label(compact: true) == "· cr stale")
        #expect(CreditBadge.unavailable.label(compact: true) == "· cr —")
    }
}
