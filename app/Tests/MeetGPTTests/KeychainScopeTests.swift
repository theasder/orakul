import Foundation
import Security
import Testing
@testable import MeetGPT

/// Reads and writes must address the SAME keychain.
///
/// macOS keeps two separate stores, and `kSecUseDataProtectionKeychain` chooses
/// between them. Writes followed `usesDataProtectionKeychain` (false on a dev
/// build) while reads and deletes hard-coded `true`, so a dev build saved every
/// token to the file keychain and then looked for it in the data-protection one:
/// the session was never read back, the app relaunched signed out, connected
/// apps disappeared, and the credits rail said "credits unavailable" while
/// Settings — reading UserDefaults — still showed the paid plan.
@Suite("Keychain scope")
struct KeychainScopeTests {
    private let store = SystemKeychain(bundleIdentifier: "ai.orakul.desktop.tests")

    private func scope(of query: [String: Any]) -> Bool? {
        query[kSecUseDataProtectionKeychain as String] as? Bool
    }

    @Test("every query names the keychain the build actually writes to")
    func queriesShareOneKeychain() {
        let plain = store.query(account: "wheespr.session")
        #expect(scope(of: plain) == SystemKeychain.usesDataProtectionKeychain)
    }

    @Test("extras cannot silently redirect a query to the other keychain")
    func extrasDoNotOverrideTheScope() {
        // Read and delete add their own keys on top of the shared base. Those
        // extras are exactly where the mismatched `true` used to live.
        let read = store.query(account: "wheespr.session", adding: [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ])
        #expect(scope(of: read) == SystemKeychain.usesDataProtectionKeychain)
        #expect(read[kSecReturnData as String] as? Bool == true)
    }

    @Test("the account is namespaced by version and bundle id")
    func accountIsNamespaced() {
        let account = SystemKeychain.versionedAccount(
            "wheespr.session", bundleIdentifier: "ai.orakul.desktop.tests")
        #expect(account == "v1.ai.orakul.desktop.tests.wheespr.session")
        #expect(store.query(account: account)[kSecAttrAccount as String] as? String == account)
    }

    @Test("a dev build uses the file keychain, a distribution build does not")
    func devBuildsUseTheFileKeychain() {
        // The reason the two stores diverge at all: a locally-signed build has
        // no team identifier, so every data-protection write fails with -34018.
        #expect(SystemKeychain.usesDataProtectionKeychain == !Config.isDevBuild)
    }
}
