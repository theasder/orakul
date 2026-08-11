import Foundation

/// What the next prompt is likely to cost, in compute credits.
///
/// The rail used to warn "large input — extra credits" purely because the
/// estimated input crossed 6,000 tokens, saying nothing about the size of the
/// charge or the size of the balance. On a large balance that warning fires
/// constantly for a real cost of a few credits out of thousands, which trains
/// people to ignore it; on a small balance the same styling has to carry a
/// genuinely expensive prompt. A number the user can compare to their balance
/// does both jobs, and the balance decides the severity.
///
/// MIRROR of the server's `computeCreditsFor` (chat branch) in
/// `functions/tariffs.js`. The server always decides the real charge — this
/// only predicts it. `test/creditTariffMirror.test.js` fails if the two tables
/// drift apart.
enum CreditCostEstimate {
    /// Input tokens covered by a model's base credit charge.
    static let baselineInputTokens = 6_000
    /// Output ceiling covered by the base rate and the largest ceiling the
    /// managed gateway accepts. These mirror tariffs.js admission policy.
    static let baselineOutputTokens = 1_200
    static let maximumOutputTokens = 8_000
    static let minimumOutputTokens = 256
    /// One credit must cover at least the most expensive metered credit COGS.
    static let worstCaseCreditCostUSD = 0.0308
    static let visionCreditsPerImage = 5
    static let fallbackBaseCredits = 3

    /// Base credits per request, before input surcharge and images.
    static let baseCredits: [String: Int] = [
        "gpt-4o-mini": 1,
        "gpt-5.4-mini": 2,
        "claude-haiku-4-5": 2,
        "gemini-3.5-flash": 2,
        "gpt-5.4": 4,
        "claude-sonnet-5": 3,
        "kimi-k2.6": 2,
        "gpt-5.5": 7,
        "gpt-5.6-sol": 7,
        "claude-opus-5": 7,
        "gemini-3.1-pro-preview": 3,
        "deepseek-v4-pro": 1,
        "qwen3.7-max": 3,
        "glm-5.2": 2,
    ]

    /// USD per million input tokens, used for the above-baseline surcharge.
    static let inputPerMillion: [String: Double] = [
        "gpt-4o-mini": 0.15,
        "gpt-5.4-mini": 0.75,
        "claude-haiku-4-5": 1,
        "gemini-3.5-flash": 1.5,
        "gpt-5.4": 2.5,
        "claude-sonnet-5": 2,
        "kimi-k2.6": 0.95,
        "gpt-5.5": 5,
        "gpt-5.6-sol": 5,
        "claude-opus-5": 5,
        "gemini-3.1-pro-preview": 2,
        "deepseek-v4-pro": 0.435,
        "qwen3.7-max": 2.5,
        "glm-5.2": 1.4,
    ]

    /// USD per million output tokens. Output is normally the expensive side of
    /// the completion, so an explicit 8k answer must be in the preflight quote.
    static let outputPerMillion: [String: Double] = [
        "gpt-4o-mini": 0.6,
        "gpt-5.4-mini": 4.5,
        "claude-haiku-4-5": 5,
        "gemini-3.5-flash": 9,
        "gpt-5.4": 15,
        "claude-sonnet-5": 10,
        "kimi-k2.6": 4,
        "gpt-5.5": 30,
        "gpt-5.6-sol": 30,
        "claude-opus-5": 25,
        "gemini-3.1-pro-preview": 12,
        "deepseek-v4-pro": 0.87,
        "qwen3.7-max": 7.5,
        "glm-5.2": 4.4,
    ]

    /// Credits charged for input above the baseline. 1 credit ≈ 1 US cent of
    /// provider input cost, which is why a long prompt on a cheap model still
    /// rounds to a couple of credits.
    static func inputSurcharge(model: String, inputTokens: Int) -> Int {
        let excess = max(0, inputTokens - baselineInputTokens)
        guard excess > 0 else { return 0 }
        let perMillion = inputPerMillion[model] ?? 1
        return Int(ceil(Double(excess) * perMillion / 1_000_000 * 100))
    }

    static func normalizedOutputBudget(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return baselineOutputTokens }
        return min(max(requested, minimumOutputTokens), maximumOutputTokens)
    }

    /// Admission-time surcharge for a deliberately enlarged output ceiling.
    /// This mirrors tariffs.js exactly: reserve enough for the bounded worst
    /// case even when a streaming provider never reports final usage.
    static func outputBudgetSurcharge(model: String,
                                      maxOutputTokens: Int?,
                                      baseCredits: Int) -> Int {
        let outputTokens = normalizedOutputBudget(maxOutputTokens)
        guard outputTokens > baselineOutputTokens else { return 0 }
        let inputRate = inputPerMillion[model] ?? 1
        let outputRate = outputPerMillion[model] ?? 3
        let boundedCost = (
            Double(baselineInputTokens) * inputRate
            + Double(outputTokens) * outputRate
        ) / 1_000_000
        let creditsNeeded = Int(ceil(boundedCost / worstCaseCreditCostUSD))
        return max(0, creditsNeeded - baseCredits)
    }

    /// Predicted charge for one chat request.
    static func credits(model: String, inputTokens: Int, imageCount: Int = 0,
                        maxOutputTokens: Int? = nil) -> Int {
        let base = baseCredits[model] ?? fallbackBaseCredits
        let vision = min(max(imageCount, 0), 8) * visionCreditsPerImage
        return base
            + inputSurcharge(model: model, inputTokens: inputTokens)
            + outputBudgetSurcharge(
                model: model, maxOutputTokens: maxOutputTokens, baseCredits: base)
            + vision
    }

    /// How alarming this prompt should look — judged against what is left, not
    /// against a fixed token threshold.
    enum Severity {
        /// Comfortably affordable: state the price, do not raise an alarm.
        case routine
        /// A visible share of the remaining balance.
        case notable
        /// More than the balance can cover.
        case unaffordable
    }

    /// A prompt that eats this share of the remaining balance is worth noticing.
    static let notableShareOfRemaining = 0.10

    static func severity(credits: Int, remaining: Int?) -> Severity {
        // No balance to compare against (direct-key build, signed out, or the
        // balance call failed): a bare number is honest, an alarm is not.
        guard let remaining, remaining > 0 else { return .routine }
        if credits > remaining { return .unaffordable }
        return Double(credits) / Double(remaining) >= notableShareOfRemaining
            ? .notable : .routine
    }
}
