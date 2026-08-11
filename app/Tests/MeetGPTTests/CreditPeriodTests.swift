import Foundation
import Testing
@testable import MeetGPT

/// The credit rail showed a balance and nothing else. A balance without its
/// reset is hard to act on — "412 left" means one thing on day 2 and another on
/// day 29 — and a raw credit count is an abstract unit until it is expressed as
/// prompts. These pin both translations.
@Suite("Credit period")
struct CreditPeriodTests {

    private func date(_ iso: String) -> Date {
        CreditPeriod.parse(periodStart: iso)!
    }

    @Test("parses the ISO period start the server reports")
    func parsesISO() {
        #expect(CreditPeriod.parse(periodStart: "2026-07-15T00:00:00.000Z") != nil)
        #expect(CreditPeriod.parse(periodStart: "2026-07-15T00:00:00Z") != nil)
        #expect(CreditPeriod.parse(periodStart: "not a date") == nil)
    }

    @Test("the allowance refills one calendar month after the period start")
    func resetsOneMonthLater() {
        let start = date("2026-07-15T00:00:00Z")
        let reset = try? #require(CreditPeriod.resetDate(periodStart: start))
        #expect(reset == date("2026-08-15T00:00:00Z"))
    }

    @Test("a month-end anchor clamps instead of spilling into the next month")
    func clampsShortMonths() {
        // The server clamps the same way; a period anchored on the 31st must
        // not roll past the end of a 30-day month.
        let start = date("2026-01-31T00:00:00Z")
        let reset = try? #require(CreditPeriod.resetDate(periodStart: start))
        #expect(reset == date("2026-02-28T00:00:00Z"))
    }

    @Test("days until reset counts down and never goes negative")
    func countsDays() {
        let start = date("2026-07-15T00:00:00Z")
        #expect(CreditPeriod.daysUntilReset(periodStart: start,
                                            now: date("2026-07-15T00:00:00Z")) == 31)
        #expect(CreditPeriod.daysUntilReset(periodStart: start,
                                            now: date("2026-08-03T00:00:00Z")) == 12)
        // A stale period start reads as "any moment now", not as a negative.
        #expect(CreditPeriod.daysUntilReset(periodStart: start,
                                            now: date("2026-09-20T00:00:00Z")) == 0)
    }

    @Test("the reset reads naturally at each distance")
    func describesReset() {
        let start = date("2026-07-15T00:00:00Z")
        #expect(CreditPeriod.resetDescription(periodStart: start,
                                              now: date("2026-08-15T00:00:00Z")) == "resets today")
        #expect(CreditPeriod.resetDescription(periodStart: start,
                                              now: date("2026-08-14T00:00:00Z")) == "resets tomorrow")
        #expect(CreditPeriod.resetDescription(periodStart: start,
                                              now: date("2026-08-03T00:00:00Z")) == "resets in 12 days")
    }

    @Test("the balance is expressed as prompts, which is what people plan around")
    func convertsToPrompts() {
        #expect(CreditPeriod.remainingPrompts(remainingCredits: 100, perPrompt: 8) == 12)
        #expect(CreditPeriod.remainingPrompts(remainingCredits: 5, perPrompt: 8) == 0)
        #expect(CreditPeriod.remainingPrompts(remainingCredits: 100, perPrompt: 1) == 100)
    }

    @Test("no prompt count is claimed when the per-prompt price is unknown")
    func noPromptsWithoutPrice() {
        // Auto and the orchestration councils price differently, so quoting a
        // chat-rate count there would under-report what the balance buys.
        #expect(CreditPeriod.remainingPrompts(remainingCredits: 100, perPrompt: nil) == nil)
        #expect(CreditPeriod.remainingPrompts(remainingCredits: 100, perPrompt: 0) == nil)
    }
}
