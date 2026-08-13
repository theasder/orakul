import Foundation

/// Shared transport policy for every bespoke managed-backend request.
///
/// Brainstorm and Fact Check do not travel through `BackendGateway`, so keeping
/// authentication and the dev-tier preview inline in that class caused those
/// routes to silently exercise the account's real tier.  Centralising the
/// headers also keeps the safety property explicit: a distribution build gets
/// `nil` from `Config.devTierOverride`, and the server independently requires
/// its non-production opt-in before it honours the header.
enum ManagedBackendRequestPolicy {
    /// The managed background routes enforce a 70 s end-to-end server deadline.
    /// Twenty seconds of client headroom lets the server fail open on an
    /// optional judge pass, release a reservation, and return structured JSON
    /// before URLSession cancels the socket.
    static let backgroundRequestTimeout: TimeInterval = 90

    static func apply(to request: inout URLRequest,
                      bearerToken: String?,
                      devTierOverride: Tier? = Config.devTierOverride) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let devTierOverride {
            request.setValue(devTierOverride.rawValue, forHTTPHeaderField: "X-Dev-Tier")
        }
    }
}

/// Routes chat through the backend's managed LLM gateway (`/api/llm/chat`):
/// provider keys stay server-side and the tier→model policy is enforced by the
/// server, not client state. Selected by `LLM_GATEWAY=backend` in mac/.env.
///
/// Sends the wheespr Bearer when signed in (unlocks the account's tier and the
/// per-user rate budget); anonymous calls still work on the free tier.
final class BackendGateway: LLMGateway {
    private let session: URLSession
    private let baseURLOverride: String?
    private let requestTimeout: TimeInterval
    private let tokenProvider: () async -> String?

    /// Eight is also the tariff's vision-charge ceiling. Refusing an oversized
    /// request keeps the client from silently sending images it did not quote in
    /// the preflight cost and prevents an unbounded base64 body.
    static let maxImages = 8
    static let maxImageBytes = 20 * 1024 * 1024

    init(session: URLSession = BackendPinning.shared,
         baseURL: String? = nil,
         requestTimeout: TimeInterval = 120,
         tokenProvider: @escaping () async -> String? = { await WheesprAuth.validAccessToken() }) {
        self.session = session
        self.baseURLOverride = baseURL
        self.requestTimeout = max(0.01, requestTimeout)
        self.tokenProvider = tokenProvider
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: images, model: model,
                             maxOutputTokens: nil, onDelta: onDelta)
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let requestID = UUID().uuidString
        let startedAt = Date()
        Log.network.info(
            "event=backend_chat_prepare request_id=\(requestID, privacy: .public) model=\(model.id, privacy: .public) system_chars=\(system.count, privacy: .public) user_chars=\(user.count, privacy: .public) image_count=\(images.count, privacy: .public)")

