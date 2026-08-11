import Foundation
import MCP

/// Persists an MCP server's OAuth token in the Keychain (one item per server),
/// so users stay connected across launches. `OAuthAccessToken` is Codable and
/// carries the DCR-issued `clientID` + refresh token, which is exactly what
/// the authorizer needs to refresh after a restart.
///
/// The backing store is injectable (default: the real Keychain) so the
/// save/load/clear round-trip can be unit-tested with an in-memory fake.
final class MCPKeychainTokenStorage: TokenStorage, @unchecked Sendable {
    private let account: String
    private let store: KeychainStore
    private let defersStoreAccess: Bool
    private let lock = NSLock()
    private var cachedToken: OAuthAccessToken?
    private var cacheMutationRevision: UInt64 = 0
    private let persistenceQueue: DispatchQueue

    init(serverID: String, store: KeychainStore = SystemKeychain.shared,
         initialTokenData: Data? = nil, defersStoreAccess: Bool = false) {
        self.account = "mcp.token.\(serverID)"
        self.store = store
        self.defersStoreAccess = defersStoreAccess
        self.cachedToken = initialTokenData.flatMap(Self.decodeToken)
        self.persistenceQueue = DispatchQueue(
            label: "ai.wheespr.meetgpt.mcp-token.\(serverID)", qos: .utility)
    }

    private static func account(for serverID: String) -> String { "mcp.token.\(serverID)" }

    /// True when a token is cached for this server (used for UI hints only).
    static func hasToken(serverID: String, store: KeychainStore = SystemKeychain.shared) -> Bool {
        store.get(account(for: serverID)) != nil
    }

    static func clearToken(serverID: String, store: KeychainStore = SystemKeychain.shared) {
        store.delete(account(for: serverID))
    }

    static func tokenData(serverID: String, store: KeychainStore = SystemKeychain.shared) -> Data? {
        store.get(account(for: serverID))
    }

    private static func decodeToken(_ data: Data) -> OAuthAccessToken? {
        try? JSONDecoder().decode(OAuthAccessToken.self, from: data)
    }

    func save(_ token: OAuthAccessToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        guard defersStoreAccess else {
            store.set(data, for: account)
            return
        }
        lock.lock(); cachedToken = token; cacheMutationRevision &+= 1; lock.unlock()
        let store = store
        let account = account
        persistenceQueue.async { store.set(data, for: account) }
    }

    func load() -> OAuthAccessToken? {
        if defersStoreAccess {
            lock.lock(); defer { lock.unlock() }
            return cachedToken
        }
        guard let data = store.get(account) else { return nil }
        return Self.decodeToken(data)
    }

    func clear() {
        guard defersStoreAccess else {
            store.delete(account)
            return
        }
        lock.lock(); cachedToken = nil; cacheMutationRevision &+= 1; lock.unlock()
        let store = store
        let account = account
        persistenceQueue.async { store.delete(account) }
    }

    /// A cold startup scan may finish just after Connect created this storage.
    /// Adopt that restored token only if OAuth/disconnect has not mutated the
    /// cache in the meantime.
    @discardableResult
    func installInitialTokenDataIfUnmodified(_ data: Data) -> Bool {
        guard defersStoreAccess, let token = Self.decodeToken(data) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard cacheMutationRevision == 0, cachedToken == nil else { return false }
        cachedToken = token
        return true
    }

    /// Deterministic seam for unit tests of save/clear ordering. Production
    /// never waits on this queue from the MainActor.
    func waitForPendingPersistence() {
        persistenceQueue.sync {}
    }
}
