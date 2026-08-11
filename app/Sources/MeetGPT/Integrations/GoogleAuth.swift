import CryptoKit
import Foundation

/// The Google services MeetGPT can be authorized for — user-selectable in
/// Settings, each mapping to one read-only OAuth scope.
enum GoogleService: String, CaseIterable, Identifiable {
    case calendar, docs, sheets, drive

    var id: String { rawValue }

    /// Services that can actually be granted right now.
    ///
    /// A case whose `scopeURLs` is empty is withdrawn — present so stored data
    /// still decodes, but never offered and never requested. Derived from the
    /// scopes rather than listed separately, so withdrawing one is a single
    /// edit and cannot leave the two out of step.
    static var requestable: [GoogleService] { allCases.filter { !$0.scopeURLs.isEmpty } }
    var label: String {
        switch self {
        case .calendar: return "Calendar"
        case .docs:     return "Docs"
        case .sheets:   return "Sheets"
        case .drive:    return "Drive"
        }
    }
    var scopeURLs: [String] {
        switch self {
        case .calendar:
            return ["https://www.googleapis.com/auth/calendar.readonly"]
        case .docs:
            return [
                // Reads a Doc BY ID — the one the user pasted or imported. It
                // does not search, which is why dropping drive.metadata.readonly
                // (below) cost the search path and not this one.
                "https://www.googleapis.com/auth/documents.readonly",
                // Least-privilege WRITE: create + manage only files THIS app
                // makes (e.g. exporting a call to a new Doc). Does NOT grant
                // access to the user's other Drive files.
                "https://www.googleapis.com/auth/drive.file",
            ]
        case .sheets:
            return [
                "https://www.googleapis.com/auth/spreadsheets.readonly",
                // Same least-privilege WRITE as Docs, for the reverse direction:
                // turning a table in an answer into a NEW spreadsheet. It lived
                // only under Docs, so a Sheets-only grant could read sheets and
                // create nothing — the export failed at Google with a 403 rather
                // than being hidden. Note this is `drive.file`, not
                // `.../auth/spreadsheets`: creating a sheet needs no access to
                // the ones the user already has.
                "https://www.googleapis.com/auth/drive.file",
            ]
        case .drive:
            // WITHDRAWN for the verification submission, not deleted.
            //
            // This was `drive.readonly` — read ANY file the user can see, so a
            // PDF spec or a .docx in the same folder became reachable where
            // Docs/Sheets search only ever matched their own two mime types.
            //
            // Google classes it as RESTRICTED, and it was the ONLY restricted
            // scope left in this client. Keeping it means a CASA Tier 2 security
            // assessment — paid, annual, months — before the consent screen can
            // go to production, for a capability with no users yet. Dropping it
            // leaves nothing above "sensitive", so the review is brand plus
            // scope justification.
            //
            // Returning [] rather than removing the case keeps saved workflows
            // and stored grants decodable. `requestable` is what filters it out
            // of the consent request and the Settings list, so nothing can grant
            // it while this is empty. To bring it back: restore the scope here,
            // bump `scopeVersion`, and file the restricted-scope submission.
            //
            // `drive.metadata.readonly` was NOT a substitute — it finds a file
            // but cannot read it, so the co-pilot would surface hits it is
            // unable to quote. It has since been dropped from Docs and Sheets
            // for its own reason: Google classes IT as restricted too, so
            // dropping drive.readonly alone did not clear CASA. The Google Cloud
            // console is the authority on this and lists it under "Your
            // restricted scopes"; the published tier tables are easy to misread.
            return []
        }
    }
}

/// OAuth tokens for Google APIs. Persisted via `Config`.
struct GoogleTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date

    /// Treat as expired a minute early to absorb clock skew, network latency,
    /// and request processing time near the boundary.
    var isExpired: Bool { Date() >= expiry.addingTimeInterval(-60) }
}

