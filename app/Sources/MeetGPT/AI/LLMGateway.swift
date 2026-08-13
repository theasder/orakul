import Foundation

/// Streams a chat completion and returns the full text. Token deltas are
/// delivered through `onDelta` as they arrive.
///
/// This is the single seam every AI call goes through. Today `LLMRouter`
/// dispatches directly to per-provider clients using build-time keys
/// (`Secrets`). When the managed backend lands, a `BackendGateway` can conform
/// to this same protocol and proxy calls per tier — no call site changes.
protocol LLMGateway {
    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String

    /// Same call, with an explicit ceiling on the model's OUTPUT tokens.
    ///
    /// Every path defaults to 1200 output tokens, which is ample for an answer
    /// and fatally small for the one feature that must emit a whole document:
    /// the Fireflies transcript merge returns the entire reconciled transcript
    /// as JSON, so it was truncated mid-object every time and failed to parse.
    /// Callers that genuinely produce long structured output raise it; nothing
    /// else pays for the bigger budget.
    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String

    /// Same call, naming the leading part of the message that is identical
    /// between consecutive calls of one session, so a provider with explicit
    /// prompt caching can put a breakpoint there.
    ///
    /// This is a REQUIREMENT, not an extension-only helper. Callers hold the
    /// gateway as an existential, and a protocol extension method that is not a
    /// requirement dispatches statically — every call would land on the default
    /// below and the router's override would never run, so the breakpoint would
    /// be silently dropped while looking perfectly wired.
    /// - Parameter onUsage: what the call actually cost, as the provider
    ///   reported it. Without it the cache is unfalsifiable: a breakpoint the
    ///   API ignored and one that worked look identical from here.
    func streamChat(system: String,
                    cachedPrefix: String,
                    volatileSuffix: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onUsage: ((TokenUsage) -> Void)?,
                    onDelta: @escaping (String) -> Void) async throws -> String
}

extension LLMGateway {
    func streamChat(system: String,
                    user: String,
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: [], model: model, onDelta: onDelta)
    }

    /// Default: ignore the ceiling. A gateway that cannot express one still
    /// answers rather than failing the call.
    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: images, model: model, onDelta: onDelta)
    }

    /// Same call, naming the leading part of the message that is identical
    /// between consecutive calls of one session, so a provider with explicit
    /// prompt caching can put a breakpoint there.
    ///
    /// Default: drop the hint and send the message whole. A gateway that cannot
    /// express a breakpoint — or a provider that caches prefixes automatically —
    /// still sends exactly the same bytes, so this is never a behaviour change,
    /// only a missed saving.
    func streamChat(system: String,
                    cachedPrefix: String,
                    volatileSuffix: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onUsage: ((TokenUsage) -> Void)? = nil,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        // No breakpoint and no usage: a gateway that cannot report either still
        // sends exactly the same bytes, so this is a missed saving, never a
        // behaviour change.
        try await streamChat(system: system, user: cachedPrefix + volatileSuffix,
                             images: images, model: model,
                             maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }

    func streamChat(system: String,
                    user: String,
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: [], model: model,
                             maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }
}

