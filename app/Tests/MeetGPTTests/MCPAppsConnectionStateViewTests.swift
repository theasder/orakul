import Foundation
import MCP
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
private final class ControlledMCPConnectionAttempt {
    private(set) var started = false
    private var continuation: CheckedContinuation<[Tool], Never>?
    private var releasedTools: [Tool]?

    func run(_: MCPServerDescriptor) async throws -> [Tool] {
        started = true
        if let releasedTools { return releasedTools }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(with tools: [Tool]) {
        releasedTools = tools
        let pending = continuation
        continuation = nil
        pending?.resume(returning: tools)
    }
}

@MainActor
private final class ControlledMCPDisconnectAttempt {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_: MCPServerDescriptor) async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct SyntheticConnectorError: LocalizedError {
    let errorDescription: String?
}

/// The actual Settings provider row, inspected without an app process, OAuth,
/// audio devices, or network. The manager's override is intentionally incapable
/// of constructing a callable MCP client: it can only drive tools/list state.
@MainActor
@Suite("Connected Apps provider-row states", .serialized)
struct MCPAppsConnectionStateViewTests {
    private let providerID = "notion"

    private func server() throws -> MCPServerDescriptor {
        try #require(MCPCatalog.builtIn.first { $0.id == providerID })
    }

    private func tools(_ count: Int = 2) -> [Tool] {
        (0..<count).map { index in
            Tool(name: "search_\(index)", description: "Read context",
                 inputSchema: .object([:]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false))
        }
    }

    private func appState(for manager: MCPConnectionManager) -> AppState {
        let state = AppState(
            llm: MockLLMGateway(response: ""),
            credentialStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter())
        state.mcp = manager
        return state
    }

    private func row(manager: MCPConnectionManager, state: AppState) throws
        -> InspectableView<ViewType.ClassifiedView> {
        let view = AnyView(
            MCPAppsSection()
                .environmentObject(manager)
                .environmentObject(state))
        return try view.inspect().find(
            viewWithAccessibilityIdentifier: "settings.connected.provider.\(providerID)")
    }

    private func expectMissingButton(_ title: String,
                                     in row: InspectableView<ViewType.ClassifiedView>) {
        #expect(throws: (any Error).self) { try row.find(button: title) }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        // 10s, not 2s. The loop exits the instant the condition holds, so a
        // generous deadline costs nothing when the machine is idle — and 2s was
        // enough in isolation but marginal in a full parallel run, where these
        // tests intermittently failed with "Search did not find a match"
        // because the view had not been updated yet. A timeout tuned to an idle
        // machine is a flake waiting for a loaded one.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("disconnected provider offers Connect and no stale status")
    func disconnected() throws {
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in [] })
        let state = appState(for: manager)
        let inspected = try row(manager: manager, state: state)

