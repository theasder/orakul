import Foundation
import MCP

/// Presents the OAuth authorization URL for an MCP server: opens the system
/// browser and catches the loopback redirect. Called by the SDK only when no
/// valid/refreshable token is stored — silent reconnects skip the browser.
struct LoopbackAuthDelegate: OAuthAuthorizationDelegate {
    let port: UInt16
    /// Non-standard authorization parameters some providers require. The SDK
    /// builds a spec-conformant URL and offers no hook for vendor extras, so
    /// they are appended here, on the way to the browser.
    var extraQueryItems: [URLQueryItem] = []

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await LoopbackRedirectServer(port: port)
            .run(opening: Self.applying(extraQueryItems, to: url))
    }

    /// Append `items`, skipping any parameter the SDK already set — overriding
    /// a spec parameter (`scope`, `state`, `code_challenge`) would break the
    /// exchange rather than extend it.
    static func applying(_ items: [URLQueryItem], to url: URL) -> URL {
        guard !items.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        let existing = Set((components.queryItems ?? []).map(\.name))
        let additions = items.filter { !existing.contains($0.name) }
        guard !additions.isEmpty else { return url }
        components.queryItems = (components.queryItems ?? []) + additions
        return components.url ?? url
    }
}

/// Google issues a refresh token only when the authorization request asks for
/// offline access, and re-issues one only when consent is re-shown. Without
/// both, a Gmail connection dies with its first access token — about an hour —
/// and every later tool call reopens the browser.
enum GoogleOfflineAccess {
    static let queryItems = [
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
    ]
}

