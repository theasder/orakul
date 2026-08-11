import Foundation
import Testing
@testable import MeetGPT

/// Auto mode: how much reasoning a request needs, and which model gets it.
///
/// This is the path a user on "Auto" never sees and always pays for — a wrong
/// route either burns a flagship on a one-line question or hands a strategy
/// analysis to a mini model. It sat at ~14% coverage.
///
/// Layered on one base fact — `effort(user:images:)` classifies a request —
/// with each later group adding a dimension to that same decision: the inputs
/// that raise effort, the boundaries between bands, what routing does with the
/// result, and what happens when a provider rejects the call.
@Suite("Auto orchestration routing")
struct AutoOrchestratorRoutingTests {

    private func text(_ count: Int, seed: String = "a meeting sentence ") -> String {
        String(repeating: seed, count: max(1, count / seed.count + 1)).prefix(count).description
    }

    // MARK: - Base: effort classification

    @Test("a short, plain request is light work")
    func shortRequestIsLight() {
        #expect(AutoOrchestrator.effort(user: "What did we decide?", images: []) == .light)
        #expect(AutoOrchestrator.effort(user: "", images: []) == .light)
    }

    // MARK: - Layer 1: what raises effort

    @Test("an image makes any request hard, however short")
    func imagesForceHard() {
        // Vision is the expensive axis: a one-word prompt over a screenshot is
        // still a vision call.
        #expect(AutoOrchestrator.effort(user: "what?", images: [Data([0x1])]) == .hard)
    }

    @Test("sheer length raises effort even with no analytical ask")
    func lengthRaisesEffort() {
        #expect(AutoOrchestrator.effort(user: text(5_000), images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: text(13_000), images: []) == .hard)
    }

    @Test("an analytical ask raises effort at a shorter length")
    func analyticalAskRaisesEffort() {
        // The signal is the KIND of question, not only its size: "compare these
        // two strategies" is real reasoning at 200 characters.
        #expect(AutoOrchestrator.effort(user: "Compare the two pricing strategies.", images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: "What is the risk here?", images: []) == .medium)
        // Same ask over a long transcript is hard, where plain text that long
        // would only be medium.
        #expect(AutoOrchestrator.effort(user: "Analyse this. " + text(5_000), images: []) == .hard)
    }

    @Test("the heavy-ask signal works in Russian too")
    func analyticalAskIsMultilingual() {
        // The transcript language follows the meeting, so an English-only
        // keyword list silently downgrades every non-English analytical ask.
        #expect(AutoOrchestrator.effort(user: "Почему это произошло?", images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: "Сравни два варианта.", images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: "Проведи анализ рисков.", images: []) == .medium)
    }

    @Test("effort bands have no gap and no overlap at their boundaries")
    func boundariesAreExact() {
        // Just under each threshold stays in the lower band; just over crosses.
        #expect(AutoOrchestrator.effort(user: text(4_000), images: []) == .light)
        #expect(AutoOrchestrator.effort(user: text(4_001), images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: text(12_000), images: []) == .medium)
        #expect(AutoOrchestrator.effort(user: text(12_001), images: []) == .hard)
    }

    // MARK: - Layer 2: what routing does with that effort

