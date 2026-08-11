import Foundation
import Testing
@testable import MeetGPT

/// Every Quick Prompt shipped one wording for all thirteen catalog models. The
/// same instruction does not land the same way on each: a long multi-clause
/// brief that a flagship follows precisely makes a fast mini model drop
/// sections, and a deliberating model wraps the answer in commentary unless told
/// not to.
///
/// Rather than 15 prompts × 13 models of hand-kept variants, the shared prompt
/// stays the single source of WHAT to produce and this layer says HOW, per class
/// of model. These tests pin the classification and the composition.
@Suite("Model prompt style")
struct ModelPromptStyleTests {

    private func model(_ id: String) -> LLMModel {
        LLMCatalog.model(id: id)!
    }

    @Test("models are classified by the catalog's own capacity tiers")
    func classifiesByTier() {
        // Free-tier models are the ones that drop sections from long briefs —
        // and they also serve every background/audit call.
        #expect(ModelPromptStyle.profile(for: model("gpt-5.4-mini")) == .compact)
        #expect(ModelPromptStyle.profile(for: model("gemini-3.5-flash")) == .compact)

        #expect(ModelPromptStyle.profile(for: model("gpt-5.4")) == .frontier)
        #expect(ModelPromptStyle.profile(for: model("claude-sonnet-5")) == .frontier)

        #expect(ModelPromptStyle.profile(for: model("gpt-5.5")) == .deliberate)
        #expect(ModelPromptStyle.profile(for: model("claude-opus-5")) == .deliberate)
        #expect(ModelPromptStyle.profile(for: model("deepseek-v4-pro")) == .deliberate)
    }

    @Test("a new catalog model is classified without touching this file")
    func everyCatalogModelIsCovered() {
        // The point of deriving from minTier: adding a model to the catalog
        // must not silently leave it unstyled.
        for candidate in LLMCatalog.all where candidate.id != LLMCatalog.autoID {
            #expect(ModelPromptStyle.guidance(for: candidate) != nil,
                    "\(candidate.id) produced no style layer")
        }
    }

    @Test("compact models are told to protect the shape, not the length")
    func compactProtectsSections() {
        let guidance = ModelPromptStyle.guidance(for: model("gpt-5.4-mini"))!
        // The measured failure is a dropped section, not wrong content.
        #expect(guidance.contains("shorten each section rather than dropping one"))
    }

    @Test("deliberating models are told not to narrate their reasoning")
    func deliberateSuppressesNarration() {
        let guidance = ModelPromptStyle.guidance(for: model("gpt-5.5"))!
        #expect(guidance.contains("Do NOT narrate your reasoning"))
        // ...and a compact model is NOT given that instruction, which would
        // waste its shorter attention on a problem it does not have.
        let compact = ModelPromptStyle.guidance(for: model("gpt-5.4-mini"))!
        #expect(!compact.contains("Do NOT narrate your reasoning"))
    }

    @Test("non-English-first providers are told to match the transcript language")
    func multilingualProvidersPinLanguage() {
        // Their characteristic slip on a mixed-language call is answering in
        // their training language — an answer the room cannot read.
        for id in ["deepseek-v4-pro", "qwen3.7-max", "glm-5.2", "kimi-k2.6"] {
            #expect(ModelPromptStyle.guidance(for: model(id))!
                .contains("language of the transcript"), "\(id) missing the language pin")
        }
        #expect(!ModelPromptStyle.guidance(for: model("gpt-5.4"))!
            .contains("language of the transcript"))
    }

    @Test("Anthropic gets the heading contract, OpenAI gets no provider line")
    func providerNudges() {
        #expect(ModelPromptStyle.guidance(for: model("claude-sonnet-5"))!
            .contains("exact section headings"))
        #expect(ModelPromptStyle.providerGuidance(.openAI) == nil)
    }

    @Test("the layer composes with the other prompt layers instead of replacing them")
    func composesWithOtherLayers() {
        let style = ModelPromptStyle.guidance(for: model("gpt-5.5"))
        let composed = SystemInstructions.system(skills: ["THEME LAYER", "ROLE LAYER", style])
        #expect(composed.contains("THEME LAYER"))
        #expect(composed.contains("ROLE LAYER"))
        #expect(composed.contains("OUTPUT STYLE FOR THIS MODEL"))
    }
}
