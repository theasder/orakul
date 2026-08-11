import Foundation
import Testing
import MCP
@testable import MeetGPT

/// A dictionary-backed KeychainStore for tests — no SecItem, no login keychain,
/// runs anywhere (incl. headless CI).
final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var reads = 0
    private var deletes = 0

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        lock.lock(); storage[account] = data; lock.unlock(); return true
    }
    func get(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return storage[account]
    }
    func delete(_ account: String) {
        lock.lock(); deletes += 1; storage[account] = nil; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return deletes }
}

final class BlockingReadKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool { true }
    func get(_ account: String) -> Data? {
        lock.lock(); started = true; lock.unlock()
        // A timeout prevents a MainActor regression from hanging the suite.
        // The test releases this immediately when the read is correctly
        // detached; an actor-blocking read can only return after the timeout.
        // 30 s, not 2 s: under a saturated parallel run the test's main-actor
        // hop between hasStarted and its assertion can exceed a small timeout,
        // marking the read finished early and failing falsely. A genuine
        // regression still fails — after one conspicuous 30 s stall.
        _ = releaseSemaphore.wait(timeout: .now() + 30)
        lock.lock(); finished = true; lock.unlock()
        return nil
    }
    func delete(_ account: String) {}
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func release() {
        // AppState restores Google and Wheespr independently.
        releaseSemaphore.signal()
        releaseSemaphore.signal()
    }
}

@Suite("Keychain token storage")
struct KeychainStorageTests {
    private func sampleToken(value: String = "tok-123") -> OAuthAccessToken {
        OAuthAccessToken(
            value: value,
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: ["mcp", "offline_access"],
            authorizationServer: URL(string: "https://app.attio.com"),
            refreshToken: "refresh-abc",
            clientID: "client-xyz"
        )
    }

    @Test("system Keychain accounts are versioned and QA-isolated")
    func systemNamespace() {
        let production = SystemKeychain.versionedAccount(
            "google.tokens", bundleIdentifier: "ai.orakul.desktop")
        let qa = SystemKeychain.versionedAccount(
            "google.tokens", bundleIdentifier: "ai.orakul.desktop.qa")

        #expect(production == "v1.ai.orakul.desktop.google.tokens")
        #expect(qa == "v1.ai.orakul.desktop.qa.google.tokens")
        #expect(production != qa)
        #expect(production != "google.tokens")
        #expect(!SystemKeychain.allowsLegacyAccess(bundleIdentifier: "ai.orakul.desktop"))
        #expect(!SystemKeychain.allowsLegacyAccess(bundleIdentifier: "ai.orakul.desktop.qa"))
        #expect(!SystemKeychain.allowsLegacyAccess(bundleIdentifier: "ai.orakul.desktop.dev"))
    }

    @Test("in-memory store round-trips set / get / delete and overwrites")
    func fakeBehaves() {
        let kc = InMemoryKeychain()
        #expect(kc.get("k") == nil)
        kc.set(Data("one".utf8), for: "k")
        #expect(kc.get("k") == Data("one".utf8))
        kc.set(Data("two".utf8), for: "k")   // overwrite
        #expect(kc.get("k") == Data("two".utf8))
        kc.delete("k")
        #expect(kc.get("k") == nil)
    }