        do {
            guard images.count <= Self.maxImages,
                  images.allSatisfy({ $0.count <= Self.maxImageBytes }) else {
                throw LLMError.http(
                    "Backend", 413,
                    "Attach at most \(Self.maxImages) images, each no larger than 20 MB.")
            }

            let configuredBase = baseURLOverride ?? Config.backendBaseURL
            let base = configuredBase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { throw LLMError.missingKey("Backend (BACKEND_URL)") }
            let root = base.hasSuffix("/") ? String(base.dropLast()) : base
            guard let url = URL(string: "\(root)/api/llm/chat"),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw LLMError.badResponse("Backend")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            // Refresh-aware: a stale stored token would be treated as anonymous by
            // the server (free tier + tiny rate bucket) — silent downgrade.
            ManagedBackendRequestPolicy.apply(
                to: &request, bearerToken: await tokenProvider())
            var payload: [String: Any] = [
                "model": model.id,
                "system": system,
                "user": user,
                "images": images.map { "data:\(ImageMime.type($0));base64,\($0.base64EncodedString())" },
            ]
            // Omitted unless raised, so the server keeps its own default for every
            // ordinary call. The server clamps this independently — the client is
            // asking, not deciding.
            if let maxOutputTokens {
                payload["maxOutputTokens"] = OutputTokenBudget.clamp(maxOutputTokens)
            }
            // Which co-pilot loop this is, when it is one. Absent for a user's own
            // prompt, which IS chat. The server validates the name and the model
            // before honouring it — this is a declaration, not a price.
            if let watch = CopilotBilling.watch {
                payload["feature"] = watch.rawValue
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            DevCallDiagnostics.shared.record(event: "backend_chat_request", fields: [
                "backendRequestID": requestID,
                "method": "POST",
                "host": url.host ?? "",
                "path": "/api/llm/chat",
                "requestBody": [
                    "model": model.id,
                    "provider": model.provider.rawValue,
                    "system": system,
                    "user": user,
                    "imageCount": images.count,
                    "maxOutputTokens": maxOutputTokens.map { $0 as Any } ?? NSNull(),
                    "feature": CopilotBilling.watch.map { $0.rawValue as Any } ?? NSNull(),
                ],
            ])

            Log.network.info(
                "event=backend_chat_start request_id=\(requestID, privacy: .public) method=POST host=\(url.host ?? "", privacy: .public) path=/api/llm/chat timeout_ms=\(Int(self.requestTimeout * 1_000), privacy: .public) body_bytes=\(request.httpBody?.count ?? 0, privacy: .public)")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse("Backend") }
            Log.network.info(
                "event=backend_chat_response request_id=\(requestID, privacy: .public) status=\(http.statusCode, privacy: .public)")
            guard (200..<300).contains(http.statusCode) else {
                var raw = ""
                for try await line in bytes.lines { raw += line + "\n" }
                let message = Self.errorMessage(fromJSON: raw) ?? raw
                throw LLMError.http("Backend", http.statusCode, String(message.prefix(300)))
            }

            var full = ""
            var deltaCount = 0
            var sawDone = false
            for try await rawLine in bytes.lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    sawDone = true
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let message = record["error"] as? String {
                    throw LLMError.http("Backend", 502, message)   // mid-stream upstream failure
                }
                // The server could not serve the requested model and answered with
                // another one. Consumed here so it can never be mistaken for answer
                // text. Its free-form body remains private in the unified log.
                if let notice = record["notice"] as? String, !notice.isEmpty {
                    DevCallDiagnostics.shared.record(event: "backend_chat_route_notice", fields: [
                        "backendRequestID": requestID,
                        "notice": notice,
                    ])
                    Log.network.info(
                        "event=backend_chat_notice request_id=\(requestID, privacy: .public) detail=\(notice, privacy: .private(mask: .hash))")
                    continue
                }
                if let delta = record["delta"] as? String, !delta.isEmpty {
                    full += delta
                    deltaCount += 1
                    onDelta(delta)
                }
            }
            // A clean TCP EOF is not proof that the model completed. Without
            // the server sentinel, a severed partial stream would otherwise be
            // archived and scored as a successful assistant answer.
            guard sawDone else { throw LLMError.badResponse("Backend") }
            Log.network.info(
                "event=backend_chat_complete request_id=\(requestID, privacy: .public) status=\(http.statusCode, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public) delta_count=\(deltaCount, privacy: .public) output_chars=\(full.count, privacy: .public)")
            DevCallDiagnostics.shared.record(event: "backend_chat_terminal", fields: [
                "backendRequestID": requestID,
                "status": http.statusCode,
                "outcome": "succeeded",
                "latencyMs": Self.elapsedMilliseconds(since: startedAt),
                "deltaCount": deltaCount,
                "response": full,
            ])
            return full
        } catch {
            Log.network.error(
                "event=backend_chat_failed request_id=\(requestID, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public) error_kind=\(Self.logKind(for: error), privacy: .public)")
            DevCallDiagnostics.shared.record(event: "backend_chat_terminal", fields: [
                "backendRequestID": requestID,
                "outcome": "failed",
                "latencyMs": Self.elapsedMilliseconds(since: startedAt),
                "errorKind": Self.logKind(for: error),
            ])
            // A connection-level failure to REACH the backend (offline, DNS,
            // refused, timeout) is, to the user, the same as a gateway outage: AI
            // is unavailable, local features are not. Re-map it onto that message
            // rather than surfacing Apple's generic "Could not connect to the
            // server". The raw error was already logged above, so telemetry keeps
            // the precise url_<code>; only the user-facing throw changes.
            if Self.isBackendUnreachable(error) {
                throw LLMError.http("Backend", 502, "Bad Gateway")
            }
            throw error
        }
    }

    /// A URLError that means the backend could not be reached at all — distinct
    /// from a cancellation (not an error to surface) or a reached-but-erroring
    /// server (already an LLMError.http with its own status).
    static func isBackendUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .resourceUnavailable, .cannotLoadFromNetwork, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func errorMessage(fromJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["error"] as? String { return message }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return object["message"] as? String
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    /// A bounded, non-content-bearing failure label for unified logs. Error
    /// descriptions can contain upstream response text, prompts, or account
    /// details and must never be logged as public network telemetry.
    private static func logKind(for error: Error) -> String {
        if let urlError = error as? URLError { return "url_\(urlError.code.rawValue)" }
        if case LLMError.http(_, let status, _) = error { return "http_\(status)" }
        if case LLMError.missingKey = error { return "configuration" }
        if case LLMError.badResponse = error { return "bad_response" }
        return "other"
    }
}

/// Picks how chat requests are served: direct provider clients (keys baked
/// into the app) or the backend's managed, tier-enforcing gateway.
enum LLMGatewayFactory {
    /// Куда пойдёт запрос. Отдельно от `make()`, чтобы это можно было
    /// проверить тестом: сам собранный конвейер обёрнут несколькими слоями и
    /// снаружи не разбирается, а ошибка именно здесь уже стоила установщика,
    /// который выглядел настроенным и не отвечал ни на что.
    enum Selection: Equatable { case ensemble, backend, direct }

    static var selection: Selection {
        if Config.llmViaEnsemble { return .ensemble }
        if Config.llmViaBackend { return .backend }
        return .direct
    }

    static func make() -> LLMGateway {
        let base: LLMGateway
        switch selection {
        case .ensemble: base = EnsembleGateway()
        case .backend:  base = BackendGateway()
        case .direct:   base = LLMRouter()
        }
        // The orchestrator is a pass-through unless the selected model is
        // "auto" — checked per request, so switching in Settings applies live.
        let orchestrated = AutoOrchestrator(inner: base)
        // The bounded read loop sits INSIDE the redactor: a tool result re-enters
        // the conversation as user text, and it must be filtered on its way out
        // like anything else. Outside, the second round trip would carry an
        // unredacted connector payload straight to the provider.
        let agentic = AgenticReadGateway(
            wrapping: orchestrated,
            executor: { await AgenticReadContext.shared.executor() },
            isRecording: { await AgenticReadContext.shared.isRecording() },
            onTurnComplete: { AgenticReadContext.shared.record($0) })
        // OUTERMOST, deliberately. Wrapping here means every branch above —
        // ensemble, backend, direct router — and every future one is filtered,
        // because this is the only place a gateway is constructed. Placing it
        // inside any branch would leave the others uncovered the moment someone
        // adds a fourth.
        return RedactingGateway(wrapping: agentic,
                                onRedaction: { OutboundRedactionLog.shared.record($0) })
    }
}
