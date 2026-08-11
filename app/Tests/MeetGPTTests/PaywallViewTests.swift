import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// PaywallView coverage: the intro stage rendering (via ViewInspector, no UI
/// host so the plan-loading .task never fires a network call) plus the pure
/// catalog logic (offer detection, interval filtering) and PaywallPlan decoding.
@MainActor
@Suite("Paywall")
struct PaywallViewTests {
    // PaywallPlan only has a Decodable init — build fixtures through JSON.
    private func plan(id: String, interval: String, offer: Bool,
                      tier: String = "pro", priceCents: Int = 1900,
                      purchasable: Bool = true,
                      features: [String] = ["A feature"], offerEndsAt: String? = nil) -> PaywallPlan {
        var obj: [String: Any] = [
            "id": id, "name": id.capitalized, "tier": tier, "interval": interval,
            "priceCents": priceCents, "currency": "USD", "offer": offer,
            "purchasable": purchasable,
            "allowances": ["copilotHours": 20, "computeCredits": 250, "groundedCycles": 20],
            "features": features
        ]
        if let offerEndsAt { obj["offerEndsAt"] = offerEndsAt }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return try! JSONDecoder().decode(PaywallPlan.self, from: data)
    }

    // MARK: View — intro stage

    @Test("intro stage renders the value props and both entry actions")
    func introStage() throws {
        let view = PaywallView().environmentObject(AppState(llm: MockLLMGateway(response: "")))
        let sut = try view.inspect()
        #expect(throws: Never.self) { try sut.find(text: "Cruxwing plans") }
        #expect(throws: Never.self) { try sut.find(text: "Continue with Free") }
        #expect(throws: Never.self) { try sut.find(text: "See plans") }
        // A benefit line is present; the pricing-stage title is not (still intro).
        #expect(throws: Never.self) {
            try sut.find(text: "Councils are explicit, on-demand actions")
        }
        #expect(throws: (any Error).self) { try sut.find(text: "Choose your plan") }
        #expect(throws: Never.self) {
            _ = try sut.find(viewWithAccessibilityIdentifier: "paywall.see-plans")
        }
    }

    @Test("pricing stage exposes stable promo input and Redeem automation identities")
    func pricingPromoControls() throws {
        let view = PaywallView(initialStage: .pricing)
            .environmentObject(AppState(llm: MockLLMGateway(response: "")))
        let sut = try view.inspect()
        for id in ["paywall.promo-code", "paywall.redeem"] {
            #expect(throws: Never.self, "missing paywall accessibility id: \(id)") {
                _ = try sut.find(viewWithAccessibilityIdentifier: id)
            }
        }
    }

    @Test("successful redemption stage exposes stable success and dismiss identities")
    func redemptionSuccessControls() throws {
        let view = PaywallView(initialStage: .done)
            .environmentObject(AppState(llm: MockLLMGateway(response: "")))
        let sut = try view.inspect()
        for id in ["paywall.success", "paywall.success-dismiss"] {
            #expect(throws: Never.self, "missing paywall accessibility id: \(id)") {
                _ = try sut.find(viewWithAccessibilityIdentifier: id)
            }
        }
    }

    // MARK: Catalog logic (pure)

    @Test("featuredOffer returns the one offer plan, or nil when there is none")
    func featuredOffer() {
        let plans = [
            plan(id: "pro-monthly", interval: "month", offer: false),
            plan(id: "launch", interval: "month", offer: true)
        ]
        #expect(PaywallView.featuredOffer(plans)?.id == "launch")
        #expect(PaywallView.featuredOffer([plan(id: "x", interval: "month", offer: false)]) == nil)
        #expect(PaywallView.featuredOffer([]) == nil)
    }

    @Test("selectablePlans filters by interval and excludes the offer")
    func selectable() {
        let plans = [
            plan(id: "pro-monthly", interval: "month", offer: false),
            plan(id: "premium-monthly", interval: "month", offer: false),
            plan(id: "pro-annual", interval: "year", offer: false),
            plan(id: "launch-monthly", interval: "month", offer: true)   // offer -> excluded
        ]
        let monthly = PaywallView.selectablePlans(plans, interval: "month")
        #expect(monthly.map(\.id) == ["pro-monthly", "premium-monthly"])

        let annual = PaywallView.selectablePlans(plans, interval: "year")
        #expect(annual.map(\.id) == ["pro-annual"])
    }

    @Test("selectablePlans surfaces the Ultra tier with its API price (M7O-P4c)")
    func ultraSurfaced() {
        let plans = [
            plan(id: "pro-monthly", interval: "month", offer: false, tier: "pro", priceCents: 1900),
            plan(id: "ultra-monthly", interval: "month", offer: false, tier: "ultra", priceCents: 9900),
        ]
        let monthly = PaywallView.selectablePlans(plans, interval: "month")
        #expect(monthly.contains { $0.tier == "ultra" })          // Ultra is NOT filtered out
        // Price comes from the API priceCents field, not a hardcoded string.
        #expect(monthly.first { $0.tier == "ultra" }?.priceLabel == "$99/mo")
    }

    // MARK: PaywallPlan model

    @Test("priceLabel formats dollars with a monthly/annual suffix")
    func priceLabel() {
        #expect(plan(id: "m", interval: "month", offer: false, priceCents: 1900).priceLabel == "$19/mo")
        #expect(plan(id: "y", interval: "year", offer: false, priceCents: 19000).priceLabel == "$190/yr")
    }

    @Test("decodes bounded allowances and non-purchasable Free")
    func decodesAllowances() {
        let free = plan(id: "free", interval: "month", offer: false,
                        tier: "free", priceCents: 0, purchasable: false)
        #expect(free.allowances.copilotHours == 20)
        #expect(free.allowances.computeCredits == 250)
        #expect(!free.purchasable)
    }

    @Test("decodes the offer end date, and tolerates its absence")
    func decodesOfferDate() {
        let withDate = plan(id: "o", interval: "month", offer: true, offerEndsAt: "2030-01-15T00:00:00Z")
        #expect(withDate.offerEndsAt != nil)
        let withoutDate = plan(id: "n", interval: "month", offer: false)
        #expect(withoutDate.offerEndsAt == nil)
    }
}
