import Foundation
import os
import Security
import LocalAuthentication

/// A generic-password store, abstracted so token persistence can be unit-tested
/// with an in-memory fake instead of the real Keychain (which needs an unlocked
/// login keychain and is unavailable on headless CI).
protocol KeychainStore: Sendable {
    @discardableResult
    func set(_ data: Data, for account: String) -> Bool
    func get(_ account: String) -> Data?
    func delete(_ account: String)
}

/// The production store: one generic-password item per account key, under a
/// single service. Auth tokens belong here, not UserDefaults (world-readable on
/// disk there).
///
/// Important: the legacy service name `ai.wheespr.meetgpt` is intentionally
/// abandoned. Those rows carry per-signature ACLs that re-prompt
/// ("… wants to use ai.wheespr.meetgpt in your keychain") on every rebuild.
/// This store never reads or writes that service — querying it is what caused
/// the dialogs. Orphaned rows can be deleted once in Keychain Access.
struct SystemKeychain: KeychainStore {
    static let shared = SystemKeychain()
    private static let productionBundleIdentifier = "ai.orakul.desktop"
    /// Fresh namespace under the new service. Do not bump into the abandoned
    /// `ai.wheespr.meetgpt` rows — that reopens the ACL prompt loop.
    private static let accountVersion = "v1"
    /// New service on purpose. Dialogs named this string when the old ACL
    /// blocked access; keeping the old name would keep showing it.
    private static let service = "com.cruxwing.credentials"

    /// Which keychain backs this build.
    ///
    /// The data-protection keychain requires an `application-identifier`
    /// entitlement, and macOS only grants one to a build signed by a real team.
    /// A locally-signed development build has no team, so EVERY write returned
    /// `errSecMissingEntitlement` (-34018) — measured, not assumed. Integration
    /// tokens were therefore never stored at all: connecting an app worked for
    /// the session and was gone on the next launch, which reads as "the build
    /// removed my integrations".
    ///
    /// Development builds use the file-based keychain instead. Items there are
    /// keyed to the signing CERTIFICATE rather than the binary hash, so they
    /// survive a rebuild — verified by writing an item, re-signing a changed
    /// binary with the same cert, and reading it back without a prompt.
    /// Distribution builds keep the data-protection keychain, which is stronger
    /// and correctly entitled.
    ///
    /// Adding `keychain-access-groups` to the dev signature is NOT an
    /// alternative: without a team prefix the system rejects the entitlement and
    /// kills the process on launch.
    static var usesDataProtectionKeychain: Bool { !Config.isDevBuild }

    private let bundleIdentifier: String
    private let accountNamespace: String

