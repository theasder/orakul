import Foundation

/// Streaming client for the Google Gemini API (Generative Language, SSE).
/// Emits token deltas through `onDelta` and resolves with the full text.
final class GeminiClient {
    private let session: URLSession
    private let keyProvider: () -> String

    /// Injected for the same reason as `AnthropicClient`: reading `Config` inline
    /// tied the SSE parser tests to the developer's `mac/.env`, so emptying the
    /// provider keys for the keyless build failed tests that never touched a key.
    init(session: URLSession = .shared,
         keyProvider: @escaping () -> String = { Config.googleAIAPIKey }) {
        self.session = session
        self.keyProvider = keyProvider
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data] = [],
                    model: String,
                    maxOutputTokens: Int? = nil,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let outputCap = OutputTokenBudget.clamp(maxOutputTokens)
        let apiKey = keyProvider()
        guard !apiKey.isEmpty else { throw LLMError.missingKey("Gemini") }

        var components = URLComponents(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        components.queryItems = [.init(name: "alt", value: "sse"), .init(name: "key", value: apiKey)]
        guard let url = components.url else { throw LLMError.badResponse("Gemini") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Multimodal: text first, then any images as inlineData blocks.
        var parts: [[String: Any]] = [["text": user]]
        for data in images {
            parts.append(["inlineData": ["mimeType": ImageMime.type(data),
                                         "data": data.base64EncodedString()]])
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": outputCap, "temperature": 0.7]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse("Gemini") }
        guard (200..<300).contains(http.statusCode) else {
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            throw LLMError.http("Gemini", http.statusCode, raw)
        }

        var full = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let delta = parseDelta(data) else { continue }
            full += delta
            onDelta(delta)
        }
        return full
    }

    /// Concatenate the text parts of the first candidate in a chunk.
    private func parseDelta(_ data: Data) -> String? {
        struct Chunk: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        let text = (chunk.candidates?.first?.content?.parts ?? [])
            .compactMap { $0.text }
            .joined()
        return text.isEmpty ? nil : text
    }
}
