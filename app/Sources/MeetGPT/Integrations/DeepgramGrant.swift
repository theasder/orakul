import Foundation

/// How a `DeepgramStreamer` authenticates its websocket.
enum DeepgramAuth {
    /// Operator/BYO key baked into the build. Bills the operator's own
    /// Deepgram account — Cruxwing credits are never charged.
    case key(String)
    /// Keyless dist path: a short-lived access token minted by our backend
    /// (`POST /api/transcription/deepgram-token`). Fetched fresh before every
    /// (re)connect — each grant re-checks the user's compute credits, so a
    /// capped user cannot open new live streams.
    case grant(() async throws -> String)

    /// Metered auth reports elapsed audio into the shared credit pool.
    var isMetered: Bool {
        if case .grant = self { return true }
        return false
    }

    /// Deepgram auth header values: permanent keys use the `Token` scheme,
    /// temporary grant tokens use `Bearer`.
    static func header(key: String) -> String { "Token \(key)" }
    static func header(grantToken: String) -> String { "Bearer \(grantToken)" }
}

/// Outcome of one usage heartbeat (`POST /api/transcription/usage`).
enum DeepgramUsageVerdict: Equatable {
    case ok
    /// Credits exhausted — the stream must stop and the session degrade
    /// on-device. Carries the server's user-facing cap message.
    case capped(String)
    /// Transient failure (network, 5xx): keep streaming, keep the unreported
    /// delta, retry on the next heartbeat.
    case failed
}

/// Grant failures, split by whether a retry can help mid-session.
enum DeepgramGrantError: Error, Equatable {
    case signInRequired
    case creditCap(String)
    case notConfigured(String)
    case transient(Int)

    /// Terminal errors trigger the on-device fallback; transient ones reuse
    /// the streamer's normal reconnect backoff (a fresh token per attempt).
    var isTerminal: Bool {
        if case .transient = self { return false }
        return true
    }

    var fallbackMessage: String {
        switch self {
        case .signInRequired:
            return "Войти, чтобы использовать Deepgram по кредитам orakul."
        case .creditCap(let message), .notConfigured(let message):
            return message
        case .transient(let status):
            return "Deepgram token grant failed (\(status))."
        }
    }
}

/// Client for the backend's Deepgram credit-economy endpoints. The server's
/// Deepgram key never reaches the Mac; usage bills the same compute-credit
/// pool as AI at the engine's chunk rate.
enum DeepgramBackend {
    /// Map a grant response to an error (nil = success). Pure — unit-tested.
    static func classifyGrant(status: Int, message: String?) -> DeepgramGrantError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .signInRequired
        case 402, 429:
            return .creditCap(message ?? "Your compute credits are used up this period — continuing on-device.")
        case 503:
            return .notConfigured(message ?? "Deepgram live streaming is not available on this server.")
        default:
            return .transient(status)
        }
    }

    /// Mint a short-lived Deepgram access token (~60 s TTL, connect-time only).
    static func grantToken(session: URLSession = BackendPinning.shared,
                           tokenProvider: () async -> String? = { await WheesprAuth.validAccessToken() }
    ) async throws -> String {
        guard let base = backendRoot() else {
            throw DeepgramGrantError.notConfigured("Deepgram needs BACKEND_URL configured in this build.")
        }
        guard let wheesprToken = await tokenProvider(), !wheesprToken.isEmpty else {
            throw DeepgramGrantError.signInRequired
        }
        guard let url = URL(string: "\(base)/api/transcription/deepgram-token") else {
            throw DeepgramGrantError.notConfigured("Invalid BACKEND_URL for Deepgram.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(wheesprToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error = classifyGrant(status: status, message: errorMessage(from: data)) {
            throw error
        }
        struct Grant: Decodable { let accessToken: String }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: data),
              !grant.accessToken.isEmpty else {
            throw DeepgramGrantError.transient(status)
        }
        return grant.accessToken
    }

    /// Report elapsed streamed audio (6-second chunks) into the credit pool.
    /// Never throws — a heartbeat must not tear down a healthy stream.
    static func reportUsage(chunks: Int,
                            engine: String = "deepgram",
                            session: URLSession = BackendPinning.shared,
                            tokenProvider: () async -> String? = { await WheesprAuth.validAccessToken() }
    ) async -> DeepgramUsageVerdict {
        guard chunks > 0 else { return .ok }
        guard let base = backendRoot(),
              let url = URL(string: "\(base)/api/transcription/usage"),
              let wheesprToken = await tokenProvider(), !wheesprToken.isEmpty else {
            return .failed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(wheesprToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["engine": engine, "chunks": chunks])

        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            return .failed
        }
        switch status {
        case 200..<300:
            return .ok
        case 402, 429:
            return .capped(errorMessage(from: data)
                ?? "Your compute credits are used up this period — continuing on-device.")
        default:
            return .failed
        }
    }

    private static func backendRoot() -> String? {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String, !error.isEmpty else { return nil }
        return error
    }
}