/// Dispatches to the concrete provider client based on `model.provider`.
final class LLMRouter: LLMGateway {
    private let openAI = OpenAIClient()
    private let anthropic = AnthropicClient()
    private let gemini = GeminiClient()
    /// Lazily-built clients for OpenAI-dialect providers (DeepSeek, Qwen, …).
    private var dialectClients: [LLMProvider: OpenAIClient] = [:]
    private let dialectLock = NSLock()

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
        switch model.provider {
        case .openAI:
            return try await openAI.streamChat(system: system, user: user, images: images, model: model.id, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        case .anthropic:
            return try await anthropic.streamChat(system: system, user: user, images: images, model: model.id, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        case .google:
            return try await gemini.streamChat(system: system, user: user, images: images, model: model.id, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        case .deepSeek, .qwen, .zhipu, .moonshot, .yandexGPT:
            return try await dialectClient(for: model.provider)
                .streamChat(system: system, user: user, images: images, model: model.id, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }
    }

    /// Anthropic is the one provider here with an EXPLICIT cache breakpoint, so
    /// it is the only one that needs the split. The others receive the same
    /// bytes: OpenAI matches prefixes automatically — which the stable-first
    /// ordering in `SystemInstructions` already serves — and the rest do not
    /// cache at all.
    func streamChat(system: String,
                    cachedPrefix: String,
                    volatileSuffix: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onUsage: ((TokenUsage) -> Void)?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        guard model.provider == .anthropic else {
            return try await streamChat(
                system: system, user: cachedPrefix + volatileSuffix, images: images,
                model: model, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }
        return try await anthropic.streamChat(
            system: system, user: volatileSuffix, images: images, model: model.id,
            maxOutputTokens: maxOutputTokens, cachedPrefix: cachedPrefix,
            onUsage: onUsage, onDelta: onDelta)
    }

    private func dialectClient(for provider: LLMProvider) -> OpenAIClient {
        dialectLock.lock(); defer { dialectLock.unlock() }
        if let client = dialectClients[provider] { return client }
        guard let dialect = provider.openAIDialect else {
            fatalError("Provider \(provider) has a native client — not OpenAI-dialect.")
        }
        let client = OpenAIClient(providerName: provider.label,
                                  endpoint: dialect.endpoint,
                                  keyProvider: dialect.key,
                                  modelIDTransform: dialect.modelID,
                                  extraHeaders: dialect.headers)
        dialectClients[provider] = client
        return client
    }
}

/// Sniffs an image's MIME type from its magic bytes, for base64 data URLs.
enum ImageMime {
    static func type(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49 { return "image/gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return "image/webp"
        }
        return "image/jpeg"
    }
}

/// Shared error for provider clients.
enum LLMError: LocalizedError {
    case missingKey(String)
    case http(String, Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            // Единственная ошибка, которую человек видит при первом же вопросе
            // в свежепоставленном приложении: ключей в установщике нет
            // намеренно. Прежний текст отправлял «войти в аккаунт, чтобы
            // пользоваться моделями» — совет для продукта с сервером, которого
            // у orakul нет. Здесь нужно назвать экран, а не диагноз.
            return "Нет ключа \(provider). Вставьте свой: «Настройки → ИИ → Ключи провайдеров» — "
                 + "там же написано, где его взять. Запись и поиск по звонкам работают и без ключа."
        case .http(let provider, let code, let body):
            // A gateway outage (the backend down or restarting) returns an nginx
            // ERROR PAGE, not a message — pasting "<html>…502 Bad Gateway…nginx"
            // at the user is leaky and useless. Say what they can actually do:
            // AI is down, recording and on-device transcription are not.
            if Self.isGatewayOutage(code: code, body: body) {
                return "AI features are temporarily unavailable — the service is down or restarting. "
                     + "Recording and on-device transcription still work; try AI again in a moment."
            }
            return "\(provider) API error (\(code)): \(Self.strippedMessage(body))"
        case .badResponse(let provider):
            return "\(provider) returned an invalid response."
        }
    }

    /// The error body with any HTML stripped and collapsed to one bounded line —
    /// so an accidental error page or long upstream dump never reaches the user
    /// raw, on ANY status code.
    static func strippedMessage(_ body: String) -> String {
        let noTags = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = noTags
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(200))
    }

    /// True when a 5xx is a GATEWAY page (backend down/restarting), not an app
    /// message. An app's own 503 ("metering unavailable, no credits spent") is
    /// informative and kept; nginx's "502 Bad Gateway" is boilerplate and replaced.
    static func isGatewayOutage(code: Int, body: String) -> Bool {
        guard code == 502 || code == 503 || code == 504 else { return false }
        let lower = strippedMessage(body).lowercased()
        if lower.isEmpty { return true }
        return lower.contains("bad gateway")
            || lower.contains("gateway time-out") || lower.contains("gateway timeout")
            || lower.contains("nginx")
            || (lower.contains("service temporarily unavailable") && lower.count < 60)
    }
}
