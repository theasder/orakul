import Foundation

/// Client for the backend orchestration councils (`POST /api/orchestrate`).
/// Sends `{ level, system, user, maxOutputTokens? }`; the server fans out to the level's panel of
/// frontier models and STREAMS the chairman's synthesis back as SSE — the same
/// `data: {"delta":…}` … `[DONE]` contract as `/api/llm/chat`. Provider keys
/// stay server-side, so the councils work in the keyless launch build where the
/// client-side EnsembleGateway can't run.
enum OrchestrateService {
    /// Stream a council answer. `level` is an OrchestrationLevel rawValue
    /// (free/medium/max/ultra). Emits each delta through `onDelta`; returns the
    /// full synthesized text. Throws LLMError on a non-2xx (incl. the server's
    /// 403 tier gate) or a mid-stream failure.
    static func stream(level: String,
                       system: String,
                       user: String,
                       maxOutputTokens: Int? = nil,
                       baseURL: String = Config.backendBaseURL,
                       session: URLSession = BackendPinning.shared,
                       onDelta: @escaping (String) -> Void) async throws -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw LLMError.missingKey("Backend (BACKEND_URL)") }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(root)/api/orchestrate") else { throw LLMError.badResponse("Orchestrate") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180   // N members + chairman synthesis
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sign-in is required server-side (the council is expensive); a stale
        // token would 401 rather than silently downgrade.
        if let token = await WheesprAuth.validAccessToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var payload: [String: Any] = [
            "level": level, "system": system, "user": user,
        ]
        if let maxOutputTokens {
            payload["maxOutputTokens"] = OutputTokenBudget.clamp(maxOutputTokens)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse("Orchestrate") }
        guard (200..<300).contains(http.statusCode) else {
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            let message = Self.errorMessage(fromJSON: raw) ?? raw
            throw LLMError.http("Orchestrate", http.statusCode, String(message.prefix(300)))
        }

        var full = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = record["error"] as? String {
                throw LLMError.http("Orchestrate", 502, message)   // mid-stream upstream failure
            }
            if let delta = record["delta"] as? String, !delta.isEmpty {
                full += delta
                onDelta(delta)
            }
        }
        return full
    }

    private static func errorMessage(fromJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }
}
