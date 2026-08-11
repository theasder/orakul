import Testing
import Foundation
@testable import MeetGPT

/// The tier-gated LLM catalog: tier ranking, per-model availability, the
/// two-tier (provider → version) selection helpers, fast-audit routing, and the
/// single-jurisdiction council presets. Availability of concrete providers
/// depends on which keys are baked into a given build, so these tests pin only
/// structural invariants that hold for every build config: tier monotonicity,
/// deterministic catalog ordering, the fast-audit mapping, and the product rule
/// that the China council is never offered as a preset.
@Suite("LLM catalog")
struct LLMCatalogTests {
    // MARK: Tier

    @Test("tier rank strictly orders free < pro < premium")
    func tierRankOrdering() {
        #expect(Tier.free.rank == 0)
        #expect(Tier.pro.rank == 1)
        #expect(Tier.premium.rank == 2)
        #expect(Tier.free.rank < Tier.pro.rank)
        #expect(Tier.pro.rank < Tier.premium.rank)
    }

    @Test("tier labels and CaseIterable order")
    func tierLabels() {
        #expect(Tier.free.label == "Free")
        #expect(Tier.pro.label == "Pro")
        #expect(Tier.premium.label == "Premium")
        #expect(Tier.ultra.label == "Ultra")
        #expect(Tier.allCases == [.free, .pro, .premium, .ultra])
        #expect(Tier.ultra.rank == 3)
        #expect(Tier.free.id == "free")
    }

    // MARK: LLMModel.isAvailable(for:)

    @Test("a model is available exactly when the tier meets its floor")
    func modelAvailability() {
        let proModel = LLMModel(id: "x", label: "X", provider: .openAI,
                                minTier: .pro, supportsVision: true)
        #expect(proModel.isAvailable(for: .free) == false)
        #expect(proModel.isAvailable(for: .pro) == true)
        #expect(proModel.isAvailable(for: .premium) == true)

        let freeModel = LLMModel(id: "y", label: "Y", provider: .google,
                                 minTier: .free, supportsVision: false)
        #expect(freeModel.isAvailable(for: .free) == true)

        let premiumModel = LLMModel(id: "z", label: "Z", provider: .anthropic,
                                    minTier: .premium, supportsVision: true)
        #expect(premiumModel.isAvailable(for: .pro) == false)
        #expect(premiumModel.isAvailable(for: .premium) == true)
    }

    // MARK: available(for:) monotonicity

