import Foundation

/// What one provider call actually cost, as the provider reports it.
///
/// The app has always sized prompts by character-count estimates and never read
/// back what was spent. That is survivable for budgeting and fatal for prompt
/// caching: a breakpoint the API ignored — block under the minimum size, prefix
/// drifted by a byte, TTL expired between passes — is indistinguishable from one
/// that worked, unless something reads `cache_read_input_tokens`.
///
/// Reads and writes are kept apart on purpose. A cache write is billed above an
/// ordinary input token and a read well below one, so a single "cached tokens"
/// figure would hide both the saving and the waste.
struct TokenUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    /// Tokens written into the cache on this call — the ones billed at a premium.
    var cacheCreationTokens: Int
    /// Tokens served from an existing cache entry — the cheap ones.
    var cacheReadTokens: Int

    init(inputTokens: Int = 0,
         outputTokens: Int = 0,
         cacheCreationTokens: Int = 0,
         cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// Everything the model had to read, however it was billed.
    var totalInputTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    /// Share of the input that came from cache. Zero — not one — when there was
    /// no input at all: an empty call did not achieve a perfect hit rate.
    var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalInputTokens)
    }

    /// A stream reports input on `message_start` and final output on
    /// `message_delta`, so a later event must not erase an earlier one.
    mutating func merge(_ other: TokenUsage) {
        inputTokens = max(inputTokens, other.inputTokens)
        outputTokens = max(outputTokens, other.outputTokens)
        cacheCreationTokens = max(cacheCreationTokens, other.cacheCreationTokens)
        cacheReadTokens = max(cacheReadTokens, other.cacheReadTokens)
    }

    /// Pulls usage out of one SSE event, or nil when the event carries none.
    ///
    /// Both shapes are handled: `message_start` nests usage under `message`,
    /// `message_delta` puts it at the top level.
    static func parse(_ data: Data) -> TokenUsage? {
        struct Payload: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
            }
            struct Message: Decodable { let usage: Usage? }
            let message: Message?
            let usage: Usage?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let usage = payload.message?.usage ?? payload.usage else { return nil }
        return TokenUsage(
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0)
    }
}
