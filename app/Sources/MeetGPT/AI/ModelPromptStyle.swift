import Foundation

/// Per-model adaptation of the shared prompt.
///
/// Every Quick Prompt used to ship one wording for all thirteen catalog models,
/// and the same instruction does not land the same way on all of them: a long
/// multi-clause brief that a flagship follows precisely will cause a fast mini
/// model to drop sections, and the "work through it step by step" phrasing that
/// helps a mid-tier model makes a deliberating model narrate its reasoning
/// instead of answering.
///
/// Rebuilding all fifteen button prompts for each model would be 195 hand-kept
/// variants that drift the moment anyone edits one. Instead the shared prompt
/// stays the single source of what to produce, and this adds a short layer
/// saying HOW to produce it for the model actually running — one profile per
/// class of model, plus a nudge for the provider's known failure mode.
///
/// The layer is appended through `SystemInstructions.system(skills:)` like the
/// theme/role/skill layers, so it composes rather than competing with them.
enum ModelPromptStyle {

    /// What kind of instruction the model responds best to. Derived from the
    /// catalog's own capacity tiers rather than a separate hand-kept list, so a
    /// new model is classified the moment it is added.
    enum Profile: String, Equatable {
        /// Fast, small models (the free tier, and every background/audit call).
        /// They lose sections from long briefs, so the layer trims scope.
        case compact
        /// Mid-tier general models — the shared prompt already suits them.
        case frontier
        /// Premium flagships that deliberate internally. They need to be told
        /// NOT to show that work, or the answer arrives wrapped in commentary.
        case deliberate
    }

    static func profile(for model: LLMModel) -> Profile {
        switch model.minTier {
        case .free: return .compact
        case .pro: return .frontier
        default: return .deliberate
        }
    }

    /// The style layer for one model, or nil when nothing needs saying.
    static func guidance(for model: LLMModel) -> String? {
        let parts = [profileGuidance(profile(for: model)), providerGuidance(model.provider)]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "OUTPUT STYLE FOR THIS MODEL\n" + parts.joined(separator: "\n")
    }

    static func profileGuidance(_ profile: Profile) -> String? {
        switch profile {
        case .compact:
            // The measured failure of a small model on these prompts is dropped
            // sections, not wrong content — so protect the shape first.
            return """
            - Produce every section the request asks for, in the order asked. If \
            you are running short, shorten each section rather than dropping one.
            - Prefer short bullets over prose. No preamble, no restating the task.
            """
        case .frontier:
            return """
            - Answer directly. No preamble, no restating the task.
            """
        case .deliberate:
            return """
            - Answer directly. Do NOT narrate your reasoning, list your steps, or \
            explain how you approached the task — the reader wants the finding.
            - Depth belongs in the substance of each point, not in extra sections \
            or a longer answer.
            """
        }
    }

    /// One line per provider for its own characteristic slip on these prompts.
    static func providerGuidance(_ provider: LLMProvider) -> String? {
        switch provider {
        case .anthropic:
            return "- Use the exact section headings the request names, once each."
        case .google:
            return "- Follow the request literally; do not add sections it did not ask for."
        case .deepSeek, .qwen, .zhipu, .moonshot:
            // These default to their training language when a transcript is
            // mixed-language, which silently produces an answer the room cannot
            // read. The app already cares about this (see languageHint).
            return "- Write the answer in the language of the transcript, and keep "
                 + "section headings exactly as the request spells them."
        case .openAI:
            return nil
        }
    }
}