    @Test("available(for:) grows monotonically with tier")
    func availableMonotonic() {
        let free = LLMCatalog.available(for: .free)
        let pro = LLMCatalog.available(for: .pro)
        let premium = LLMCatalog.available(for: .premium)

        // Each tier is a strict superset (by id) of the weaker one.
        let freeIDs = Set(free.map(\.id))
        let proIDs = Set(pro.map(\.id))
        let premiumIDs = Set(premium.map(\.id))
        #expect(freeIDs.isSubset(of: proIDs))
        #expect(proIDs.isSubset(of: premiumIDs))

        // Counts are non-decreasing, and premium is the whole catalog.
        #expect(free.count <= pro.count)
        #expect(pro.count <= premium.count)
        #expect(premium.count == LLMCatalog.all.count)

        // Every listed model actually clears its tier gate.
        for model in free { #expect(model.isAvailable(for: .free)) }
        for model in premium { #expect(model.isAvailable(for: .premium)) }
    }

    // MARK: defaultModel(for:)

    @Test("defaultModel is the first model the tier can use")
    func defaultModelPerTier() {
        // Free's first catalog entry is GPT-5.4 mini.
        #expect(LLMCatalog.defaultModel(for: .free).id == "gpt-5.4-mini")
        // Whatever tier, the default is always available for that tier.
        #expect(LLMCatalog.defaultModel(for: .pro).isAvailable(for: .pro))
        #expect(LLMCatalog.defaultModel(for: .premium).isAvailable(for: .premium))
        // It equals the first element of available(for:).
        #expect(LLMCatalog.defaultModel(for: .pro).id == LLMCatalog.available(for: .pro).first?.id)
    }

    // MARK: model(id:)

    @Test("model(id:) resolves known ids and returns nil otherwise")
    func modelLookup() {
        #expect(LLMCatalog.model(id: "gpt-5.4-mini")?.provider == .openAI)
        #expect(LLMCatalog.model(id: "claude-opus-5")?.minTier == .premium)
        #expect(LLMCatalog.model(id: "glm-5.2")?.provider == .zhipu)
        #expect(LLMCatalog.model(id: "does-not-exist") == nil)
        #expect(LLMCatalog.model(id: "") == nil)
        // The "auto" pseudo-model is a sentinel, not in the real catalog table.
        #expect(LLMCatalog.model(id: LLMCatalog.autoID) == nil)
    }

    // MARK: fastAudit(for:)

    @Test("auto and council selections audit with the cheapest fast model")
    func fastAuditAutoAndCouncil() {
        #expect(LLMCatalog.fastAudit(for: LLMCatalog.auto).id == "gpt-5.4-mini")

        let councilSelection = LLMModel(id: "council:us", label: "US Council",
                                        provider: .openAI, minTier: .free,
                                        supportsVision: false)
        #expect(LLMCatalog.fastAudit(for: councilSelection).id == "gpt-5.4-mini")
    }

    @Test("fastAudit maps a provider to its fast tier when one exists")
    func fastAuditProviderFastTier() {
        // OpenAI's fast tier is GPT-5.4 mini.
        let gpt55 = LLMCatalog.model(id: "gpt-5.5")!
        #expect(LLMCatalog.fastAudit(for: gpt55, managed: false).id == "gpt-5.4-mini")

        // Google's fast tier is Gemini Flash.
        let geminiPro = LLMCatalog.model(id: "gemini-3.1-pro-preview")!
        #expect(LLMCatalog.fastAudit(for: geminiPro, managed: false).id == "gemini-3.5-flash")
    }

    @Test("fastAudit returns the model itself when its provider has no fast tier")
    func fastAuditNoFastTier() {
        // Anthropic, DeepSeek, Qwen, Zhipu, Moonshot have no cheap fast entry.
        let sonnet = LLMCatalog.model(id: "claude-sonnet-5")!
        #expect(LLMCatalog.fastAudit(for: sonnet, managed: false).id == sonnet.id)

        let deepseek = LLMCatalog.model(id: "deepseek-v4-pro")!
        #expect(LLMCatalog.fastAudit(for: deepseek, managed: false).id == deepseek.id)

        let kimi = LLMCatalog.model(id: "kimi-k2.6")!
        #expect(LLMCatalog.fastAudit(for: kimi, managed: false).id == kimi.id)
    }

    // MARK: fastAudit cost invariants (M7d — mechanical passes use the fast tier)
    //
    // Every mechanical pass (rhetoric/facilitation/digest/goal-suggest/refine
    // audit/follow-ups/grounding-query) routes its model through
    // `fastAudit(for: Config.selectedModel)`. These lock in that the function can
    // never make such a pass MORE expensive than the user's selected model — a
    // guarantee no future catalog edit can silently break.

    @Test("a mechanical pass NEVER escalates tier — fastAudit ≤ the selected model")
    func fastAuditNeverEscalatesTier() {
        // The core cost guarantee, asserted across the WHOLE catalog + Auto.
        for model in LLMCatalog.all + [LLMCatalog.auto] {
            let audited = LLMCatalog.fastAudit(for: model)
            #expect(audited.minTier.rank <= model.minTier.rank,
                    "fastAudit(\(model.id)) → \(audited.id) escalated tier \(model.minTier) → \(audited.minTier)")
        }
    }

    @Test("the fast-tier models are themselves free tier — a downgrade reaches the cheapest tier")
    func fastModelsAreFreeTier() {
        // If a provider HAS a fast entry, fastAudit lands on a free-tier model,
        // so a paid model's mechanical pass genuinely drops to the cheapest tier.
        for model in LLMCatalog.all {
            let audited = LLMCatalog.fastAudit(for: model)
            if audited.id != model.id {  // an actual downgrade happened
                #expect(audited.minTier == .free,
                        "fastAudit(\(model.id)) downgraded to \(audited.id) at tier \(audited.minTier), not free")
            }
        }
    }