/// Gmail's MCP server advertises, per tool, every scope that would satisfy it —
/// including `https://mail.google.com/`, which can permanently delete mail.
/// Taking the advertised set verbatim would request exactly that.
///
/// Cruxwing reads mail for meeting context and can create a follow-up draft.
/// `gmail.compose` is unavoidably a write- and send-capable Google credential,
/// even when Cruxwing invokes only draft tools. Broad mailbox and modify scopes
/// are refused; the action planner separately denies Gmail send tools and every
/// draft write remains behind the editable confirmation sheet.
struct GmailLeastPrivilegeOAuthScopeSelector: OAuthScopeSelecting {
    static let allowed: Set<String> = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.compose",
    ]

    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? {
        // Unlike Atlassian, an unhinted request does NOT fall back to the full
        // allowlist: whichever tool triggered the challenge named its scopes,
        // and asking for drafting rights to read a thread is not least
        // privilege. With no hint at all, read-only covers every read tool.
        let hinted: Set<String>
        if let challengeScope {
            hinted = Set(challengeScope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        } else if let scopesSupported {
            hinted = Set(scopesSupported)
        } else {
            return ["https://www.googleapis.com/auth/gmail.readonly"]
        }
        let selected = hinted.intersection(Self.allowed)
        return selected.isEmpty ? nil : selected
    }

    func parseScopeString(_ scope: String) -> Set<String> {
        Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    func serialize(_ scopes: Set<String>) -> String? {
        guard !scopes.isEmpty else { return nil }
        return scopes.sorted().joined(separator: " ")
    }
}

/// Google Analytics advertises `analytics` alongside `analytics.readonly`, and
/// plain `analytics` is READ-WRITE over the property: it can create and modify
/// GA configuration. A meeting co-pilot reads numbers to check a claim; it has no
/// business editing anyone's analytics setup, and a token that could is a token
/// worth stealing.
///
/// Same shape as the Gmail selector, and the same reason: the server tells you
/// every scope that would satisfy a tool, and the widest one always would.
struct GoogleAnalyticsLeastPrivilegeOAuthScopeSelector: OAuthScopeSelecting {
    static let allowed: Set<String> = [
        "https://www.googleapis.com/auth/analytics.readonly",
    ]

    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? {
        // No fallback to "whatever was offered". With one allowed scope the
        // intersection is the whole policy, and an unhinted request gets exactly
        // the read-only scope rather than the union of what the server suggested.
        let hinted: Set<String>
        if let challengeScope {
            hinted = parseScopeString(challengeScope)
        } else if let scopesSupported {
            hinted = Set(scopesSupported)
        } else {
            return Self.allowed
        }
        let selected = hinted.intersection(Self.allowed)
        // Nil rather than a guess: if the server ever stops offering the read-only
        // scope, failing to connect is correct — silently taking the write scope
        // is not.
        return selected.isEmpty ? nil : selected
    }

    func parseScopeString(_ scope: String) -> Set<String> {
        Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    func serialize(_ scopes: Set<String>) -> String? {
        guard !scopes.isEmpty else { return nil }
        return scopes.sorted().joined(separator: " ")
    }
}

/// Atlassian advertises every product permission together. Cruxwing requests
/// Jira/Confluence reads plus Jira issue creation (used only by the explicit
/// task-filing confirmation sheet), never Confluence/Compass/graph writes.
struct AtlassianLeastPrivilegeOAuthScopeSelector: OAuthScopeSelecting {
    static let allowed: Set<String> = [
        "read:me", "read:account", "offline_access", "email",
        "read:jira-work", "write:jira-work",
        "search:confluence", "read:confluence-user",
        "read:page:confluence", "read:comment:confluence",
        "read:space:confluence", "read:hierarchical-content:confluence",
    ]

    func selectScopes(challengeScope: String?, scopesSupported: [String]?) -> Set<String>? {
        let hinted: Set<String>
        if let challengeScope {
            hinted = parseScopeString(challengeScope)
        } else if let scopesSupported {
            hinted = Set(scopesSupported)
        } else {
            hinted = Self.allowed
        }
        let selected = hinted.intersection(Self.allowed)
        return selected.isEmpty ? nil : selected
    }

    func parseScopeString(_ scope: String) -> Set<String> {
        Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    func serialize(_ scopes: Set<String>) -> String? {
        guard !scopes.isEmpty else { return nil }
        return scopes.sorted().joined(separator: " ")
    }
}

/// Connects the app to work-app MCP servers (Notion, Fireflies, Linear, …).
///
/// One uniform, keyless flow for every app: the SDK discovers the server's
/// OAuth metadata (RFC 9728/8414), registers us as a public client on the fly
/// (RFC 7591 — no client secret to ship), runs authorization-code + PKCE via
/// the system browser with a loopback redirect, and persists the token in the
/// Keychain. Adding a new integration = one catalog line, or the user pastes a
/// custom server URL.
@MainActor
final class MCPConnectionManager: ObservableObject {
    /// Atlassian's 2026 `/authv2` resource uses a different authorization
    /// server/DCR registration. Version its Keychain namespace so an upgraded
    /// app never attempts the first request with an incompatible old client id.
    static let atlassianTokenStorageID = "atlassian-authv2"

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// A canceled connect is still unwinding. Keep the row non-actionable
        /// until that exact attempt exits; otherwise an immediate second click
        /// merely coalesces onto the canceled task and appears to do nothing.
        case disconnecting
        case connected(toolCount: Int)
        case failed(String)
    }

    /// Deterministic seam for connection-state/UI tests. Production always
    /// leaves this nil and uses the real MCP SDK/OAuth path. A test override
    /// returns only the advertised tools, deliberately creating no callable
    /// client, so it cannot contact or mutate a real connected app.
    typealias ConnectionAttemptOverride = (MCPServerDescriptor) async throws -> [Tool]
    /// Deterministic tool transport used by connector-boundary tests. Production
    /// leaves it nil and uses the MCP SDK client.
    typealias ToolCallOverride = (
        MCPServerDescriptor, String, [String: Value]?
    ) async throws -> String
    /// Deterministic suspension point for the teardown UI/race tests. Production
    /// leaves this nil and awaits the SDK client's disconnect operation.
    typealias DisconnectAttemptOverride = (MCPServerDescriptor) async -> Void

    @Published private(set) var states: [String: ConnectionState] = [:]
    @Published private(set) var customServers: [MCPServerDescriptor]
    /// Snapshot of servers with stored OAuth credentials. SwiftUI view bodies
    /// must never synchronously query Keychain: each probe creates an
    /// authentication context and performs XPC, which made recording layouts
    /// stall whenever unrelated observable state changed.
    @Published private(set) var authorizedServerIDs: Set<String>
    /// Monotonic invalidation trigger for prompt-workflow design and evidence
    /// caches. It changes after a verified capability appears/disappears and
    /// whenever connector/account identity may change. AppState observes it to
    /// rebuild every prompt button and discard its own short-lived source cache.
    @Published private(set) var capabilityRevision: UInt64 = 0

    /// Namespace for connected-app evidence. It advances synchronously before
    /// a connector reconnect/disconnect or Cruxwing account transition, so a
    /// lookup that started under the previous identity cannot be read by (or
    /// complete into) the next identity even if its network task is still live.
    private(set) var groundingCacheScope: UInt64 = 0

    private let tokenStore: KeychainStore
    private let defersTokenStoreAccess: Bool
    private let notificationCenter: NotificationCenter
    private let connectionAttemptOverride: ConnectionAttemptOverride?
    private let toolCallOverride: ToolCallOverride?
    private let disconnectAttemptOverride: DisconnectAttemptOverride?
    private let connectorTelemetry: ConnectorTelemetry
    private var accountContextObserver: NSObjectProtocol?
    private var clients: [String: Client] = [:]
    private var toolCache: [String: [Tool]] = [:]
    private var tokenStorages: [String: MCPKeychainTokenStorage] = [:]
    private var restoredTokenData: [String: Data] = [:]
    /// In-flight connects, so concurrent callers await ONE attempt instead of
    /// racing (the loser used to see a nil client and fail spuriously).
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var persistedAuthorizationLoadTask: Task<[String: Data], Never>?
    private var persistedAuthorizationLoaded = false
    /// Connect/disconnect actions can race the background startup scan. These
    /// overrides ensure a late snapshot never resurrects a disconnected app or
    /// hides one that just connected.
    private var authorizationOverrides: [String: Bool] = [:]
    /// Consecutive failed connection attempts, surfaced as the retry ordinal.
    private var connectionRetryCounts: [String: Int] = [:]

    init(tokenStore: KeychainStore = SystemKeychain.shared,
         deferTokenStoreAccess: Bool? = nil,
         notificationCenter: NotificationCenter = .default,
         connectionAttemptOverride: ConnectionAttemptOverride? = nil,
         toolCallOverride: ToolCallOverride? = nil,
         disconnectAttemptOverride: DisconnectAttemptOverride? = nil,
         connectorTelemetry: ConnectorTelemetry? = nil) {
        let customServers = Self.loadCustomServers()
        self.customServers = customServers
        self.tokenStore = tokenStore
        self.defersTokenStoreAccess = deferTokenStoreAccess ?? (tokenStore is SystemKeychain)
        self.notificationCenter = notificationCenter
        self.connectionAttemptOverride = connectionAttemptOverride
        self.toolCallOverride = toolCallOverride
        self.disconnectAttemptOverride = disconnectAttemptOverride
        self.connectorTelemetry = connectorTelemetry ?? .live
        self.authorizedServerIDs = []
        self.accountContextObserver = notificationCenter.addObserver(
            forName: .wheesprAccountContextChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // The callback is delivered on OperationQueue.main; express that
            // fact to Swift's actor checker so the namespace changes in the
            // same turn as the account notification.
            MainActor.assumeIsolated {
                self?.advanceGroundingCacheScope(publishCapabilityChange: true)
            }
        }
    }

    deinit {
        if let accountContextObserver {
            notificationCenter.removeObserver(accountContextObserver)
        }
    }

    /// Restore cached OAuth badges after the first window exists. The Keychain
    /// scan is deliberately detached from the main actor: a stale macOS ACL can
    /// otherwise block SwiftUI scene instantiation before any window/AX tree is
    /// available. Repeated appearances await the same task and never rescan.
    func loadPersistedAuthorization() async {
        guard !persistedAuthorizationLoaded else { return }

        let task: Task<[String: Data], Never>
        if let existing = persistedAuthorizationLoadTask {
            task = existing
        } else {
            let accounts = servers.map { server in
                (server.id, Self.tokenStorageID(for: server.id))
            }
            let store = tokenStore
            task = Task.detached(priority: .userInitiated) {
                var tokens: [String: Data] = [:]
                for (serverID, storageID) in accounts {
                    if let data = MCPKeychainTokenStorage.tokenData(
                        serverID: storageID, store: store) {
                        tokens[serverID] = data
                    }
                }
                // The unversioned account belonged to Atlassian's retired
                // resource. Never make the production restore wait for its
                // potentially stale ACL; test stores clean it synchronously.
                if store is SystemKeychain {
                    Task.detached(priority: .utility) {
                        MCPKeychainTokenStorage.clearToken(
                            serverID: "atlassian", store: store)
                    }
                } else {
                    MCPKeychainTokenStorage.clearToken(
                        serverID: "atlassian", store: store)
                }
                return tokens
            }
            persistedAuthorizationLoadTask = task
        }

        var restored = await task.value
        guard !persistedAuthorizationLoaded else { return }
        persistedAuthorizationLoaded = true
        persistedAuthorizationLoadTask = nil
        var restoredIDs = Set(restored.keys)
        for (serverID, isAuthorized) in authorizationOverrides {
            if isAuthorized {
                restoredIDs.insert(serverID)
            } else {
                restoredIDs.remove(serverID)
                restored[serverID] = nil
            }
        }
        restoredTokenData = restored
        for (serverID, data) in restored {
            tokenStorages[serverID]?.installInitialTokenDataIfUnmodified(data)
        }
        let changed = restoredIDs != authorizedServerIDs
        authorizedServerIDs = restoredIDs
        if changed { capabilityRevision &+= 1 }
    }

    /// Catalog (+ pre-registered apps whose credentials are configured) +
    /// user-added servers, in display order.
    var servers: [MCPServerDescriptor] {
        MCPCatalog.builtIn + MCPCatalog.preRegistered + customServers
    }

    /// Last good answer per connected-app query, plus the breaker that stops a
    /// failing server being dialled every tick. Keeps grounding usable while an
    /// app is down, rate-limited, or merely slow — see MCPResultCache.
    let groundingCache = MCPResultCache()

    func state(of id: String) -> ConnectionState { states[id] ?? .disconnected }

    func isConnected(_ id: String) -> Bool {
        if case .connected = state(of: id) { return true }
        return false
    }

    /// Servers with a live session this launch.
    var connectedServers: [MCPServerDescriptor] { servers.filter { isConnected($0.id) } }

    /// A token is cached from an earlier session (connect won't need a browser).
    func isAuthorized(_ id: String) -> Bool { authorizedServerIDs.contains(id) }

    func tools(for id: String) -> [Tool] { toolCache[id] ?? [] }

    /// Only read-shaped tools are eligible for the one-click context import.
    /// Keep this distinct from `tools(for:)`: explicit, confirmation-backed
    /// workflows still need write tools, but the import sheet never should.
    func importTools(for id: String) -> [Tool] {
        MCPImportToolPolicy.filter(tools(for: id))
    }

    // MARK: - Connect / disconnect

    func connect(_ server: MCPServerDescriptor) async {
        // A disconnect owns this provider until its old transport and token
        // writes have drained. Background grounding/import callers must fail
        // closed instead of opening a replacement connection that late cleanup
        // could erase.
        if case .disconnecting = state(of: server.id) { return }
        // Coalesce: a second caller awaits the in-flight attempt and then sees
        // its committed result, instead of returning early to a nil client.
        if let inflight = connectTasks[server.id] {
            await inflight.value
            return
        }
        let task = Task { await self.performConnect(server) }
        connectTasks[server.id] = task
        await task.value
        connectTasks[server.id] = nil
    }

    private func performConnect(_ server: MCPServerDescriptor) async {
        let telemetryStartedAt = connectorTelemetry.start()
        let telemetryContext = ConnectorTelemetryContext(
            requestID: connectorTelemetry.makeRequestID(),
            retryCount: connectionRetryCounts[server.id] ?? 0)
        // A reconnect may authorize a different provider account. Rotate before
        // the first await so no old answer can cross that identity boundary.
        advanceGroundingCacheScope(publishCapabilityChange: true)
        states[server.id] = .connecting
        if let connectionAttemptOverride {
            do {
                let tools = try await connectionAttemptOverride(server)
                // The same stale-completion rule as the SDK path: Cancel /
                // Disconnect marks the row first, and a late success cannot
                // resurrect it.
                guard state(of: server.id) == .connecting else { return }
                toolCache[server.id] = tools
                setAuthorized(true, serverID: server.id)
                states[server.id] = .connected(toolCount: tools.count)
                capabilityRevision &+= 1
                recordReconnectTelemetry(
                    server: server, context: telemetryContext,
                    status: .reconnectSucceeded, startedAt: telemetryStartedAt)
                connectionRetryCounts[server.id] = 0
            } catch {
                guard state(of: server.id) == .connecting else { return }
                recordReconnectFailureTelemetry(
                    server: server, error: error, context: telemetryContext,
                    startedAt: telemetryStartedAt)
                connectionRetryCounts[server.id] = telemetryContext.retryCount + 1
                handleFailure(server, error)
            }
            return
        }
        await waitForInitialAuthorizationRestore()
        // Disconnect may have raced while the bounded cold-restore grace was
        // running. Never open a browser after the user turned the app off.
        guard state(of: server.id) == .connecting else { return }
        do {
            let client = try await makeClient(for: server)
            do {
                let (tools, _) = try await client.listTools()
                // A disconnect may have raced in while we were connecting —
                // honor it instead of resurrecting the session.
                guard state(of: server.id) == .connecting else {
                    await client.disconnect()
                    // OAuth may have persisted a freshly-issued token after a
                    // racing disconnect queued its first clear. Queue another
                    // clear after the OAuth leg so the serial store order ends
                    // in the user's requested disconnected state.
                    clearStoredToken(for: server.id)
                    return
                }
                clients[server.id] = client
                toolCache[server.id] = tools
                setAuthorized(true, serverID: server.id)
                states[server.id] = .connected(toolCount: tools.count)
                capabilityRevision &+= 1
                recordReconnectTelemetry(
                    server: server, context: telemetryContext,
                    status: .reconnectSucceeded, startedAt: telemetryStartedAt)
                connectionRetryCounts[server.id] = 0
            } catch {
                // Don't leak a live connected client when listTools fails.
                await client.disconnect()
                guard state(of: server.id) == .connecting else {
                    clearStoredToken(for: server.id)
                    return
                }
                recordReconnectFailureTelemetry(
                    server: server, error: error, context: telemetryContext,
                    startedAt: telemetryStartedAt)
                connectionRetryCounts[server.id] = telemetryContext.retryCount + 1
                handleFailure(server, error)
            }
        } catch {
            guard state(of: server.id) == .connecting else {
                clearStoredToken(for: server.id)
                return
            }
            recordReconnectFailureTelemetry(
                server: server, error: error, context: telemetryContext,
                startedAt: telemetryStartedAt)
            connectionRetryCounts[server.id] = telemetryContext.retryCount + 1
            handleFailure(server, error)
        }
    }

    private func recordReconnectTelemetry(
        server: MCPServerDescriptor,
        context: ConnectorTelemetryContext,
        status: ConnectorTelemetryRecord.StatusCategory,
        startedAt: TimeInterval,
        retryEligible: Bool? = nil
    ) {
        connectorTelemetry.record(
            operation: .reconnect,
            server: server,
            context: context,
            status: status,
            startedAt: startedAt,
            retryEligible: retryEligible)
    }

    private func recordReconnectFailureTelemetry(
        server: MCPServerDescriptor,
        error: Error,
        context: ConnectorTelemetryContext,
        startedAt: TimeInterval
    ) {
        let failure = ConnectorTelemetryRecord.StatusCategory.classify(error)
        recordReconnectTelemetry(
            server: server,
            context: context,
            status: .reconnectFailed,
            startedAt: startedAt,
            retryEligible: failure.isRetryEligible)
    }

    /// Give the one-shot background Keychain scan a short chance to restore a
    /// refresh token before starting browser OAuth. Polling is intentional: it
    /// never awaits the Security XPC task itself, so a stuck login keychain can
    /// delay Connect by at most this bounded grace period.
    private func waitForInitialAuthorizationRestore() async {
        guard !persistedAuthorizationLoaded else { return }
        if persistedAuthorizationLoadTask == nil {
            Task { [weak self] in await self?.loadPersistedAuthorization() }
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !persistedAuthorizationLoaded, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Turn a connect error into a failed state — and for auth / session-binding
    /// failures, wipe the stored token FIRST so the next attempt re-registers
    /// and re-authorizes from a clean slate. The Keychain item carries the
    /// DCR-issued client id + refresh token, so clearing it forces fresh dynamic
    /// client registration + browser authorization. This breaks the recurring
    /// "session binding verification failed" loop where a stale registration
    /// keeps getting reused.
    private func handleFailure(_ server: MCPServerDescriptor, _ error: Error) {
        let message = Self.shortMessage(error)
        let hadAuthorization = authorizedServerIDs.contains(server.id)
        // Browser leg never completed (user parked on the provider's login or
        // an error page; our loopback listener timed out). Reset to a clean
        // slate and say what actually fixes it — the raw SDK wrapper
        // ("Internal error: Authorization flow failed: …") helps nobody.
        if message.localizedCaseInsensitiveContains("timed out") {
            clearStoredToken(for: server.id)
            setAuthorized(false, serverID: server.id)
            toolCache[server.id] = nil
            states[server.id] = .failed(
                "The browser sign-in didn't finish. Close any old \(server.name) authorization tabs, sign in at the service's site once, then connect again.")
            if hadAuthorization { capabilityRevision &+= 1 }
        } else if Self.isAuthFailure(error) {
            clearStoredToken(for: server.id)
            setAuthorized(false, serverID: server.id)
            toolCache[server.id] = nil
            states[server.id] = .failed("Sign-in couldn't be verified — connect again to re-authorize.")
            if hadAuthorization { capabilityRevision &+= 1 }
        } else {
            states[server.id] = .failed(message)
        }
    }

    /// Whether a failure looks like an auth / session-binding problem (the class
    /// a fresh browser re-authorization fixes) rather than a transient network
    /// blip — so a valid refreshable token survives an offline moment.
    private static func isAuthFailure(_ error: Error) -> Bool {
        if error is OAuthAuthorizationError { return true }
        let message = shortMessage(error).lowercased()
        let signals = [
            "session binding", "verification failed", "state mismatch", "missing state",
            "invalid_grant", "invalid grant", "invalid_client", "invalid client",
            "unauthorized", "forbidden", "access denied", "access_denied",
            "pkce", "redirect uri mismatch", "issuer mismatch"
        ]
        return signals.contains { message.contains($0) }
    }

    func disconnect(_ server: MCPServerDescriptor) async {
        // One teardown owns the terminal transition. A duplicate call must not
        // publish `.disconnected` while the first call is still awaiting the
        // old client, or Connect could race its final token clear.
        if case .disconnecting = state(of: server.id) { return }
        let wasUsable = isConnected(server.id) || isAuthorized(server.id)
        let inFlightConnect = connectTasks[server.id]
        // Mark the evidence namespace first. An in-flight call from the old
        // connection can still finish, but MCPGrounding validates this scope
        // before storing or returning its result.
        advanceGroundingCacheScope(publishCapabilityChange: false)
        // Mark first: an in-flight performConnect re-checks the state before
        // committing, so this can't be silently undone.
        // Teardown may suspend in the MCP transport even without an in-flight
        // connect. Never expose Connect until the old client, credentials, and
        // capability snapshot are all retired, or a rapid second click can be
        // erased by the late cleanup below.
        states[server.id] = .disconnecting
        inFlightConnect?.cancel()
        let client = clients.removeValue(forKey: server.id)
        toolCache[server.id] = nil
        clearStoredToken(for: server.id)
        setAuthorized(false, serverID: server.id)
        if wasUsable { capabilityRevision &+= 1 }
        if let disconnectAttemptOverride {
            await disconnectAttemptOverride(server)
        } else if let client {
            await client.disconnect()
        }
        if let inFlightConnect {
            // The SDK/override may finish after cancellation. Its stale-state
            // guards discard the completion; only then expose Connect again,
            // after the coalescing slot is known to be retired.
            await inFlightConnect.value
            connectTasks[server.id] = nil
        }
        // Clear again after all old async producers finish. OAuth/token refresh
        // may have persisted after the first clear; serial storage ordering now
        // guarantees the user's disconnect is the final mutation.
        clearStoredToken(for: server.id)
        states[server.id] = .disconnected
    }

    /// Call a tool and flatten its text content — the building block every
    /// feature (context import, brainstormer enrichment, …) consumes.
    func callToolText(server: MCPServerDescriptor, tool: String,
                      arguments: [String: Value]?,
                      requiredConnectionScope: UInt64? = nil,
                      telemetryContext suppliedContext: ConnectorTelemetryContext =
                          ConnectorTelemetryContext()) async throws -> String {
        var telemetryContext = suppliedContext
        if telemetryContext.requestID == nil {
            telemetryContext.requestID = connectorTelemetry.makeRequestID()
        }
        let telemetryStartedAt = connectorTelemetry.start()

        do {
            if let requiredConnectionScope {
                try requireReviewedConnection(
                    server, scope: requiredConnectionScope,
                    acceptsOverrideTransport: toolCallOverride != nil)
            }
            let text: String
            if let toolCallOverride {
                text = try await toolCallOverride(server, tool, arguments)
            } else {
                if clients[server.id] == nil {
                    // Read paths may silently reconnect. A confirmed write may
                    // not: reconnecting can select a different provider account
                    // than the one named in the preview the user approved.
                    guard requiredConnectionScope == nil else {
                        throw MCPConnectionError.reviewedConnectionChanged(server.name)
                    }
                    await connect(server)
                }
                if let requiredConnectionScope {
                    try requireReviewedConnection(
                        server, scope: requiredConnectionScope,
                        acceptsOverrideTransport: false)
                }
                guard let client = clients[server.id] else {
                    if case .failed(let message) = state(of: server.id) {
                        throw MCPConnectionError.notConnected(server.name, message)
                    }
                    throw MCPConnectionError.notConnected(server.name, nil)
                }
                let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
                text = content.compactMap { item -> String? in
                    if case .text(let text, _, _) = item { return text }
                    return nil
                }.joined(separator: "\n")
                if isError == true {
                    throw MCPConnectionError.toolFailed(
                        tool, text.isEmpty ? "unknown error" : String(text.prefix(300)))
                }
            }

            connectorTelemetry.record(
                operation: .toolCall,
                server: server,
                toolName: tool,
                context: telemetryContext,
                status: .success,
                startedAt: telemetryStartedAt)
            return text
        } catch {
            let status = ConnectorTelemetryRecord.StatusCategory.classify(error)
            connectorTelemetry.record(
                operation: .toolCall,
                server: server,
                toolName: tool,
                context: telemetryContext,
                status: status,
                startedAt: telemetryStartedAt)
            throw error
        }
    }

    /// Validate the exact connected-account namespace reviewed by a write
    /// confirmation. This is synchronous on MainActor: no disconnect/reconnect
    /// can interleave between the check and handing the request to the captured
    /// client transport.
    func requireReviewedConnection(_ server: MCPServerDescriptor,
                                   scope: UInt64,
                                   acceptsOverrideTransport: Bool = false) throws {
        guard groundingCacheScope == scope,
              isConnected(server.id),
              acceptsOverrideTransport || clients[server.id] != nil else {
            throw MCPConnectionError.reviewedConnectionChanged(server.name)
        }
    }

    /// Cache paths do not call a tool, so they report at the lookup boundary.
    /// Inputs are classifications/age only; neither the cache key nor its text
    /// value is accepted by this API.
    func recordConnectorCacheTelemetry(
        server: MCPServerDescriptor,
        toolName: String,
        requestID: String,
        result: ConnectorTelemetryRecord.CacheResult,
        age: TimeInterval?,
        retryCount: Int,
        status: ConnectorTelemetryRecord.StatusCategory = .success
    ) {
        let startedAt = connectorTelemetry.start()
        connectorTelemetry.record(
            operation: .cacheLookup,
            server: server,
            toolName: toolName,
            context: ConnectorTelemetryContext(
                requestID: requestID,
                cacheResult: result,
                cacheAgeMilliseconds: age.map { Int(($0 * 1_000).rounded()) },
                retryCount: retryCount),
            status: status,
            startedAt: startedAt)
    }

    func makeConnectorTelemetryRequestID() -> String {
        connectorTelemetry.makeRequestID()
    }

    /// Guarded execution path for the one-click import sheet. The policy is
    /// checked again here (not only while rendering the picker) so stale SwiftUI
    /// selection state or a future caller cannot invoke a write tool by name.
    func callImportToolText(server: MCPServerDescriptor, tool: Tool,
                            arguments: [String: Value]?) async throws -> String {
        guard MCPImportToolPolicy.isSafeForImport(tool) else {
            throw MCPConnectionError.unsafeImportTool(tool.name)
        }
        guard importTools(for: server.id).contains(where: { $0.name == tool.name }) else {
            throw MCPConnectionError.toolFailed(tool.name, "tool is no longer available for read-only import")
        }
        return try await callToolText(server: server, tool: tool.name, arguments: arguments)
    }

    // MARK: - Custom servers

    func addCustomServer(name: String, urlString: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return false }
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        customServers.append(MCPServerDescriptor(
            id: id, name: trimmedName, endpoint: url, symbol: "puzzlepiece.extension", isCustom: true))
        Self.saveCustomServers(customServers)
        return true
    }

    func removeCustomServer(id: String) {
        guard let server = customServers.first(where: { $0.id == id }) else { return }
        Task { await disconnect(server) }
        customServers.removeAll { $0.id == id }
        Self.saveCustomServers(customServers)
    }

    // MARK: - Plumbing

    /// Advances synchronously for isolation, then clears storage asynchronously
    /// for bounded memory. Scope validation is the security boundary; clearing
    /// is cleanup, so an old in-flight store arriving after `clear()` is still
    /// harmless and unreachable.
    private func advanceGroundingCacheScope(publishCapabilityChange: Bool) {
        groundingCacheScope &+= 1
        if publishCapabilityChange { capabilityRevision &+= 1 }
        let cache = groundingCache
        Task { await cache.clear() }
    }

    private func makeClient(for server: MCPServerDescriptor) async throws -> Client {
        // Random loopback port for DCR servers (the port only matters while the
        // browser flow runs); pre-registered servers (HubSpot) use their FIXED
        // port because their consoles validate exact redirect URIs.
        let port = server.fixedLoopbackPort ?? UInt16.random(in: 49500...64500)
        let tokenStorage: MCPKeychainTokenStorage
        if let existing = tokenStorages[server.id] {
            tokenStorage = existing
        } else {
            tokenStorage = MCPKeychainTokenStorage(
                serverID: Self.tokenStorageID(for: server.id),
                store: tokenStore,
                initialTokenData: restoredTokenData[server.id],
                defersStoreAccess: defersTokenStoreAccess)
            tokenStorages[server.id] = tokenStorage
        }
        let authentication: OAuthConfiguration.TokenEndpointAuthentication
        if let clientID = server.fixedClientID, let secret = server.fixedClientSecret {
            authentication = .clientSecretPost(clientID: clientID, clientSecret: secret)
        } else {
            // Restore the DCR-issued public client id alongside the refresh
            // token. Without this, a post-relaunch refresh is sent with an
            // empty client id and unnecessarily forces browser authorization.
            authentication = .none(clientID: tokenStorage.load()?.clientID ?? "")
        }
        let oauth = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: authentication,
            authorizationRedirectURI: URL(string: "http://127.0.0.1:\(port)/callback")!,
            clientName: "Cruxwing",
            authorizationDelegate: LoopbackAuthDelegate(
                port: port,
                // Both Google connectors need access_type=offline or the grant
                // dies with its first access token, about an hour in.
                extraQueryItems: ["gmail", "google-analytics"].contains(server.id)
                    ? GoogleOfflineAccess.queryItems : [])
        )
        let scopeSelector: any OAuthScopeSelecting
        switch server.id {
        case "atlassian": scopeSelector = AtlassianLeastPrivilegeOAuthScopeSelector()
        case "gmail":     scopeSelector = GmailLeastPrivilegeOAuthScopeSelector()
        case "google-analytics": scopeSelector = GoogleAnalyticsLeastPrivilegeOAuthScopeSelector()
        default:          scopeSelector = DefaultOAuthScopeSelector()
        }
        let authorizer = OAuthAuthorizer(
            configuration: oauth,
            tokenStorage: tokenStorage,
            scopeSelector: scopeSelector
        )
        let transport = HTTPClientTransport(
            endpoint: server.endpoint,
            streaming: true,
            authorizer: authorizer
        )
        let client = Client(name: "Cruxwing", version: "1.0.0")
        _ = try await client.connect(transport: transport)
        return client
    }

    static func tokenStorageID(for serverID: String) -> String {
        serverID == "atlassian" ? atlassianTokenStorageID : serverID
    }

    private func setAuthorized(_ isAuthorized: Bool, serverID: String) {
        authorizationOverrides[serverID] = isAuthorized
        if isAuthorized { authorizedServerIDs.insert(serverID) }
        else {
            authorizedServerIDs.remove(serverID)
            restoredTokenData[serverID] = nil
        }
    }

    /// Clear through the same memory-backed storage used by OAuth. Its serial
    /// persistence queue preserves save-then-disconnect ordering without ever
    /// making the MainActor wait for Security.framework.
    private func clearStoredToken(for serverID: String) {
        let storage: MCPKeychainTokenStorage
        if let existing = tokenStorages[serverID] {
            storage = existing
        } else {
            storage = MCPKeychainTokenStorage(
                serverID: Self.tokenStorageID(for: serverID),
                store: tokenStore,
                initialTokenData: restoredTokenData[serverID],
                defersStoreAccess: defersTokenStoreAccess)
            tokenStorages[serverID] = storage
        }
        storage.clear()
    }

    private static func shortMessage(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return String(message.prefix(200))
    }

    // MARK: - Custom server persistence (descriptors only — tokens live in Keychain)

    private static let customServersKey = "mcp.customServers"

    private static func loadCustomServers() -> [MCPServerDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: customServersKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServerDescriptor].self, from: data)) ?? []
    }

    private static func saveCustomServers(_ servers: [MCPServerDescriptor]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: customServersKey)
        }
    }
}

enum MCPConnectionError: LocalizedError {
    case notConnected(String, String?)
    case toolFailed(String, String)
    case unsafeImportTool(String)
    case reviewedConnectionChanged(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let name, let detail):
            return "Couldn't connect to \(name)\(detail.map { ": \($0)" } ?? "")."
        case .toolFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        case .unsafeImportTool(let tool):
            return "\(tool) can change connected-app data and isn't available for one-click import."
        case .reviewedConnectionChanged(let name):
            return "The \(name) account changed after this action was reviewed. Open the action again to confirm its destination."
        }
    }
}