    @Test("light work routes to a model the free tier could run")
    func lightRoutesCheap() {
        for tier in [Tier.free, .pro, .premium, .ultra] {
            let model = AutoOrchestrator.route(.light, tier: tier, hasImages: false)
            #expect(model.minTier == .free,
                    "\(tier) sent light work to \(model.id) (minTier \(model.minTier))")
        }
    }

    @Test("hard work routes by capability rank, not catalog position")
    func hardRoutesToTheStrongest() {
        // The documented regression: the catalog array is grouped by tier then
        // vendor, so its LAST element is merely the last vendor declared.
        // Reading it as weakest-to-strongest sent a Premium user's hard task to
        // GLM-5.2 instead of the flagship.
        for tier in [Tier.premium, .ultra] {
            let model = AutoOrchestrator.route(.hard, tier: tier, hasImages: false)
            let pool = LLMCatalog.available(for: tier).filter { $0.provider.isConfigured }
            let best = LLMCatalog.strongest(in: pool)
            #expect(model.id == best?.id, "\(tier) picked \(model.id), strongest is \(best?.id ?? "-")")
            #expect(model.id != pool.last?.id || pool.count == 1,
                    "\(tier) looks positional: took the last catalog entry")
        }
    }

    @Test("effort is monotonic: harder work never routes to a weaker model")
    func harderNeverRoutesWeaker() {
        for tier in [Tier.free, .pro, .premium, .ultra] {
            let light = AutoOrchestrator.route(.light, tier: tier, hasImages: false)
            let medium = AutoOrchestrator.route(.medium, tier: tier, hasImages: false)
            let hard = AutoOrchestrator.route(.hard, tier: tier, hasImages: false)
            // Lower rank index = stronger.
            #expect(LLMCatalog.rank(of: medium) <= LLMCatalog.rank(of: light), "\(tier)")
            #expect(LLMCatalog.rank(of: hard) <= LLMCatalog.rank(of: medium), "\(tier)")
        }
    }

    @Test("a tier is never routed a model it cannot run")
    func routingRespectsTheTier() {
        // The cost failure mode: routing a Free user to a Premium model is a
        // bill nobody agreed to.
        for tier in [Tier.free, .pro, .premium, .ultra] {
            for effort in [AutoOrchestrator.Effort.light, .medium, .hard] {
                let model = AutoOrchestrator.route(effort, tier: tier, hasImages: false)
                #expect(model.minTier.rank <= tier.rank,
                        "\(tier)/\(effort) routed to \(model.id) (needs \(model.minTier))")
            }
        }
    }

    @Test("a request with images only routes to a model that can see them")
    func visionRequestsRouteToVisionModels() {
        for tier in [Tier.free, .pro, .premium, .ultra] {
            for effort in [AutoOrchestrator.Effort.light, .medium, .hard] {
                let model = AutoOrchestrator.route(effort, tier: tier, hasImages: true)
                // Either a vision model, or the tier default as the documented
                // last resort when the tier has none.
                #expect(model.supportsVision || model.id == LLMCatalog.defaultModel(for: tier).id,
                        "\(tier)/\(effort) routed images to \(model.id)")
            }
        }
    }

    @Test("pinning a provider keeps routing inside it when it has a candidate")
    func providerPinningIsHonoured() {
        let pool = LLMCatalog.available(for: .ultra).filter { $0.provider.isConfigured }
        guard let pinned = pool.first?.provider else { return }
        let model = AutoOrchestrator.route(.hard, tier: .ultra, hasImages: false, within: pinned)
        #expect(model.provider == pinned)
    }

    @Test("pinning a provider with nothing to offer falls back rather than failing")
    func pinningUnavailableProviderFallsBack() {
        // A pin is a preference, not a constraint that may return nothing —
        // the caller needs a model to run.
        let model = AutoOrchestrator.route(.hard, tier: .free, hasImages: true, within: .anthropic)
        #expect(!model.id.isEmpty)
    }

    // MARK: - Layer 3: recovering when a provider rejects the call

    @Test("a missing key or a provider 401 is an auth failure worth retrying elsewhere")
    func recognisesAuthFailures() {
        #expect(AutoOrchestrator.isProviderAuthFailure(LLMError.missingKey("OpenAI")))
        #expect(AutoOrchestrator.isProviderAuthFailure(LLMError.http("OpenAI", 401, "bad key")))
    }

    @Test("our own backend's 401 is not a provider auth failure")
    func backendAuthIsNotAProviderProblem() {
        // A 401 from Backend means the USER is signed out. Retrying it on
        // another provider cannot help and would hide the real cause — which is
        // exactly the "credits unavailable" confusion in a different disguise.
        #expect(!AutoOrchestrator.isProviderAuthFailure(LLMError.http("Backend", 401, "sign in")))
    }

    @Test("outages, rate limits and transport errors are not auth failures")
    func otherErrorsAreNotAuthFailures() {
        for code in [429, 500, 502, 503] {
            #expect(!AutoOrchestrator.isProviderAuthFailure(LLMError.http("OpenAI", code, "")),
                    "\(code) treated as an auth failure")
        }
        #expect(!AutoOrchestrator.isProviderAuthFailure(LLMError.badResponse("OpenAI")))
        #expect(!AutoOrchestrator.isProviderAuthFailure(URLError(.timedOut)))
    }

    @Test("the auth fallback never returns the provider that just failed")
    func fallbackExcludesTheFailedProvider() {
        for tier in [Tier.free, .pro, .premium, .ultra] {
            for provider in [LLMProvider.openAI, .anthropic, .google] {
                guard let fallback = AutoOrchestrator.authFallbackModel(
                    excluding: provider, tier: tier) else { continue }
                #expect(fallback.provider != provider,
                        "\(tier): fell back to the same provider \(provider)")
                #expect(fallback.minTier.rank <= tier.rank,
                        "\(tier): fell back to \(fallback.id), above the tier")
            }
        }
    }
}
