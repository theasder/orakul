import Foundation
import Testing
@testable import MeetGPT

/// Dev-mode plan preview (Settings ▸ Account & Privacy ▸ Developer).
/// The override must drive Config.currentTier — the single seam every gate
/// reads (model catalog, allowances, background co-pilot) — and must clear
/// back to the real entitlement.
@Suite("Dev tier override", .serialized)
struct DevTierOverrideTests {
    private let key = "dev.tierOverride"
    private let purchasedKey = "billing.purchasedTier"

    @Test("live entitlement scope masks but never mutates a saved preview")
    @MainActor
    func liveEntitlementScopeIsProcessLocal() throws {
        guard Config.isDevBuild else { return }
        let defaults = UserDefaults.standard
        let savedPreview = defaults.string(forKey: key)
        let savedPurchased = defaults.string(forKey: purchasedKey)
        defer {
            Config.setLiveTestRealEntitlementMode(false)
            if let savedPreview { defaults.set(savedPreview, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            if let savedPurchased { defaults.set(savedPurchased, forKey: purchasedKey) }
            else { defaults.removeObject(forKey: purchasedKey) }
        }

        defaults.set(Tier.premium.rawValue, forKey: key)
        defaults.set(Tier.ultra.rawValue, forKey: purchasedKey)
        Config.setLiveTestRealEntitlementMode(false)
        #expect(Config.devTierOverride == .premium)
        #expect(Config.currentTier == .premium)
        let state = AppState()
        #expect(state.currentTier == .premium)

        var ordinaryPaywall = URLRequest(
            url: try #require(URL(string: "https://api.example.test/api/billing/usage")))
        PaywallAPI.applyDevTierPreview(to: &ordinaryPaywall)
        #expect(ordinaryPaywall.value(forHTTPHeaderField: "X-Dev-Tier") == "premium")

        Config.setLiveTestRealEntitlementMode(true)
        Config.setLiveTestRealEntitlementMode(true) // begin is idempotent
        #expect(Config.devTierOverride == nil)
        #expect(Config.currentTier == .ultra)
        state.refreshEntitlementAfterRedeem()
        #expect(state.currentTier == .ultra)
        #expect(state.tariffAllowance.computeCredits == 1_500)
        #expect(TariffAllowance.forTier(Config.currentTier)
            == TariffAllowance(copilotHours: 60, computeCredits: 1_500,
                               groundedCycles: 300))
        #expect(defaults.string(forKey: key) == Tier.premium.rawValue,
                "the saved developer preference must survive a crash")

        var scopedPaywall = URLRequest(
            url: try #require(URL(string: "https://api.example.test/api/billing/usage")))
        PaywallAPI.applyDevTierPreview(to: &scopedPaywall)
        #expect(scopedPaywall.value(forHTTPHeaderField: "X-Dev-Tier") == nil)

        var scopedManaged = URLRequest(
            url: try #require(URL(string: "https://api.example.test/api/brainstorm")))
        ManagedBackendRequestPolicy.apply(
            to: &scopedManaged, bearerToken: nil,
            devTierOverride: Config.devTierOverride)
        #expect(scopedManaged.value(forHTTPHeaderField: "X-Dev-Tier") == nil)

        Config.setLiveTestRealEntitlementMode(false)
        Config.setLiveTestRealEntitlementMode(false) // end is idempotent
        state.refreshEntitlementAfterRedeem()
        #expect(Config.devTierOverride == .premium)
        #expect(Config.currentTier == .premium)
        #expect(state.currentTier == .premium)
        #expect(state.tariffAllowance.computeCredits == 750)
        #expect(defaults.string(forKey: key) == Tier.premium.rawValue)
    }

    @Test("override drives currentTier and clears back to the real plan")
    func overrideRoundTrip() {
        guard Config.isDevBuild else { return }   // dist builds: feature absent
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        let real = Config.currentTier

        for tier in Tier.allCases {
            Config.devTierOverride = tier
            #expect(Config.currentTier == tier)
            // The whole entitlement surface follows the preview:
            #expect(TariffAllowance.forTier(Config.currentTier) == TariffAllowance.forTier(tier))
        }

        Config.devTierOverride = nil
        #expect(Config.devTierOverride == nil)
        #expect(Config.currentTier == real)
    }

    @Test("preview unlocks and relocks the model catalog")
    func modelCatalogFollowsPreview() {
        guard Config.isDevBuild else { return }
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        Config.devTierOverride = .free
        let freeModels = LLMCatalog.all.filter { $0.isAvailable(for: Config.currentTier) }.count
        Config.devTierOverride = .ultra
        let ultraModels = LLMCatalog.all.filter { $0.isAvailable(for: Config.currentTier) }.count
        Config.devTierOverride = nil

        #expect(ultraModels > freeModels)   // higher plan, strictly more models
    }

    @Test("a stored override is inert unless this is a dev build")
    func distBuildsIgnoreStoredOverride() {
        // The getter refuses to read the key outside dev builds, so even a
        // hand-planted UserDefaults value cannot unlock a shipped binary.
        // (In dev test runs this asserts the guard's shape, not its firing.)
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("ultra", forKey: key)
        if Config.isDevBuild {
            #expect(Config.devTierOverride == .ultra)
        } else {
            #expect(Config.devTierOverride == nil)
            #expect(Config.currentTier != .ultra || Config.baselineTier == .ultra
                    || Config.purchasedTier == .ultra)
        }
    }
}
