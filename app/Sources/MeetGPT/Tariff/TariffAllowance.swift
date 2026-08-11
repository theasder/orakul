import Foundation

/// The bounded monthly usage included with a tariff. This mirrors the backend
/// catalog so the Mac can stop automatic work before it creates avoidable spend;
/// the backend remains authoritative for model access and compute credits.
struct TariffAllowance: Codable, Equatable, Sendable {
    let copilotHours: Int
    let computeCredits: Int
    let groundedCycles: Int

    static func forTier(_ tier: Tier) -> TariffAllowance {
        switch tier {
        case .free:
            return TariffAllowance(copilotHours: 2, computeCredits: 15, groundedCycles: 3)
        case .pro:
            return TariffAllowance(copilotHours: 20, computeCredits: 250, groundedCycles: 20)
        case .premium:
            return TariffAllowance(copilotHours: 40, computeCredits: 750, groundedCycles: 100)
        case .ultra:
            return TariffAllowance(copilotHours: 60, computeCredits: 1_500, groundedCycles: 300)
        }
    }

    var copilotSeconds: Int { copilotHours * 3_600 }

    func remainingCopilotSeconds(usedSeconds: Int, activeSeconds: Int = 0) -> Int {
        max(0, copilotSeconds - max(0, usedSeconds) - max(0, activeSeconds))
    }

    func canRunGroundedCycle(used: Int) -> Bool {
        max(0, used) < groundedCycles
    }
}

enum TariffPeriod {
    static func currentStart(anchor: Date?, now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let anchor, anchor <= now else {
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        }
        var month = max(0, calendar.dateComponents([.month], from: anchor, to: now).month ?? 0)
        var candidate = calendar.date(byAdding: .month, value: month, to: anchor) ?? anchor
        while candidate > now, month > 0 {
            month -= 1
            candidate = calendar.date(byAdding: .month, value: month, to: anchor) ?? anchor
        }
        return candidate
    }
}
