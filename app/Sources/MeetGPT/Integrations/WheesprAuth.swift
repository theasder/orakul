import Foundation

enum WheesprAuthError: LocalizedError {
    case noBackend
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noBackend:               return "This build isn't connected to a backend yet — sign-in is unavailable."
        case .http(let code, let msg): return msg.isEmpty ? "Sign-in failed (\(code))." : msg
        case .badResponse:             return "The server returned an unexpected response."
        }
    }
}

/// Client for the wheespr backend auth contract (functions/auth/index.js): email
/// OTP sign-in, password/phone, native Apple/Google account exchange, token
/// refresh, and logout. Matches the backend's snake_case JSON.
enum WheesprAuth {
    /// Request a one-time code by email. No session yet.
    static func requestCode(email: String) async throws {
        _ = try await postRaw("/auth/email/start", body: ["email": email])
    }

    /// Verify the code and receive a session.
    static func verify(email: String, code: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/email/verify", body: ["email": email, "code": code])
        return try session(from: data, fallbackEmail: email)
    }

    /// Exchange a refresh token for a fresh session (rotates both tokens).
    static func refresh(refreshToken: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/session/refresh", body: ["refresh_token": refreshToken])
        return try session(from: data, fallbackEmail: "")
    }

    // MARK: Additional providers

    /// Email + password (register creates or claims an OTP-only account).
    static func registerPassword(email: String, password: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/password/register", body: ["email": email, "password": password])
        return try session(from: data, fallbackEmail: email)
    }

    static func loginPassword(email: String, password: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/password/login", body: ["email": email, "password": password])
        return try session(from: data, fallbackEmail: email)
    }

    /// Phone sign-in (SMS code via Twilio Verify on the backend).
    static func requestPhoneCode(phone: String) async throws {
        _ = try await postRaw("/auth/phone/start", body: ["phone": phone])
    }

    static func verifyPhone(phone: String, code: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/phone/verify", body: ["phone": phone, "code": code])
        return try session(from: data, fallbackEmail: phone)
    }

    /// Native Sign in with Apple — exchange the ASAuthorization identity token.
    static func loginAppleNative(idToken: String, nonce: String? = nil) async throws -> WheesprSession {
        var body: [String: Any] = ["id_token": idToken]
        if let nonce, !nonce.isEmpty { body["nonce"] = nonce }
        let data = try await postRaw("/auth/apple/native", body: body)
        return try session(from: data, fallbackEmail: "")
    }

    /// Native Google account login — exchange an OpenID id_token (not Calendar scopes).
    static func loginGoogleNative(idToken: String) async throws -> WheesprSession {
        let data = try await postRaw("/auth/google/native", body: ["id_token": idToken])
        return try session(from: data, fallbackEmail: "")
    }

    /// Best-effort server-side revocation — failures shouldn't block local sign-out.
    static func logout(refreshToken: String) async {
        _ = try? await postRaw("/auth/logout", body: ["refresh_token": refreshToken])
    }

    // MARK: Refresh-aware token access

    /// Shared in-flight refresh so concurrent callers coalesce into one request.
    /// This is the **single** refresh path for the Mac app (PaywallAPI, gateways,
    /// and AppState all call through here).
    @MainActor private static var inflightRefresh: Task<String?, Never>?

    /// Cancel any in-flight refresh (call on sign-out so a late result can't
    /// resurrect the session).
    @MainActor
    static func cancelInflightRefresh() {
        inflightRefresh?.cancel()
        inflightRefresh = nil
    }

    /// The current access token, transparently refreshed (and persisted) when
    /// expired. Nil when signed out or the refresh fails. A definitive 401
    /// clears the Keychain session and posts `.wheesprSessionExpired`.
    @MainActor
    static func validAccessToken() async -> String? {
        guard let session = Config.wheesprSession else { return nil }
        if !session.isAccessExpired { return session.accessToken }
        if let inflight = inflightRefresh { return await inflight.value }

        let expectedRefresh = session.refreshToken
        let task = Task<String?, Never> {
            do {
                let refreshed = try await refresh(refreshToken: expectedRefresh)
                // Don't resurrect a session that was signed out while refreshing.
                guard Config.wheesprSession?.refreshToken == expectedRefresh else { return nil }
                var updated = refreshed
                if updated.email.isEmpty { updated.email = session.email }
                Config.wheesprSession = updated
                return updated.accessToken
            } catch WheesprAuthError.http(let code, _) where code == 401 {
                // Refresh revoked/expired — clear storage and notify the UI.
                if Config.wheesprSession?.refreshToken == expectedRefresh {
                    Config.wheesprSession = nil
                    WheesprSessionNotifications.postExpired()
                }
                return nil
            } catch {
                return nil   // transient — keep the session, retry later
            }
        }
        inflightRefresh = task
        let token = await task.value
        if inflightRefresh == task { inflightRefresh = nil }
        return token
    }

    // MARK: Response shapes

    private struct TokenResponse: Decodable {
        struct UserDTO: Decodable { let email: String?; let displayName: String? }
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let user: UserDTO?
    }

    private static func session(from data: Data, fallbackEmail: String) throws -> WheesprSession {
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = r.access_token, !access.isEmpty,
              let refresh = r.refresh_token, !refresh.isEmpty else {
            throw WheesprAuthError.badResponse
        }
        return WheesprSession(
            accessToken: access,
            refreshToken: refresh,
            accessExpiry: Date().addingTimeInterval(r.expires_in ?? 900),
            email: r.user?.email ?? fallbackEmail,
            displayName: r.user?.displayName
        )
    }

    // MARK: Transport

    private static func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw WheesprAuthError.noBackend }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + path) else { throw WheesprAuthError.badResponse }
        // Never send tokens over cleartext: https only, except explicit localhost dev.
        let scheme = url.scheme?.lowercased()
        let isLocalhost = url.host == "localhost" || url.host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocalhost) else {
            throw WheesprAuthError.http(0, "Sign-in requires an https backend URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await BackendPinning.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WheesprAuthError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
            throw WheesprAuthError.http(http.statusCode, message)
        }
        return data
    }
}
