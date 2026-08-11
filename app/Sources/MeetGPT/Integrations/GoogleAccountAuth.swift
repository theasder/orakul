import CryptoKit
import Foundation

/// Native Google **account** login (openid / email / profile only).
/// Intentionally separate from `GoogleAuth` (Calendar/Docs/Sheets connector):
/// different scopes, no token persistence — the id_token is exchanged immediately
/// for a Cruxwing session via `POST /auth/google/native`.
@MainActor
final class GoogleAccountAuth {
    static let shared = GoogleAccountAuth()

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let accountScope = "openid email profile"

    private var activeLoopback: LoopbackRedirectServer?

    /// Run Desktop OAuth + PKCE and return the OpenID `id_token` (not persisted).
    func authorizeIDToken(clientID: String, clientSecret: String,
                          timeout: TimeInterval = 120) async throws -> String {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GoogleAuthError.missingClientID }
        guard clientID.hasSuffix(".apps.googleusercontent.com") else { throw GoogleAuthError.badClientID }
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
            .init(name: "scope", value: Self.accountScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
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

        if let errorCode = value("error") {
            throw GoogleAuthError.server(errorCode, value("error_description"))
        }
        guard value("state") == state else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code") else { throw GoogleAuthError.noCode }

        return try await Self.exchangeIDToken(
            code: code, verifier: verifier,
            clientID: clientID, clientSecret: clientSecret,
            redirectURI: redirectURI)
    }

    func cancel() {
        activeLoopback?.cancel()
    }

    private static func exchangeIDToken(
        code: String, verifier: String,
        clientID: String, clientSecret: String,
        redirectURI: String
    ) async throws -> String {
        let form = GoogleAuth.authorizationCodeTokenForm(
            clientID: clientID, clientSecret: clientSecret,
            code: code, verifier: verifier, redirectURI: redirectURI)
        guard let url = URL(string: tokenEndpoint) else { throw GoogleAuthError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let error = GoogleAuth.oauthError(from: data) { throw error }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GoogleAuthError.http(http.statusCode)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let idToken = json["id_token"] as? String, !idToken.isEmpty else {
            throw GoogleAuthError.server("missing_id_token", "Google did not return an OpenID id_token.")
        }
        return idToken
    }

    // MARK: PKCE helpers (same contract as GoogleAuth)

    private static func codeVerifier() -> String {
        randomState(length: 64)
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomState(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
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
