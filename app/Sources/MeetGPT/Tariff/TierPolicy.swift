import Foundation

/// The server/purchased entitlement is the tariff truth. Engagement is useful
/// product telemetry, but must never silently unlock an unbounded provider bill.
enum TierPolicy {
    static let paywallReminderDays = 7

    static func effectiveTier(stats _: UsageStats, floor: Tier) -> Tier {
        floor
    }

    static func status(stats _: UsageStats, tier: Tier) -> String {
        let allowance = TariffAllowance.forTier(tier)
        return "\(tier.label) · \(allowance.copilotHours)h Copilot · \(allowance.computeCredits) credits / month"
    }
}