enum GoogleAuthError: LocalizedError {
    case missingClientID
    case missingClientSecret
    case badClientID
    case cancelled
    case noCode
    case stateMismatch
    case server(String, String?)   // OAuth error code + optional description
    case http(Int)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Add GOOGLE_CLIENT_ID for the Google Desktop OAuth client and rebuild Cruxwing."
        case .missingClientSecret: return "Add GOOGLE_CLIENT_SECRET for the same Google Desktop OAuth client and rebuild Cruxwing."
        case .badClientID:     return "That doesn't look like a Google OAuth client ID."
        case .cancelled:       return "Google sign-in was cancelled."
        case .noCode:          return "Google didn't return an authorization code."
        case .stateMismatch:   return "Google sign-in could not be verified (state mismatch). Please try again."
        case .server(let code, let desc):
            return desc.map { "Google: \($0)" } ?? "Google auth error: \(code)"
        case .http(let code):  return "Google auth responded \(code)."
        case .notConnected:    return "Connect Google Calendar first."
        }
    }
}

/// Native OAuth 2.0 + PKCE for a Google "Desktop app" client.
/// Google recommends a random loopback redirect for macOS desktop apps; the
/// local listener receives one callback and never binds beyond 127.0.0.1.
@MainActor
final class GoogleAuth {
    private struct TokenResult {
        let tokens: GoogleTokens
        let grantedScope: String?
    }

    /// The scope actually requested = only the services the user enabled in
    /// Settings (granular authorization: a disabled service is excluded from
    /// the grant itself, so the token can't touch it — enforced by Google).
    static var scope: String {
        let enabled = Config.googleEnabledServices
        let services = GoogleService.requestable.filter { enabled.contains($0.rawValue) }
        var scopes: [String] = []
        for service in (services.isEmpty ? [GoogleService.calendar] : services) {
            for scope in service.scopeURLs where !scopes.contains(scope) { scopes.append(scope) }
        }
        return scopes.joined(separator: " ")
    }

    /// Increment whenever the scope CATALOG gains a scope. Grants below this
    /// are stale. (Per-service checks use `Config.googleGrantedServices`.)
    /// v4: added drive.file to Docs so the app can CREATE a Doc from a call.
    /// v5: added the Drive service (drive.readonly) — reads files that are not
    ///     Docs or Sheets. Every existing grant must be re-consented, because a
    ///     token issued under v4 cannot read them however the UI is toggled.
    /// v6: added drive.file to Sheets so the app can CREATE a spreadsheet from a
    ///     table in an answer. A Sheets-only grant issued under v5 has no write
    ///     scope at all, and no per-service version exists to distinguish it, so
    ///     the catalog version is what forces the re-consent. Grants that also
    ///     included Docs already carry drive.file and reconnect to the same set.
    ///     Also WITHDREW every restricted scope: the Drive service
    ///     (drive.readonly) and drive.metadata.readonly from Docs and Sheets.
    ///     The bump matters twice over here: a v5 token still HOLDS the
    ///     restricted scope, and re-consenting is what actually drops it.
    static let scopeVersion = 6

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private var activeLoopback: LoopbackRedirectServer?

    // MARK: Authorize

    func authorize(clientID: String, clientSecret: String,
                   timeout: TimeInterval = 120) async throws -> GoogleTokens {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GoogleAuthError.missingClientID }
        guard clientID.hasSuffix(".apps.googleusercontent.com") else { throw GoogleAuthError.badClientID }
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        guard !prefix.isEmpty else { throw GoogleAuthError.badClientID }
        guard !clientSecret.isEmpty else { throw GoogleAuthError.missingClientSecret }

        let port = UInt16.random(in: 49500...64500)
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(verifier)
        let state = Self.randomState()

        var components = URLComponents(string: Self.authEndpoint)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else { throw GoogleAuthError.badClientID }

        let loopback = LoopbackRedirectServer(port: port)
        activeLoopback = loopback
        defer {
            if activeLoopback === loopback { activeLoopback = nil }
        }

        let callbackURL: URL
        do {
            callbackURL = try await loopback.run(opening: authURL, timeout: timeout)
        } catch LoopbackRedirectServer.LoopbackError.cancelled {
            throw GoogleAuthError.cancelled
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }

        // Surface an explicit denial / error from Google, and verify the
        // anti-CSRF state round-tripped before trusting the code.
        if let errorCode = value("error") {
            throw GoogleAuthError.server(errorCode, value("error_description"))
        }
        guard value("state") == state else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code") else { throw GoogleAuthError.noCode }

