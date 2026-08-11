import Foundation

/// Streaming client for the Anthropic Messages API (SSE).
/// Emits token deltas through `onDelta` and resolves with the full text.
final class AnthropicClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// What the last completed call cost. Read by diagnostics to check that the
    /// cache breakpoints are being honoured — an ignored breakpoint reports zero
    /// cache reads while looking, from the code, exactly like a working one.
    private(set) var lastUsage = TokenUsage()

    /// Assembles the request body, with cache breakpoints on the parts that do
    /// not change between calls.
    ///
    /// The system prompt is identical for a whole session — base instructions
    /// plus role and skill guidance — so it is always marked. A block below the
    /// minimum cacheable size is simply not cached by the API; marking it is
    /// harmless, which is why there is no size check here.
    ///
    /// Pure and static so the body can be asserted without a network call.
    static func requestBody(system: String,
                            user: String,
                            cachedPrefix: String?,
                            images: [Data],
                            model: String,
                            outputCap: Int) -> [String: Any] {
        var content: [[String: Any]] = []
        let stablePrefix = cachedPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stablePrefix, !stablePrefix.isEmpty {
            content.append([
                "type": "text",
                "text": cachedPrefix ?? "",
                "cache_control": ["type": "ephemeral"],
            ])
        }
        content.append(["type": "text", "text": user])

        // Multimodal: text first, then any images as base64 blocks.
        for data in images {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": ImageMime.type(data),
                    "data": data.base64EncodedString(),
                ],
            ])
        }

        // The system block is marked ONLY when the caller named a stable prefix,
        // which is how it says its prompt repeats. Marking is not free: a block
        // that is never read still bills its write at a premium, and several
        // callers rebuild their system prompt every pass — the agenda watch
        // rewrites it with the findings surfaced so far — so unconditional
        // marking would make those calls dearer, not cheaper.
        let systemField: Any = stablePrefix?.isEmpty == false
            ? [["type": "text", "text": system,
                "cache_control": ["type": "ephemeral"]]]
            : system

        return [
            "model": model,
            "max_tokens": outputCap,
            "stream": true,
            "system": systemField,
            "messages": [["role": "user", "content": content]],
        ]
    }
    private let session: URLSession
    private let keyProvider: () -> String

    /// The key is injected rather than read inline so behavior under a known key
    /// is testable. Reading `Config` directly made the parser tests depend on
    /// whatever happened to be in the developer's `mac/.env`, and they broke the
    /// day provider keys were emptied for the keyless build — see `OpenAIClient`,
    /// which already took this shape.
    init(session: URLSession = .shared,
         keyProvider: @escaping () -> String = { Config.anthropicAPIKey }) {
        self.session = session
        self.keyProvider = keyProvider
    }

    /// - Parameter cachedPrefix: the part of the user message that is identical
    ///   between consecutive calls of the same session — attached context,
    ///   connector evidence, the settled head of the transcript. It becomes its
    ///   own cache breakpoint; the rest stays uncached because it changes every
    ///   pass, and marking it would pay the write premium for nothing.
    func streamChat(system: String,
                    user: String,
                    images: [Data] = [],
                    model: String,
                    maxOutputTokens: Int? = nil,
                    cachedPrefix: String? = nil,
                    onUsage: ((TokenUsage) -> Void)? = nil,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        var streamUsage = TokenUsage()
        let outputCap = OutputTokenBudget.clamp(maxOutputTokens)
        let apiKey = keyProvider()
        guard !apiKey.isEmpty else { throw LLMError.missingKey("Anthropic") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = Self.requestBody(
            system: system, user: user, cachedPrefix: cachedPrefix,
            images: images, model: model, outputCap: outputCap)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse("Anthropic") }
        guard (200..<300).contains(http.statusCode) else {
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            throw LLMError.http("Anthropic", http.statusCode, raw)
        }

        var full = ""
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }   // ignore "event:" lines
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            // Usage rides its own events, so read it before deciding the line
            // held no text: message_start and message_delta carry the counts
            // that make prompt caching verifiable rather than merely intended.
            if let usage = TokenUsage.parse(data) {
                streamUsage.merge(usage)
            }
            guard let delta = parseDelta(data) else { continue }
            full += delta
            onDelta(delta)
        }
        lastUsage = streamUsage
        onUsage?(streamUsage)
        return full
    }

    /// Pull `delta.text` out of a `content_block_delta` event.
    private func parseDelta(_ data: Data) -> String? {
        struct Event: Decodable {
            let type: String
            struct Delta: Decodable { let text: String? }
            let delta: Delta?
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: data),
              event.type == "content_block_delta" else { return nil }
        return event.delta?.text
    }
}
