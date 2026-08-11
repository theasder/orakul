import Foundation

/// Rough size of the shared context available before a prompt button is
/// selected, by ingredient. The selected button still adds its request and
/// skill instructions. Chars/4 is a rough token approximation; this is a
/// preflight budget gauge, not a bill.
struct TokenEstimate: Equatable {
    /// The backend's fixed model/council credit already covers this much input.
    /// Longer input can add a model-aware credit surcharge. Keep this mirrored
    /// with `BASELINE_INPUT_TOKENS` in `functions/tariffs.js`.
    static let baseCreditInputTokens = 6_000

    /// Conservative connected-source allowance used by the global preflight
    /// bar. Individual prompt workflows can retrieve less, so the UI says
    /// "up to" rather than presenting this as an invoice.
    static let connectedSourceCharacterBudget = 3_000

    /// Transcript block (digest-aware — what buildUserMessage would send).
    var transcriptChars: Int = 0
    /// User-attached context (files + notes).
    var contextChars: Int = 0
    /// Grounding upper bound: active connected sources × per-source budget.
    var sourcesChars: Int = 0
    /// Shared system prompt: base instructions + theme/role layers. The selected
    /// button's request and skill layer are intentionally not known yet.
    var instructionsChars: Int = 0

    static func tokens(_ chars: Int) -> Int { chars <= 0 ? 0 : (chars + 3) / 4 }

    var transcriptTokens: Int { Self.tokens(transcriptChars) }
    var contextTokens: Int { Self.tokens(contextChars) }
    var sourcesTokens: Int { Self.tokens(sourcesChars) }
    var instructionsTokens: Int { Self.tokens(instructionsChars) }
    var totalTokens: Int { transcriptTokens + contextTokens + sourcesTokens + instructionsTokens }

    /// Input beyond the amount covered by a request's fixed credit price.
    var tokensAboveBaseCreditInput: Int {
        max(0, totalTokens - Self.baseCreditInputTokens)
    }

    /// Absolute fill for the budget rail. Unlike the old composition-only
    /// gauge, a small prompt now looks small relative to the 6k threshold.
    var baseCreditInputFraction: Double {
        min(1, Double(totalTokens) / Double(Self.baseCreditInputTokens))
    }

    /// Compact display: 980 → "980", 12_400 → "12.4k", 1_240_000 → "1.2M".
    static func label(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000:
            return "\(tokens)"
        case ..<1_000_000:
            let k = Double(tokens) / 1_000
            return k >= 100 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
        default:
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }
}