    @Test("fastAudit keeps the same provider for real models (direct-key safety)")
    func fastAuditPreservesProvider() {
        // Real selections stay on their own provider so a direct-key user isn't
        // routed to a provider whose key they never configured. (Auto/council are
        // pseudo-selections and legitimately route to OpenAI's cheap model.)
        for model in LLMCatalog.all {
            #expect(LLMCatalog.fastAudit(for: model, managed: false).provider == model.provider)
        }
    }

    @Test("fastAudit is idempotent — a second mechanical pass doesn't drift")
    func fastAuditIsIdempotent() {
        for model in LLMCatalog.all + [LLMCatalog.auto] {
            let once = LLMCatalog.fastAudit(for: model)
            #expect(LLMCatalog.fastAudit(for: once).id == once.id)
        }
    }

    @Test("GPT-5.6 Sol is the strongest OpenAI premium version, vision-capable")
    func solIsStrongestOpenAIPremium() {
        let sol = LLMCatalog.model(id: "gpt-5.6-sol")
        #expect(sol != nil)
        #expect(sol?.provider == .openAI)
        #expect(sol?.minTier == .premium)
        #expect(sol?.supportsVision == true)
        // Catalog order is weak→strong, so Sol is the last (strongest) OpenAI
        // version a premium user sees — the autoVersion for OpenAI.
        let openAIVersions = LLMCatalog.versions(of: .openAI, for: .premium)
        #expect(openAIVersions.last?.id == "gpt-5.6-sol")
        // Its mechanical passes still downgrade to the free fast tier (M7d-1).
        #expect(LLMCatalog.fastAudit(for: sol!).minTier == .free)
    }

    // MARK: versions / autoVersion ordering (deterministic — no key checks)

    @Test("versions(of:for:) are catalog-ordered weak→strong and autoVersion is the last")
    func versionsOrdering() {
        // OpenAI at premium spans free→pro→premium in catalog order.
        let openAIPremium = LLMCatalog.versions(of: .openAI, for: .premium)
        #expect(openAIPremium.map(\.id) == ["gpt-5.4-mini", "gpt-5.4", "gpt-5.5", "gpt-5.6-sol"])
        #expect(LLMCatalog.autoVersion(of: .openAI, for: .premium)?.id == "gpt-5.6-sol")

        // Google at premium: flash (free) then pro.
        let googlePremium = LLMCatalog.versions(of: .google, for: .premium)
        #expect(googlePremium.map(\.id) == ["gemini-3.5-flash", "gemini-3.1-pro-preview"])
        #expect(LLMCatalog.autoVersion(of: .google, for: .premium)?.id == "gemini-3.1-pro-preview")

        // Anthropic at premium: Sonnet (pro) → Opus 4.8 → Fable 5. Fable is the
        // newer/stronger flagship, so it stays the strongest (autoVersion) —
        // Opus sits just below it (orchestration Ultra > Max).
        let anthropicPremium = LLMCatalog.versions(of: .anthropic, for: .premium)
        #expect(anthropicPremium.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
        #expect(LLMCatalog.autoVersion(of: .anthropic, for: .premium)?.id == "claude-opus-5")

        // Every returned version belongs to the asked provider and clears the tier.
        for model in openAIPremium {
            #expect(model.provider == .openAI)
            #expect(model.isAvailable(for: .premium))
        }
    }

    @Test("versions and autoVersion are empty/nil when the tier unlocks none")
    func versionsEmpty() {
        // Anthropic's cheapest model is pro-tier, so free unlocks nothing.
        #expect(LLMCatalog.versions(of: .anthropic, for: .free).isEmpty)
        #expect(LLMCatalog.autoVersion(of: .anthropic, for: .free) == nil)
        // Anthropic at pro: sonnet only (fable is premium).
        #expect(LLMCatalog.versions(of: .anthropic, for: .pro).map(\.id) == ["claude-sonnet-5"])
        #expect(LLMCatalog.autoVersion(of: .anthropic, for: .pro)?.id == "claude-sonnet-5")
    }

