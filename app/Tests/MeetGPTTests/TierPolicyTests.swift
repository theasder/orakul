import Testing
import Foundation
@testable import MeetGPT

/// A tariff is a purchased/server entitlement. Local engagement and elapsed
/// trial days must never silently unlock provider spend.
@Suite("Tier policy")
struct TierPolicyTests {
    private func stats(meetings: Int = 0, aiRequests: Int = 0, days: Int = 30) -> UsageStats {
        UsageStats(meetings: meetings, aiRequests: aiRequests, daysSinceFirstLaunch: days)
    }

    @Test("the purchased floor is always the effective tier")
    func floorIsTruth() {
        #expect(TierPolicy.effectiveTier(stats: stats(days: 0), floor: .free) == .free)
        #expect(TierPolicy.effectiveTier(stats: stats(meetings: 1_000, aiRequests: 10_000),
                                         floor: .free) == .free)
        #expect(TierPolicy.effectiveTier(stats: stats(), floor: .pro) == .pro)
        #expect(TierPolicy.effectiveTier(stats: stats(), floor: .premium) == .premium)
        #expect(TierPolicy.effectiveTier(stats: stats(), floor: .ultra) == .ultra)
    }

    @Test("status explains the tier's bounded monthly allowance")
    func statusShowsAllowance() {
        #expect(TierPolicy.status(stats: stats(), tier: .free)
            == "Free · 2h Copilot · 15 credits / month")
        #expect(TierPolicy.status(stats: stats(), tier: .premium)
            == "Premium · 40h Copilot · 750 credits / month")
    }
}