    @Test("save then load round-trips every OAuthAccessToken field")
    func tokenRoundTrip() {
        let kc = InMemoryKeychain()
        let storage = MCPKeychainTokenStorage(serverID: "attio", store: kc)
        storage.save(sampleToken())

        let loaded = storage.load()
        #expect(loaded?.value == "tok-123")
        #expect(loaded?.tokenType == "Bearer")
        #expect(loaded?.refreshToken == "refresh-abc")
        #expect(loaded?.clientID == "client-xyz")
        #expect(loaded?.scopes == ["mcp", "offline_access"])
        #expect(loaded?.authorizationServer?.absoluteString == "https://app.attio.com")
        #expect(loaded?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("load returns nil when nothing is stored")
    func loadEmpty() {
        let storage = MCPKeychainTokenStorage(serverID: "notion", store: InMemoryKeychain())
        #expect(storage.load() == nil)
    }

    @Test("clear removes the stored token")
    func clearRemoves() {
        let kc = InMemoryKeychain()
        let storage = MCPKeychainTokenStorage(serverID: "linear", store: kc)
        storage.save(sampleToken())
        #expect(storage.load() != nil)
        storage.clear()
        #expect(storage.load() == nil)
    }

    @Test("hasToken / clearToken reflect and mutate presence under the server's account")
    func hasAndClearToken() {
        let kc = InMemoryKeychain()
        #expect(MCPKeychainTokenStorage.hasToken(serverID: "sentry", store: kc) == false)
        MCPKeychainTokenStorage(serverID: "sentry", store: kc).save(sampleToken())
        #expect(MCPKeychainTokenStorage.hasToken(serverID: "sentry", store: kc) == true)
        MCPKeychainTokenStorage.clearToken(serverID: "sentry", store: kc)
        #expect(MCPKeychainTokenStorage.hasToken(serverID: "sentry", store: kc) == false)
    }

    @Test("different server ids are isolated (distinct keychain accounts)")
    func serverIsolation() {
        let kc = InMemoryKeychain()
        MCPKeychainTokenStorage(serverID: "fireflies", store: kc).save(sampleToken(value: "ff"))
        let other = MCPKeychainTokenStorage(serverID: "asana", store: kc)
        #expect(other.load() == nil)
        #expect(MCPKeychainTokenStorage(serverID: "fireflies", store: kc).load()?.value == "ff")
        #expect(kc.count == 1)  // only fireflies wrote a row
    }

    @Test("corrupt stored bytes decode to nil instead of crashing")
    func corruptData() {
        let kc = InMemoryKeychain()
        kc.set(Data("not a token".utf8), for: "mcp.token.hubspot")
        #expect(MCPKeychainTokenStorage(serverID: "hubspot", store: kc).load() == nil)
    }

    @MainActor
    @Test("MCP authorization is snapshotted instead of probing Keychain during layout")
    func managerCachesAuthorization() async throws {
        let kc = InMemoryKeychain()
        let server = try #require(MCPCatalog.builtIn.first)
        kc.set(Data("cached-token".utf8), for: "mcp.token.\(server.id)")

        let manager = MCPConnectionManager(tokenStore: kc)
        #expect(kc.readCount == 0)
        #expect(kc.deleteCount == 0)
        #expect(!manager.isAuthorized(server.id))

        await manager.loadPersistedAuthorization()
        let initializationReads = kc.readCount
        #expect(initializationReads == manager.servers.count)
        #expect(kc.deleteCount == 1)
        #expect(manager.isAuthorized(server.id))

        for _ in 0..<20 {
            _ = manager.isAuthorized(server.id)
            _ = manager.researchableServers
        }
        #expect(kc.readCount == initializationReads)
        await manager.loadPersistedAuthorization()
        #expect(kc.readCount == initializationReads)

        let revision = manager.capabilityRevision
        await manager.disconnect(server)
        #expect(!manager.isAuthorized(server.id))
        #expect(kc.count == 0)
        #expect(manager.capabilityRevision == revision + 1)
    }

    @MainActor
    @Test("Atlassian authv2 ignores and removes the retired token namespace")
    func atlassianTokenMigration() async throws {
        let kc = InMemoryKeychain()
        let atlassian = try #require(MCPCatalog.builtIn.first { $0.id == "atlassian" })
        kc.set(Data("legacy-token".utf8), for: "mcp.token.atlassian")

        let migrated = MCPConnectionManager(tokenStore: kc)
        #expect(!migrated.isAuthorized(atlassian.id))
        #expect(kc.deleteCount == 0)
        await migrated.loadPersistedAuthorization()
        #expect(kc.get("mcp.token.atlassian") == nil)

        kc.set(Data("authv2-token".utf8),
               for: "mcp.token.\(MCPConnectionManager.atlassianTokenStorageID)")
        let current = MCPConnectionManager(tokenStore: kc)
        #expect(!current.isAuthorized(atlassian.id))
        await current.loadPersistedAuthorization()
        #expect(current.isAuthorized(atlassian.id))
    }

    @MainActor
    @Test("AppState restores account badges after construction without a synchronous Keychain read")
    func appStateDefersCredentialReads() async throws {
        let kc = InMemoryKeychain()
        let google = GoogleTokens(
            accessToken: "google-access",
            refreshToken: "google-refresh",
            expiry: Date(timeIntervalSince1970: 1_900_000_000))
        let session = WheesprSession(
            accessToken: "account-access",
            refreshToken: "account-refresh",
            accessExpiry: Date(timeIntervalSince1970: 1_900_000_000),
            email: "qa@example.com",
            displayName: "QA")
        kc.set(try JSONEncoder().encode(google), for: "google.tokens")
        kc.set(try JSONEncoder().encode(session), for: "wheespr.session")

        let state = AppState(
            llm: MockLLMGateway(response: ""),
            credentialStore: kc)
        #expect(kc.readCount == 0)
        #expect(!state.googleConnected)
        #expect(!state.wheesprConnected)

        await state.loadPersistedConnectionState()
        #expect(kc.readCount == 2)
        #expect(state.googleConnected)
        #expect(state.wheesprConnected)
        #expect(state.wheesprEmail == "qa@example.com")

        await state.loadPersistedConnectionState()
        #expect(kc.readCount == 2)
    }

    @MainActor
    @Test("slow credential restore never occupies the MainActor")
    func slowRestoreStaysOffMain() async {
        let kc = BlockingReadKeychain()
        let state = AppState(
            llm: MockLLMGateway(response: ""),
            credentialStore: kc)
        let load = Task { await state.loadPersistedConnectionState() }

        // REACHING this line is the assertion. A MainActor-isolated read would
        // hold the actor for the whole blocking `get`, so this main-actor task
        // could not resume to observe `hasStarted`, let alone run the statements
        // below — the test would sit until the fake store's timeout and then
        // fail. No separate expectation is needed, and the one that used to
        // live here (`#expect(!kc.hasFinished)`) asserted something else: that
        // the 30 s timeout had not yet elapsed. Under a saturated parallel run
        // it sometimes had, which failed a passing implementation.
        while !kc.hasStarted { await Task.yield() }
        state.googleConnecting = true
        #expect(state.googleConnecting)

        kc.release()
        await load.value
    }

    @Test("OAuth storage serves its restored cache without another store read")
    func deferredOAuthStorageUsesMemory() throws {
        let kc = InMemoryKeychain()
        let token = sampleToken()
        let data = try JSONEncoder().encode(token)
        let storage = MCPKeychainTokenStorage(
            serverID: "notion",
            store: kc,
            initialTokenData: data,
            defersStoreAccess: true)

        for _ in 0..<20 { #expect(storage.load()?.value == token.value) }
        #expect(kc.readCount == 0)
        storage.clear()
        #expect(storage.load() == nil)
        #expect(kc.readCount == 0)
        storage.waitForPendingPersistence()
        #expect(kc.count == 0)
    }

    @Test("a post-OAuth clear is the final persisted operation after disconnect")
    func deferredOAuthClearWinsRace() throws {
        let kc = InMemoryKeychain()
        let storage = MCPKeychainTokenStorage(
            serverID: "asana", store: kc,
            defersStoreAccess: true)

        storage.clear()                 // disconnect races the browser leg
        storage.save(sampleToken())     // OAuth completes after that clear
        storage.clear()                 // state guard clears once more
        storage.waitForPendingPersistence()

        #expect(storage.load() == nil)
        #expect(kc.count == 0)
    }

    @Test("late cold token hydrates only an untouched OAuth cache")
    func lateColdTokenHydrationIsGenerationGuarded() throws {
        let kc = InMemoryKeychain()
        let cold = try JSONEncoder().encode(sampleToken(value: "cold"))
        let storage = MCPKeychainTokenStorage(
            serverID: "linear", store: kc,
            defersStoreAccess: true)

        #expect(storage.installInitialTokenDataIfUnmodified(cold))
        #expect(storage.load()?.value == "cold")

        storage.save(sampleToken(value: "fresh-oauth"))
        #expect(!storage.installInitialTokenDataIfUnmodified(cold))
        #expect(storage.load()?.value == "fresh-oauth")
        storage.waitForPendingPersistence()
    }

    @Test("late startup restore cannot overwrite a newer credential mutation")
    func credentialCacheGenerationGuard() {
        let cache = CredentialMemoryCache()
        let initial = cache.revisions()
        let newer = WheesprSession(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            accessExpiry: .distantFuture,
            email: "new@example.com",
            displayName: nil)
        let stale = WheesprSession(
            accessToken: "stale-access",
            refreshToken: "stale-refresh",
            accessExpiry: .distantFuture,
            email: "stale@example.com",
            displayName: nil)

        cache.setWheesprSession(newer)
        #expect(!cache.installWheesprSession(stale, ifRevisionIs: initial.wheespr))
        #expect(cache.wheesprSession()?.email == "new@example.com")
    }

    @Test("Atlassian OAuth scopes keep confirmed Jira filing but exclude unrelated writes")
    func atlassianReadScopes() {
        let selector = AtlassianLeastPrivilegeOAuthScopeSelector()
        let selected = selector.selectScopes(
            challengeScope: nil,
            scopesSupported: [
                "offline_access", "read:jira-work", "write:jira-work",
                "search:confluence", "read:page:confluence", "write:page:confluence",
                "read:component:compass", "write:all:twg",
            ]) ?? []

        #expect(selected.contains("offline_access"))
        #expect(selected.contains("read:jira-work"))
        #expect(selected.contains("write:jira-work"))
        #expect(selected.contains("search:confluence"))
        #expect(selected.contains("read:page:confluence"))
        #expect(Set(selected.filter { $0.hasPrefix("write:") }) == ["write:jira-work"])
        #expect(!selected.contains("read:component:compass"))
    }
}
