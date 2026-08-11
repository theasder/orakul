import Foundation

/// Cost ceilings for automatic analysis. Blind spots use one multi-lens pass;
/// specialized watches are slower, optional confirmations. Frontier models and
/// councils remain user-triggered.
///
/// Blind-spot credit burn (backend): each wake reserves compute credits while
/// Settings → Co-pilot → Brainstorm is on. Paid tiers wake a bit more often and
/// burn more credits per scan.
enum CopilotCadence {
    static let blindSpotSeconds: UInt64 = 120
    /// Slowest Pro+ cadence, reached when every specialist watch is enabled.
    static let blindSpotPaidSeconds: UInt64 = 90
    static let agendaSeconds: UInt64 = 300
    static let factCheckSeconds: UInt64 = 300
    static let rhetoricSeconds: UInt64 = 300
    static let facilitationSeconds: UInt64 = 300
    static let maxGroundingSources = 2

    /// Mirrors the backend's worst-case hourly co-pilot envelope. Optional
    /// specialist watches and Blind Spot share this budget: when a watch is off,
    /// its unused credits can make the user-visible Blind Spot feature more
    /// responsive without changing allowances or gross-margin assumptions.
    static func copilotCreditsPerHour(for tier: Tier) -> Int {
        switch tier {
        case .free: return 54
        case .pro: return 144
        case .premium: return 184
        case .ultra: return 224
        }
    }

    static func blindSpotCreditsPerScan(for tier: Tier) -> Int {
        switch tier {
        case .free: return 1
        case .pro: return 3
        case .premium: return 4
        case .ultra: return 5
        }
    }

    /// Budget-neutral adaptive cadence. Fact Check costs 12 one-credit wakes per
    /// hour; each enabled member of the three-way ambient rotation costs four.
    /// Integer division deliberately rounds the available scan count down, then
    /// the interval rounds up, so no combination can exceed its tariff envelope.
    static func blindSpotSeconds(
        for tier: Tier,
        agendaEnabled: Bool,
        factCheckEnabled: Bool,
        rhetoricEnabled: Bool,
        facilitationEnabled: Bool
    ) -> UInt64 {
        var specialistCredits = factCheckEnabled ? 12 : 0
        specialistCredits += agendaEnabled ? 4 : 0
        specialistCredits += rhetoricEnabled ? 4 : 0
        specialistCredits += facilitationEnabled ? 4 : 0

        let available = max(1, copilotCreditsPerHour(for: tier) - specialistCredits)
        let scansPerHour = max(1, available / blindSpotCreditsPerScan(for: tier))
        return UInt64((3_600 + scansPerHour - 1) / scansPerHour)
    }
}
