import Foundation

/// Recognises the server's "pool exhausted" rejection so the app can LATCH it.
///
/// Every metered route answers an exhausted pool with HTTP 429 and a
/// user-facing sentence in a JSON envelope. The background watch loops used to
/// swallow that with `try?` and re-dial every cadence for the rest of the call
/// — reported as "after credits were over, blind spots were still working":
/// nothing stopped, nothing was surfaced, and the retries themselves kept the
/// backend busy saying no.
///
/// Only 429 latches. A 403 is a tier gate (a different feature of a different
/// plan), 5xx is an outage, and both deserve retries — an empty pool does not
/// refill mid-call.
enum CreditExhaustion {
    /// The user-facing message when `error` is a quota rejection, else nil.
    static func quotaMessage(from error: Error) -> String? {
        guard case LLMError.http(_, 429, let body) = error else { return nil }
        return unwrap(body) ?? "AI credits for this period are used up — upgrade or add credits to continue."
    }

    /// The server wraps the sentence as {"error": "...", "upgrade": true}; a
    /// banner must show the sentence, not the envelope.
    private static func unwrap(_ body: String) -> String? {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("{") ? nil : trimmed
    }
}