    /// Dev builds: never let the FILE keychain raise its classic ACL dialog
    /// ("Cruxwing wants to use your confidential information stored in …").
    ///
    /// File-keychain items are ACL-keyed to the signing certificate. The one
    /// time the identity changes — e.g. a local dev cert replaced by Developer
    /// ID — every existing row stops trusting the binary and EVERY read throws
    /// that modal, several per launch. With interaction off, a mismatched row
    /// reads as `errSecInteractionNotAllowed` instead: the connector shows as
    /// disconnected, reconnecting rewrites the row under the current identity,
    /// and the dialog can never appear again. Deprecated API, deliberately:
    /// it is the only switch Apple ships for the classic keychain's UI, and
    /// the data-protection keychain used by dist builds never shows it.
    private static let interactionSuppressed: Bool = {
        guard !usesDataProtectionKeychain else { return true }
        // Resolved via dlsym on purpose. `SecKeychainSetUserInteractionAllowed`
        // is deprecated (the whole SecKeychain family is), but it remains the
        // only switch for the classic keychain's dialogs — there is no modern
        // replacement because the modern keychain has no such dialog. The
        // dynamic call keeps the build warning-clean without pretending the
        // dependency is not there.
        typealias SetInteractionAllowed = @convention(c) (DarwinBoolean) -> OSStatus
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "SecKeychainSetUserInteractionAllowed") else {
            return false
        }
        return unsafeBitCast(symbol, to: SetInteractionAllowed.self)(false) == errSecSuccess
    }()

    init(bundleIdentifier: String? = nil) {
        let bundleID = bundleIdentifier
            ?? Bundle.main.bundleIdentifier
            ?? Self.productionBundleIdentifier
        self.bundleIdentifier = bundleID
        accountNamespace = "\(Self.accountVersion).\(bundleID)"
        _ = Self.interactionSuppressed
    }

    static func versionedAccount(_ account: String, bundleIdentifier: String) -> String {
        "\(accountVersion).\(bundleIdentifier).\(account)"
    }

    /// Legacy `ai.wheespr.meetgpt` rows are never inspected — touching them
    /// is what triggers the keychain password dialog.
    static func allowsLegacyAccess(bundleIdentifier: String) -> Bool {
        false
    }

    private func versionedAccount(_ account: String) -> String {
        "\(accountNamespace).\(account)"
    }

    private func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Service, account and — critically — WHICH KEYCHAIN, for every query.
    ///
    /// The two keychains are separate stores: an item added with
    /// `kSecUseDataProtectionKeychain: false` is not found by a query that
    /// passes `true` (errSecItemNotFound). Reads and deletes used to hard-code
    /// `true` while writes followed `usesDataProtectionKeychain`, so on a dev
    /// build every token was written to the file keychain and then looked for in
    /// the data-protection one. Nothing was ever read back: the app relaunched
    /// signed out, with connected apps gone and the credits rail reporting
    /// "credits unavailable" — while Settings still showed the plan, which lives
    /// in UserDefaults. One builder now stamps the flag for all four paths so
    /// they cannot drift again.
    func query(account storedAccount: String,
               adding extras: [String: Any] = [:]) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: storedAccount,
            kSecUseDataProtectionKeychain as String: Self.usesDataProtectionKeychain
        ]
        query.merge(extras) { _, new in new }
        return query
    }

    private func baseQuery(account storedAccount: String) -> [String: Any] {
        // No kSecUseAuthenticationUI: deprecated since macOS 11, and redundant
        // beside the LAContext above — `interactionNotAllowed` is exactly what
        // the deprecation says to use instead.
        query(account: storedAccount, adding: [
            kSecUseAuthenticationContext as String: nonInteractiveContext()
        ])
    }

    private func insertAttributes(data: Data, account storedAccount: String) -> [String: Any] {
        query(account: storedAccount, adding: [
            kSecValueData as String: data,
            // Data-protection items key off the app identity without the classic
            // login-keychain ACL prompt that plagued `ai.wheespr.meetgpt`.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ])
    }

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        let storedAccount = versionedAccount(account)
        let query = baseQuery(account: storedAccount)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(insertAttributes(data: data, account: storedAccount) as CFDictionary, nil)
        } else if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            // Replace a stale row without prompting — Fail makes update/delete soft-fail.
            _ = SecItemDelete(query as CFDictionary)
            status = SecItemAdd(insertAttributes(data: data, account: storedAccount) as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.keychain.error("Keychain write failed for \(storedAccount, privacy: .public) — OSStatus \(status, privacy: .public)")
            return false
        }
        return true
    }

    func get(_ account: String) -> Data? {
        // Only the current service + namespace. Never probe `ai.wheespr.meetgpt`.
        getStored(versionedAccount(account))
    }

    private func getStored(_ storedAccount: String) -> Data? {
        let query = query(account: storedAccount, adding: [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: nonInteractiveContext()
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            // A row this binary is not allowed to read — written under a
            // previous signing identity. It can never become readable, so
            // remove it: the connector reads as disconnected, and the next
            // connect rewrites the row under the current identity.
            Log.keychain.error(
                "Keychain row \(storedAccount, privacy: .public) is ACL-blocked (OSStatus \(status, privacy: .public)) — deleting the orphan")
            _ = SecItemDelete(self.query(account: storedAccount) as CFDictionary)
            return nil
        }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(_ account: String) {
        let status = deleteStored(versionedAccount(account))
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.keychain.error(
                "Keychain delete failed for \(versionedAccount(account), privacy: .public) — OSStatus \(status, privacy: .public)")
        }
    }

    @discardableResult
    private func deleteStored(_ storedAccount: String) -> OSStatus {
        SecItemDelete(baseQuery(account: storedAccount) as CFDictionary)
    }
}

/// Static facade kept for existing call sites (Config's google/wheespr tokens).
/// Delegates to the production store; the protocol above is the seam tests use.
enum Keychain {
    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool { SystemKeychain.shared.set(data, for: account) }
    static func get(_ account: String) -> Data? { SystemKeychain.shared.get(account) }
    static func delete(_ account: String) { SystemKeychain.shared.delete(account) }
}
