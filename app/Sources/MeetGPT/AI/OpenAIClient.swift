import Foundation

/// Streaming client for the OpenAI chat-completions dialect.
///
/// Every major Chinese provider (DeepSeek, Qwen/DashScope, Zhipu GLM,
/// Moonshot Kimi — endpoints live-probed) speaks this same dialect, so one
/// parameterized client covers OpenAI and all of them.
final class OpenAIClient {
    private let endpoint: URL
    private let providerName: String
    private let keyProvider: () -> String
    private let session: URLSession
    /// Как назвать модель в теле запроса. У большинства провайдеров — как есть;
    /// YandexGPT требует `gpt://<каталог>/<модель>/latest`, где каталог свой у
    /// каждого пользователя, поэтому подстановка живёт здесь, а не в каталоге
    /// моделей: там она была бы одинаковой для всех.
    private let modelIDTransform: (String) -> String
    /// Заголовки сверх Authorization и Content-Type. Яндексу нужен ещё
    /// `x-folder-id`.
    private let extraHeaders: () -> [String: String]

    /// Defaults to OpenAI proper; pass a base URL + key lookup for any
    /// OpenAI-compatible provider.
    init(session: URLSession = .shared,
         providerName: String = "OpenAI",
         endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
         keyProvider: @escaping () -> String = { Config.openAIAPIKey },
         modelIDTransform: @escaping (String) -> String = { $0 },
         extraHeaders: @escaping () -> [String: String] = { [:] }) {
        self.session = session
        self.providerName = providerName
        self.endpoint = endpoint
        self.keyProvider = keyProvider
        self.modelIDTransform = modelIDTransform
        self.extraHeaders = extraHeaders
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data] = [],
                    model: String,
                    maxOutputTokens: Int? = nil,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let outputCap = OutputTokenBudget.clamp(maxOutputTokens)
        let apiKey = keyProvider()
        guard !apiKey.isEmpty else { throw LLMError.missingKey(providerName) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in extraHeaders() {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // With images, the user message becomes multimodal content (vision).
        let userContent: Any
        if images.isEmpty {
            userContent = user
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": user]]
            for data in images {
                let url = "data:\(ImageMime.type(data));base64,\(data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            userContent = parts
        }

        var body: [String: Any] = [
            "model": modelIDTransform(model),
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": userContent]
            ]
        ]
        if model.hasPrefix("gpt-5") {
            body["max_completion_tokens"] = outputCap
        } else {
            body["max_tokens"] = outputCap
            body["temperature"] = 0.7
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: providerName, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            throw LLMError.http(providerName, http.statusCode, raw)
        }

        var full = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

            if let delta = parseDelta(data) {
                full += delta
                onDelta(delta)
            }
        }
        return full
    }

    private func parseDelta(_ data: Data) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
              let delta = chunk.choices.first?.delta.content else { return nil }
        return delta
    }
}