        #expect(throws: Never.self) { try inspected.find(button: "Подключить") }
        expectMissingButton("Переподключить", in: inspected)
        expectMissingButton("Отключить", in: inspected)
        expectMissingButton("Отмена", in: inspected)
        #expect(throws: (any Error).self) {
            try inspected.find(viewWithAccessibilityIdentifier:
                "settings.connected.provider.\(providerID).status")
        }
    }

    @Test("connecting provider shows named progress and a cancel action")
    func connecting() async throws {
        let driver = ControlledMCPConnectionAttempt()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { try await driver.run($0) })
        let state = appState(for: manager)
        let target = try server()
        let task = Task { await manager.connect(target) }
        defer { driver.release(with: tools()) }
        await waitUntil { driver.started && manager.state(of: target.id) == .connecting }

        let inspected = try row(manager: manager, state: state)
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityLabel: "Подключаю Notion")
        }
        #expect(throws: Never.self) { try inspected.find(button: "Отмена") }
        expectMissingButton("Подключить", in: inspected)
        expectMissingButton("Отключить", in: inspected)

        driver.release(with: tools())
        await task.value
    }

    @Test("authorized provider offers Reconnect and reconnecting becomes cancellable progress")
    func reconnecting() async throws {
        let keychain = InMemoryKeychain()
        keychain.set(Data("cached-token".utf8), for: "mcp.token.\(providerID)")
        let driver = ControlledMCPConnectionAttempt()
        let manager = MCPConnectionManager(
            tokenStore: keychain,
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { try await driver.run($0) })
        await manager.loadPersistedAuthorization()
        let state = appState(for: manager)
        let target = try server()

        var inspected = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try inspected.find(button: "Переподключить") }
        #expect(throws: Never.self) { try inspected.find(text: "authorized") }

        let task = Task { await manager.connect(target) }
        defer { driver.release(with: tools()) }
        await waitUntil { driver.started && manager.state(of: target.id) == .connecting }
        inspected = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try inspected.find(button: "Отключить") }
        expectMissingButton("Отмена", in: inspected)
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityIdentifier:
                "settings.connected.provider.\(providerID).progress")
        }
        expectMissingButton("Переподключить", in: inspected)

        driver.release(with: tools())
        await task.value
    }

    @Test("authorized reconnect exposes Disconnect—not misleading Cancel—and late success cannot restore its grant")
    func reconnectStopIsExplicitlyDestructive() async throws {
        let keychain = InMemoryKeychain()
        keychain.set(Data("cached-token".utf8), for: "mcp.token.\(providerID)")
        let driver = ControlledMCPConnectionAttempt()
        let manager = MCPConnectionManager(
            tokenStore: keychain,
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { try await driver.run($0) })
        await manager.loadPersistedAuthorization()
        let state = appState(for: manager)
        let target = try server()
        let connectTask = Task { await manager.connect(target) }
        defer { driver.release(with: tools()) }
        await waitUntil { driver.started && manager.state(of: target.id) == .connecting }

        let connectingRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try connectingRow.find(button: "Отключить") }
        expectMissingButton("Отмена", in: connectingRow)
        try connectingRow.find(button: "Отключить").tap()
        await waitUntil { manager.state(of: target.id) == .disconnecting }

        // Rapid non-linear navigation cannot expose a Connect button that only
        // coalesces onto the canceled attempt. The row remains non-actionable
        // until that attempt has actually unwound.
        let disconnectingRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) {
            try disconnectingRow.find(viewWithAccessibilityLabel: "Отключаю Notion")
        }
        for title in ["Подключить", "Reconnect", "Отключить", "Отмена"] {
            expectMissingButton(title, in: disconnectingRow)
        }

        driver.release(with: tools(3))
        await connectTask.value
        await waitUntil { manager.state(of: target.id) == .disconnected }

        #expect(manager.state(of: target.id) == .disconnected)
        #expect(!manager.isAuthorized(target.id))
        #expect(manager.tools(for: target.id).isEmpty)
        #expect(keychain.get("mcp.token.\(providerID)") == nil)
        let finalRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try finalRow.find(button: "Подключить") }
        expectMissingButton("Reconnect", in: finalRow)
    }

    @Test("connected provider reports tools and exposes Disconnect")
    func connected() async throws {
        let advertised = tools(2)
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in advertised })
        let target = try server()
        await manager.connect(target)
        let state = appState(for: manager)
        let inspected = try row(manager: manager, state: state)

        #expect(throws: Never.self) { try inspected.find(button: "Отключить") }
        #expect(throws: Never.self) {
            try inspected.find(textWhere: { text, _ in text.hasPrefix("2 tools ·") })
        }
        expectMissingButton("Подключить", in: inspected)
        expectMissingButton("Переподключить", in: inspected)
        expectMissingButton("Отмена", in: inspected)
    }

    @Test("transient errors preserve authorized Reconnect but use Connect without a token")
    func errorStates() async throws {
        let message = "Synthetic provider outage"
        let target = try server()

        let fresh = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in
                throw SyntheticConnectorError(errorDescription: message)
            })
        await fresh.connect(target)
        var state = appState(for: fresh)
        var inspected = try row(manager: fresh, state: state)
        #expect(throws: Never.self) { try inspected.find(text: message) }
        #expect(throws: Never.self) { try inspected.find(button: "Подключить") }
        expectMissingButton("Переподключить", in: inspected)

        let keychain = InMemoryKeychain()
        keychain.set(Data("cached-token".utf8), for: "mcp.token.\(providerID)")
        let authorized = MCPConnectionManager(
            tokenStore: keychain,
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in
                throw SyntheticConnectorError(errorDescription: message)
            })
        await authorized.loadPersistedAuthorization()
        await authorized.connect(target)
        state = appState(for: authorized)
        inspected = try row(manager: authorized, state: state)
        #expect(throws: Never.self) { try inspected.find(text: message) }
        #expect(throws: Never.self) { try inspected.find(button: "Переподключить") }
        expectMissingButton("Подключить", in: inspected)
    }

    @Test("Disconnect action clears authorization and returns the row to Connect")
    func disconnectAction() async throws {
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in self.tools() })
        let target = try server()
        await manager.connect(target)
        let state = appState(for: manager)

        let connectedRow = try row(manager: manager, state: state)
        try connectedRow.find(button: "Отключить").tap()
        await waitUntil { manager.state(of: target.id) == .disconnected }

        #expect(!manager.isAuthorized(target.id))
        #expect(manager.tools(for: target.id).isEmpty)
        let disconnectedRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try disconnectedRow.find(button: "Подключить") }
        expectMissingButton("Отключить", in: disconnectedRow)
    }

    @Test("connected teardown hides Connect and rejects reconnect until asynchronous cleanup finishes")
    func connectedTeardownIsNonActionable() async throws {
        let disconnectDriver = ControlledMCPDisconnectAttempt()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in self.tools() },
            disconnectAttemptOverride: { await disconnectDriver.run($0) })
        let target = try server()
        await manager.connect(target)
        let state = appState(for: manager)

        let connectedRow = try row(manager: manager, state: state)
        try connectedRow.find(button: "Отключить").tap()
        await waitUntil {
            disconnectDriver.started && manager.state(of: target.id) == .disconnecting
        }

        let tearingDownRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) {
            try tearingDownRow.find(viewWithAccessibilityLabel: "Отключаю Notion")
        }
        for title in ["Подключить", "Reconnect", "Отключить", "Отмена"] {
            expectMissingButton(title, in: tearingDownRow)
        }
        #expect(manager.tools(for: target.id).isEmpty)
        #expect(!manager.isAuthorized(target.id))

        // A background import/grounding caller cannot replace the connection
        // while the old transport is still unwinding.
        await manager.connect(target)
        #expect(manager.state(of: target.id) == .disconnecting)
        await manager.disconnect(target)
        #expect(manager.state(of: target.id) == .disconnecting,
                "a duplicate disconnect must not publish a premature terminal state")

        disconnectDriver.release()
        await waitUntil { manager.state(of: target.id) == .disconnected }
        let finalRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try finalRow.find(button: "Подключить") }
    }

    @Test("Cancel wins over a late successful connection completion")
    func staleCompletionCannotResurrectRow() async throws {
        let driver = ControlledMCPConnectionAttempt()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { try await driver.run($0) })
        let target = try server()
        let state = appState(for: manager)
        let connectTask = Task { await manager.connect(target) }
        defer { driver.release(with: tools()) }
        await waitUntil { driver.started && manager.state(of: target.id) == .connecting }

        let connectingRow = try row(manager: manager, state: state)
        try connectingRow.find(button: "Отмена").tap()
        await waitUntil { manager.state(of: target.id) == .disconnecting }

        let cancellingRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) {
            try cancellingRow.find(viewWithAccessibilityLabel: "Отключаю Notion")
        }
        for title in ["Подключить", "Reconnect", "Отключить", "Отмена"] {
            expectMissingButton(title, in: cancellingRow)
        }

        // The old tools/list returns after the user's cancel. It must be ignored.
        driver.release(with: tools(3))
        await connectTask.value
        await waitUntil { manager.state(of: target.id) == .disconnected }

        #expect(manager.state(of: target.id) == .disconnected)
        #expect(!manager.isAuthorized(target.id))
        #expect(manager.tools(for: target.id).isEmpty)
        let finalRow = try row(manager: manager, state: state)
        #expect(throws: Never.self) { try finalRow.find(button: "Подключить") }
        expectMissingButton("Отключить", in: finalRow)
        #expect(throws: (any Error).self) {
            try finalRow.find(viewWithAccessibilityIdentifier:
                "settings.connected.provider.\(providerID).status")
        }
    }
}