        let result = try await Self.exchange(code: code, verifier: verifier,
                                             clientID: clientID, clientSecret: clientSecret,
                                             redirectURI: redirectURI)
        // Google supports granular consent, so the user may grant only a subset
        // of the scopes requested above. Persist what the token response actually
        // granted rather than assuming the Settings selection was accepted.
        Config.googleGrantedServices = Self.servicesGranted(by: result.grantedScope)
        return result.tokens
    }

    func cancel() {
        activeLoopback?.cancel()
    }

    // MARK: Token exchange / refresh

    private static func exchange(code: String, verifier: String,
                                 clientID: String, clientSecret: String,
                                 redirectURI: String) async throws -> TokenResult {
        try await postToken(
            form: authorizationCodeTokenForm(
                clientID: clientID,
                clientSecret: clientSecret,
                code: code,
                verifier: verifier,
                redirectURI: redirectURI),
            existingRefresh: nil)
    }

    /// Returns a valid (refreshed if needed) token set, or throws.
    static func validTokens(clientID: String, clientSecret: String,
                            current: GoogleTokens?) async throws -> GoogleTokens {
        guard let current else { throw GoogleAuthError.notConnected }
        guard current.isExpired, let refresh = current.refreshToken else { return current }
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientSecret.isEmpty else { throw GoogleAuthError.missingClientSecret }
        return try await postToken(
            form: refreshTokenForm(
                clientID: clientID,
                clientSecret: clientSecret,
                refreshToken: refresh),
            existingRefresh: refresh).tokens
    }

    /// Pure form builders keep the Desktop credential present in both token
    /// paths and make that protocol contract testable without network calls.
    nonisolated static func authorizationCodeTokenForm(
        clientID: String, clientSecret: String, code: String,
        verifier: String, redirectURI: String
    ) -> [String: String] {
        [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
    }

    nonisolated static func refreshTokenForm(
        clientID: String, clientSecret: String, refreshToken: String
    ) -> [String: String] {
        [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
    }

    private static func postToken(form: [String: String], existingRefresh: String?) async throws -> TokenResult {
        guard let url = URL(string: tokenEndpoint) else { throw GoogleAuthError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // OAuth servers return the useful error code/description in the JSON
        // body on non-2xx responses. Parse it before falling back to HTTP status.
        if let error = Self.oauthError(from: data) { throw error }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GoogleAuthError.http(http.statusCode)
        }
        guard let accessToken = json["access_token"] as? String else { throw GoogleAuthError.http(0) }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        // Refresh responses omit refresh_token — keep the existing one.
        let refreshToken = (json["refresh_token"] as? String) ?? existingRefresh
        return TokenResult(
            tokens: GoogleTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiry: Date().addingTimeInterval(expiresIn)),
            grantedScope: json["scope"] as? String)
    }

    /// Extract a standards-shaped OAuth error from a token response body.
    /// Internal for focused tests; never includes tokens or request parameters.
    nonisolated static func oauthError(from data: Data) -> GoogleAuthError? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = json["error"] as? String else { return nil }
        return .server(code, json["error_description"] as? String)
    }

    /// Convert Google's space-delimited granted-scope response into the service
    /// ids used by workflow routing. Docs and Sheets each require both their
    /// content scope and Drive metadata scope, so a partial grant is not treated
    /// as a usable workflow connection.
    nonisolated static func servicesGranted(by scope: String?) -> Set<String> {
        let scopes = Set((scope ?? "").split(whereSeparator: \Character.isWhitespace).map(String.init))
        // `requestable`, not `allCases`: a withdrawn service has no scopes, and
        // the empty set is a subset of everything — it would report as granted
        // on every connect.
        return Set(GoogleService.requestable.compactMap { service in
            Set(service.scopeURLs).isSubset(of: scopes) ? service.rawValue : nil
        })
    }

    /// Best-effort server-side revocation of the refresh token (RFC 7009).
    /// Fire-and-forget — failures shouldn't block disconnect.
    static func revoke(refreshToken: String?) async {
        guard let token = refreshToken, !token.isEmpty,
              let url = URL(string: "https://oauth2.googleapis.com/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(formEncode(token))".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: PKCE helpers

    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