    // MARK: configuredProviders ordering (membership is key-dependent)

    @Test("configuredProviders is a catalog-ordered subsequence, deduped, and tier-monotonic")
    func configuredProvidersOrdering() {
        // Full first-appearance provider order across the catalog.
        var catalogOrder: [LLMProvider] = []
        for model in LLMCatalog.all where !catalogOrder.contains(model.provider) {
            catalogOrder.append(model.provider)
        }

        let premium = LLMCatalog.configuredProviders(for: .premium)
        // No duplicates.
        #expect(Set(premium).count == premium.count)
        // Relative order matches the catalog's first-appearance order.
        #expect(premium == catalogOrder.filter(premium.contains))
        // Every configured provider actually reports itself configured.
        for provider in premium { #expect(provider.isConfigured) }

        // Weaker tiers configure a subset of a stronger tier's providers.
        let free = LLMCatalog.configuredProviders(for: .free)
        #expect(Set(free).isSubset(of: Set(premium)))
    }

    // MARK: LLMProvider jurisdiction + label

    @Test("US providers report .us jurisdiction, Chinese providers .china")
    func providerJurisdiction() {
        for provider in [LLMProvider.openAI, .anthropic, .google] {
            #expect(provider.jurisdiction == .us)
        }
        for provider in [LLMProvider.deepSeek, .qwen, .zhipu, .moonshot] {
            #expect(provider.jurisdiction == .china)
        }
    }

    @Test("provider labels are the human-facing vendor names")
    func providerLabels() {
        #expect(LLMProvider.openAI.label == "OpenAI")
        #expect(LLMProvider.anthropic.label == "Anthropic")
        #expect(LLMProvider.google.label == "Google")
        #expect(LLMProvider.deepSeek.label == "DeepSeek")
        #expect(LLMProvider.qwen.label == "Qwen")
        #expect(LLMProvider.zhipu.label == "Zhipu GLM")
        #expect(LLMProvider.moonshot.label == "Moonshot")
    }

    // MARK: Councils

    @Test("the China council follows the same ≥2-member rule as US (decision reversed 2026-07, D11)")
    func chinaCouncilSymmetricWithUS() {
        // The earlier hard-off for China is gone: both jurisdictions are offered
        // by the same rule — available exactly when their panel has ≥2 members.
        for tier in Tier.allCases {
            let panel = LLMCatalog.councilPanel(.china, for: tier)
            #expect(LLMCatalog.councilAvailable(.china, for: tier) == (panel.count >= 2))
        }
    }

    @Test("US council availability is exactly a ≥2-member configured panel")
    func usCouncilRequiresTwoProviders() {
        for tier in Tier.allCases {
            let panel = LLMCatalog.councilPanel(.us, for: tier)
            #expect(LLMCatalog.councilAvailable(.us, for: tier) == (panel.count >= 2))
        }
    }

    @Test("council panels only include same-jurisdiction providers at their autoVersion")
    func councilPanelMembers() {
        for tier in Tier.allCases {
            for member in LLMCatalog.councilPanel(.us, for: tier) {
                #expect(member.provider.jurisdiction == .us)
                #expect(member.provider.hasDirectKey)
                // Each member runs the provider's strongest tier-allowed version.
                #expect(member.modelID == LLMCatalog.autoVersion(of: member.provider, for: tier)?.id)
            }
            for member in LLMCatalog.councilPanel(.china, for: tier) {
                #expect(member.provider.jurisdiction == .china)
            }
        }
    }

    @Test("council preset ids are the stable selection sentinels")
    func councilPresetIDs() {
        #expect(LLMCatalog.councilUS == "council:us")
        #expect(LLMCatalog.councilCN == "council:cn")
    }
}
