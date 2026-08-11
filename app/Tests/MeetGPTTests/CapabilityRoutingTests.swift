import Foundation
import Testing
@testable import MeetGPT

/// "Give me your best model" was decided by ARRAY POSITION: `route(.hard)` took
/// the last element of the available pool, on the assumption that the catalog is
/// ordered weakest → strongest. It is not — it is grouped by tier and then by
/// vendor, so the last premium entry is simply the last vendor declared. A
/// Premium user on Auto with a hard task was therefore routed to GLM-5.2 instead
/// of the flagship.
@Suite("Capability routing")
struct CapabilityRoutingTests {

    private func model(_ id: String) -> LLMModel { LLMCatalog.model(id: id)! }

    @Test("the flagship wins regardless of where it sits in the catalog array")
    func flagshipBeatsArrayPosition() {
        let premiumPool = LLMCatalog.available(for: .premium)
        let strongest = LLMCatalog.strongest(in: premiumPool)

        #expect(strongest?.id == "gpt-5.6-sol")
        // The bug in one line: the last array element is NOT the strongest.
        #expect(premiumPool.last?.id != strongest?.id)
    }

    @Test("ranking covers every catalog model, so nothing sorts as unknown")
    func everyModelIsRanked() {
        for candidate in LLMCatalog.all where candidate.id != LLMCatalog.autoID {
            #expect(LLMCatalog.rank(of: candidate) != Int.max,
                    "\(candidate.id) is missing from capabilityOrder")
        }
    }

    @Test("an unranked model sorts last rather than silently winning")
    func unrankedSortsLast() {
        let known = model("gpt-5.4-mini")
        let unknown = LLMModel(id: "brand-new-model", label: "New", provider: .openAI,
                               minTier: .free, supportsVision: false)
        #expect(LLMCatalog.strongest(in: [unknown, known])?.id == known.id)
    }

    @Test("a weaker tier gets the strongest model IT is allowed, not the global best")
    func respectsTierCeiling() {
        let proPool = LLMCatalog.available(for: .pro)
        let strongest = LLMCatalog.strongest(in: proPool)
        #expect(strongest?.minTier.rank ?? 0 <= Tier.pro.rank)
        // gpt-5.4 outranks the other pro-tier options in capabilityOrder.
        #expect(strongest?.id == "gpt-5.4")
    }

    @Test("free tier resolves to its own best, never to a paid model")
    func freeStaysFree() {
        let freePool = LLMCatalog.available(for: .free)
        let strongest = LLMCatalog.strongest(in: freePool)
        #expect(strongest?.minTier == .free)
        #expect(strongest?.id == "gemini-3.5-flash")
    }

    @Test("within one provider the catalog order still holds, so autoVersion is safe")
    func perProviderOrderingUnchanged() {
        // autoVersion takes .last deliberately — inside a single vendor the
        // catalog IS weak → strong, which is why it was left positional.
        #expect(LLMCatalog.autoVersion(of: .anthropic, for: .premium)?.id == "claude-opus-5")
        #expect(LLMCatalog.autoVersion(of: .openAI, for: .premium)?.id == "gpt-5.6-sol")
        #expect(LLMCatalog.autoVersion(of: .google, for: .premium)?.id == "gemini-3.1-pro-preview")
    }
}
