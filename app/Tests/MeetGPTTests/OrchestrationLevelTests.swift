import Testing
@testable import MeetGPT

/// The price/power-tiered orchestration panels (Free/Medium/Max/Ultra). The
/// load-bearing invariant: every panel names models that actually exist in the
/// catalog, so a panel can never route to a model the app can't serve.
@Suite("OrchestrationLevel")
struct OrchestrationLevelTests {
    @Test("every panel member and chairman is a real catalog model")
    func panelsNameRealModels() {
        for level in OrchestrationLevel.allCases {
            #expect(level.memberModelIDs.count >= 2, "\(level) needs a real panel")
            for id in level.memberModelIDs {
                #expect(LLMCatalog.model(id: id) != nil, "\(level) names missing model \(id)")
            }
            #expect(LLMCatalog.model(id: level.chairmanModelID) != nil)
        }
    }

    @Test("the chairman is the panel's strongest (last) member")
    func chairmanIsStrongestMember() {
        for level in OrchestrationLevel.allCases {
            #expect(level.chairmanModelID == level.memberModelIDs.last)
        }
    }

    @Test("panels map to the intended tariff tiers")
    func panelTierMapping() {
        #expect(OrchestrationLevel.free.minTier == .free)
        #expect(OrchestrationLevel.medium.minTier == .pro)
        #expect(OrchestrationLevel.max.minTier == .premium)
        #expect(OrchestrationLevel.ultra.minTier == .ultra)
    }

    @Test("councils disclose their cost-weighted starting credits")
    func creditWeights() {
        #expect(OrchestrationLevel.free.computeCredits == 5)
        #expect(OrchestrationLevel.medium.computeCredits == 15)
        #expect(OrchestrationLevel.max.computeCredits == 24)
        #expect(OrchestrationLevel.ultra.computeCredits == 38)
    }

    @Test("the composition matches the product spec (Max and Ultra both chaired by GPT-5.6 Sol; Ultra is a wider panel)")
    func compositionMatchesSpec() {
        #expect(OrchestrationLevel.max.chairmanModelID == "gpt-5.6-sol")
        #expect(OrchestrationLevel.ultra.chairmanModelID == "gpt-5.6-sol")
        #expect(OrchestrationLevel.max.memberModelIDs.contains("gpt-5.6-sol"))
        #expect(OrchestrationLevel.ultra.memberModelIDs.contains("gpt-5.6-sol"))
        #expect(OrchestrationLevel.medium.chairmanModelID == "claude-sonnet-5")
    }

    @Test("available(for:) climbs with the tariff; highest(for:) is the top unlocked")
    func availabilityByTier() {
        #expect(OrchestrationLevel.available(for: .free) == [.free])
        #expect(OrchestrationLevel.available(for: .pro) == [.free, .medium])
        #expect(OrchestrationLevel.available(for: .premium) == [.free, .medium, .max])
        #expect(OrchestrationLevel.available(for: .ultra) == [.free, .medium, .max, .ultra])
        #expect(OrchestrationLevel.highest(for: .free) == .free)
        #expect(OrchestrationLevel.highest(for: .premium) == .max)
        #expect(OrchestrationLevel.highest(for: .ultra) == .ultra)
    }

    @Test("selection sentinels round-trip through Config.selectedModelID")
    func selectionRoundTrip() {
        for level in OrchestrationLevel.allCases {
            #expect(level.selectionID == "orchestrate:\(level.rawValue)")
            #expect(OrchestrationLevel.from(selection: level.selectionID) == level)
        }
        #expect(OrchestrationLevel.from(selection: "auto") == nil)
        #expect(OrchestrationLevel.from(selection: "gpt-5.6-sol") == nil)
    }
}
