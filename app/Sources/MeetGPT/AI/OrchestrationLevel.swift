import Foundation

/// Price/power-tiered orchestration panels for "Auto" mode. Each level is a
/// multi-model COUNCIL: its member models each answer independently and the
/// CHAIRMAN model synthesizes one final answer (see EnsembleGateway). Levels are
/// gated by the user's tariff — richer panels cost N× per request, so they climb
/// with the plan:
///
///   Free     mini + Gemini Flash          · chaired by GPT-5.4 mini
///   Medium   Sonnet 5 + GPT-5.5 + Flash    · chaired by Claude Sonnet 5   (Pro)
///   Max      Opus 5 + Sol + Gemini Pro    · chaired by GPT-5.6 Sol     (Premium)
///   Ultra    + DeepSeek V4 Pro (4 members) · chaired by GPT-5.6 Sol     (Ultra)
///
/// Ultra used to differ from Max only by swapping Opus for Claude Fable as
/// chairman — 58% more credits for a synthesis by a model tuned for narrative
/// rather than analysis. It now earns its price with a WIDER panel: one more
/// independent perspective before the same chairman synthesises.
///
/// Chairman rule: the panel's strongest member chairs its own council. Member
/// ids are validated against LLMCatalog in tests so a panel can never name a
/// model that isn't served.
enum OrchestrationLevel: String, CaseIterable, Identifiable, Codable {
    case free, medium, max, ultra

    var id: String { rawValue }

    /// Selection sentinel stored in Config.selectedModelID, e.g. "orchestrate:max".
    var selectionID: String { "orchestrate:\(rawValue)" }

    static let selectionPrefix = "orchestrate:"

    /// Resolve a stored selection sentinel back to its level (nil if not one).
    static func from(selection: String) -> OrchestrationLevel? {
        guard selection.hasPrefix(selectionPrefix) else { return nil }
        return OrchestrationLevel(rawValue: String(selection.dropFirst(selectionPrefix.count)))
    }

    var label: String {
        switch self {
        case .free:   return "Free"
        case .medium: return "Medium"
        case .max:    return "Max"
        case .ultra:  return "Ultra"
        }
    }

    /// Shown under the label in the picker.
    var blurb: String {
        switch self {
        case .free:   return "Two fast models, reconciled"
        case .medium: return "Sonnet + GPT + Gemini panel"
        case .max:    return "Sol + Opus + Gemini Pro panel"
        case .ultra:  return "Sol + Opus + Gemini Pro + DeepSeek — widest council"
        }
    }

    /// The tariff a user must be on to run this level.
    var minTier: Tier {
        switch self {
        case .free:   return .free
        case .medium: return .pro
        case .max:    return .premium
        case .ultra:  return .ultra
        }
    }

    /// Panel members, weakest → strongest (the last is the chairman).
    var memberModelIDs: [String] {
        switch self {
        case .free:   return ["gemini-3.5-flash", "gpt-5.4-mini"]
        case .medium: return ["gemini-3.5-flash", "gpt-5.5", "claude-sonnet-5"]
        case .max:    return ["gemini-3.1-pro-preview", "claude-opus-5", "gpt-5.6-sol"]
        case .ultra:  return ["gemini-3.1-pro-preview", "deepseek-v4-pro", "claude-opus-5", "gpt-5.6-sol"]
        }
    }

    /// The synthesizer that reconciles the panel — its strongest member.
    var chairmanModelID: String { memberModelIDs.last ?? "gpt-5.4-mini" }

    /// Starting tariff charge for a baseline-sized prompt. Long prompts add a
    /// model-aware surcharge on the backend before the council runs.
    var computeCredits: Int {
        switch self {
        case .free:   return 5
        case .medium: return 15
        case .max:    return 24
        case .ultra:  return 38
        }
    }

    /// The highest orchestration level a tier may run.
    static func highest(for tier: Tier) -> OrchestrationLevel {
        allCases.last { $0.minTier.rank <= tier.rank } ?? .free
    }

    /// Levels a tier is allowed to pick (cheapest → richest).
    static func available(for tier: Tier) -> [OrchestrationLevel] {
        allCases.filter { $0.minTier.rank <= tier.rank }
    }
}
