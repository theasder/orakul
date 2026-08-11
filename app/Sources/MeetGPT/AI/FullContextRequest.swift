import Foundation

/// Opt-in full-context mode: send the whole transcript and everything attached,
/// to models whose window can hold it.
///
/// **The default is untouched.** Per-tier ceilings stay exactly where they were,
/// because this is a deliberate spend and not a better default. A user who never
/// opts in sees no change in behaviour and no change in cost.
///
/// **Per request, never a setting.** A persistent switch would keep charging
/// after the one long call that justified it, and the person who turned it on in
/// March would not connect the bill in June to the toggle. It resets after every
/// send.
///
/// **Priced before the send.** The rules here mirror
/// `cruxwing-api/functions/fullContext.js` exactly, and `FullContextRequestTests`
/// checks the constants against the shared contract. A quoted price that differs
/// from what is charged is worse than not offering the mode at all, so the two
/// implementations are pinned to each other rather than merely written to match.
enum FullContextRequest {

    /// Chars per token. Deliberately LOW so the estimate errs high — quoting
    /// under and charging over is the failure that loses trust.
    static let charsPerToken = 3.5
    /// Below this a bigger window is a rounding difference sold as a feature.
    static let minimumContextTokens = 200_000
    /// Headroom for the system prompt, attached material and the answer.
    static let windowUtilisation = 0.75
    /// The ordinary input envelope, and the unit cost is quoted in.
    static let defaultEnvelopeChars = 8_000
    /// No attachment can produce an unbounded bill.
    static let maximumCreditMultiplier = 40

    /// Compute credits one ordinary request costs, by model.
    ///
    /// Mirrors `COMPUTE_CREDITS.models` in cruxwing-api/functions/tariffs.js.
    /// An unlisted model falls back to the server's own fallback rate rather
    /// than to 1: quoting cheap and charging more is the failure this whole
    /// module exists to avoid.
    static let baseCreditsByModel: [String: Int] = [
        "gpt-5.4-mini": 2, "gemini-3.5-flash": 2, "gpt-5.4": 4,
        "claude-sonnet-5": 3, "kimi-k2.6": 2, "gpt-5.5": 7, "gpt-5.6-sol": 7,
        "claude-opus-5": 7, "gemini-3.1-pro-preview": 3, "deepseek-v4-pro": 1,
        "qwen3.7-max": 3, "glm-5.2": 2,
    ]

    /// The server's fallback rate for a model it has no entry for.
    static let fallbackCredits = 3

    static func baseCredits(for model: LLMModel) -> Int {
        baseCreditsByModel[model.id] ?? fallbackCredits
    }

    /// Whether the mode may be offered for this model at all.
    ///
    /// About the MODEL, not the user. Tier gating is separate, because "your
    /// plan does not include this" and "this model cannot do this" are different
    /// messages and merging them produces the unhelpful one.
    static func isEligible(_ model: LLMModel) -> Bool {
        guard let tokens = model.contextTokens else { return false }
        return tokens >= minimumContextTokens
    }

    /// Largest input this model may be sent in full-context mode.
    ///
    /// Returns the ordinary envelope for an ineligible model rather than
    /// trapping, so a caller that forgets to check degrades to normal behaviour
    /// instead of building a request the provider will reject.
    static func maximumInputChars(for model: LLMModel) -> Int {
        guard isEligible(model), let tokens = model.contextTokens else {
            return defaultEnvelopeChars
        }
        return Int(Double(tokens) * windowUtilisation * charsPerToken)
    }

    /// Credits for one request, in whole envelopes, rounded up.
    ///
    /// The provider bills for tokens sent. A mode that quietly undercharges gets
    /// withdrawn later, which costs the user more than an honest price now.
    static func credits(baseCredits: Int, inputChars: Int) -> Int {
        let base = max(1, baseCredits)
        let chars = max(0, inputChars)
        let envelopes = max(1, Int(ceil(Double(chars) / Double(defaultEnvelopeChars))))
        return base * min(envelopes, maximumCreditMultiplier)
    }

    /// What the composer needs to show before sending.
    struct Quote: Equatable {
        /// Whether the mode would actually apply to this send.
        let active: Bool
        /// Why not, when it was asked for and refused. Nil when it applies or
        /// was never requested — a refusal must be stated, because silently
        /// falling back would leave the user believing the whole transcript went.
        let refusal: String?
        let limitChars: Int
        let credits: Int
        /// True when even the larger envelope cannot hold everything.
        let truncated: Bool

        /// One line for the composer. Names the price and the size, because the
        /// decision is "is this worth N credits", and neither number alone
        /// answers it.
        var summary: String {
            if let refusal { return refusal }
            guard active else { return "" }
            let thousands = limitChars / 1_000
            return truncated
                ? "Full context · \(credits) credits · sending the last \(thousands)k characters"
                : "Full context · \(credits) credits · sending everything"
        }
    }

    static func quote(model: LLMModel,
                      requested: Bool,
                      inputChars: Int,
                      baseCredits: Int) -> Quote {
        guard requested else {
            return Quote(active: false, refusal: nil,
                         limitChars: defaultEnvelopeChars, credits: max(1, baseCredits),
                         truncated: inputChars > defaultEnvelopeChars)
        }
        guard isEligible(model) else {
            return Quote(
                active: false,
                refusal: model.contextTokens == nil
                    ? "\(model.label) has no verified context window, so full context isn’t offered for it."
                    : "\(model.label)’s context window is too small for full context.",
                limitChars: defaultEnvelopeChars,
                credits: max(1, baseCredits),
                truncated: inputChars > defaultEnvelopeChars)
        }
        let limit = maximumInputChars(for: model)
        // Price what will actually be SENT. Charging for material the window
        // cannot hold bills for tokens the provider never sees.
        let sent = min(inputChars, limit)
        return Quote(active: true, refusal: nil, limitChars: limit,
                     credits: credits(baseCredits: baseCredits, inputChars: sent),
                     truncated: inputChars > limit)
    }
}
