import Foundation

/// When the compute-credit allowance refills.
///
/// The rail showed a balance and nothing else, which is the one thing that
/// makes a balance hard to act on: "412 credits left" means something very
/// different on day 2 than on day 29. Every comparable product answers this —
/// usage panels lead with the remaining amount AND its reset.
///
/// The server anchors the period on the plan's activation date and steps it by
/// whole months (`billingPeriodStart` in functions/tariffs.js), so the reset is
/// one calendar month after the reported `periodStart`, clamped for short
/// months. Computed in UTC to match the server rather than drifting by the
/// viewer's timezone.
enum CreditPeriod {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// ISO-8601 `periodStart` as reported by `GET /api/billing/usage`.
    static func parse(periodStart: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: periodStart) { return date }
        return ISO8601DateFormatter().date(from: periodStart)
    }

    /// One calendar month after the period start. `Calendar` clamps naturally —
    /// a period anchored on the 31st rolls to the 30th (or 28th) rather than
    /// spilling into the following month, matching the server's clamp.
    static func resetDate(periodStart: Date) -> Date? {
        utcCalendar.date(byAdding: .month, value: 1, to: periodStart)
    }

    /// Whole days until the allowance refills. 0 means it resets today; never
    /// negative, since a stale `periodStart` should read as "any moment now"
    /// rather than as a countdown that has gone backwards.
    static func daysUntilReset(periodStart: Date, now: Date = Date()) -> Int? {
        guard let reset = resetDate(periodStart: periodStart) else { return nil }
        let days = utcCalendar.dateComponents([.day], from: now, to: reset).day ?? 0
        return max(0, days)
    }

    /// "resets today" / "resets tomorrow" / "resets in 12 days".
    static func resetDescription(periodStart: Date, now: Date = Date()) -> String? {
        guard let days = daysUntilReset(periodStart: periodStart, now: now) else { return nil }
        switch days {
        case 0: return "resets today"
        case 1: return "resets tomorrow"
        default: return "resets in \(days) days"
        }
    }

    /// How many more prompts of the current size the balance covers.
    ///
    /// A raw credit count is an abstract unit; the number of prompts it buys is
    /// the thing people actually plan around. nil when the per-prompt cost is
    /// unknown (Auto and the orchestration councils price differently).
    static func remainingPrompts(remainingCredits: Int, perPrompt: Int?) -> Int? {
        guard let perPrompt, perPrompt > 0, remainingCredits >= 0 else { return nil }
        return remainingCredits / perPrompt
    }
}
