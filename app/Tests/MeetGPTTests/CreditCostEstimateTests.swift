import Foundation
import Testing
@testable import MeetGPT

/// The price shown to the user before they spend.
///
/// This is a client-side MIRROR of the server's `computeCreditsFor` chat
/// branch. The server always decides the real charge; this only predicts it —
/// so the failure mode is quiet and corrosive: the rail quotes one number, the
/// invoice says another, and the user learns not to trust the rail.
///
/// Layered on one base fact — a known model costs its listed base — with each
/// later group adding a term of the formula, then the severity judgement built
/// on top of the total.
@Suite("Credit cost estimate")
struct CreditCostEstimateTests {

    // MARK: - Base

    @Test("a known model costs its listed base credits")
    func chargesTheListedBase() {
        #expect(CreditCostEstimate.credits(model: "gpt-4o-mini", inputTokens: 100) == 1)
        #expect(CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100) == 4)
        #expect(CreditCostEstimate.credits(model: "claude-opus-5", inputTokens: 100) == 7)
    }

    // MARK: - Layer: input surcharge

    @Test("input inside the baseline adds nothing")
    func baselineIsIncluded() {
        // The baseline is what the base charge already covers; charging for it
        // twice would make every short prompt look expensive.
        for tokens in [0, 1_000, CreditCostEstimate.baselineInputTokens] {
            #expect(CreditCostEstimate.inputSurcharge(model: "gpt-5.4", inputTokens: tokens) == 0,
                    "\(tokens) tokens was surcharged")
        }
    }

    @Test("input above the baseline is surcharged at the model's own rate")
    func surchargeScalesWithTheModel() {
        // A long prompt on a cheap model must not cost what it costs on a
        // flagship — that difference is the entire reason for the rate table.
        let excessive = CreditCostEstimate.baselineInputTokens + 1_000_000
        let cheap = CreditCostEstimate.inputSurcharge(model: "gpt-4o-mini", inputTokens: excessive)
        let dear = CreditCostEstimate.inputSurcharge(model: "gpt-5.5", inputTokens: excessive)
        #expect(cheap == 15)   // 1M tokens × $0.15/M × 100 credits/$
        #expect(dear == 500)   // 1M tokens × $5.00/M × 100 credits/$
        #expect(dear > cheap)
    }

    @Test("a partial credit of surcharge rounds up, never down to free")
    func surchargeRoundsUp() {
        // Rounding down would let a long prompt on a cheap model be surcharged
        // zero — the app would under-quote exactly the case the surcharge is for.
        let justOver = CreditCostEstimate.baselineInputTokens + 100
        #expect(CreditCostEstimate.inputSurcharge(model: "gpt-4o-mini", inputTokens: justOver) == 1)
    }

    @Test("an unknown model falls back to a non-zero price on both terms")
    func unknownModelsAreNotFree() {
        // A model the client has not heard of — newer than this build — must
        // never be quoted as free; the server will still charge for it.
        #expect(CreditCostEstimate.credits(model: "some-new-model", inputTokens: 100)
                == CreditCostEstimate.fallbackBaseCredits)
        #expect(CreditCostEstimate.inputSurcharge(
            model: "some-new-model",
            inputTokens: CreditCostEstimate.baselineInputTokens + 1_000_000) > 0)
    }

    // MARK: - Layer: output ceiling

    @Test("the default output budget keeps the existing base quote")
    func baselineOutputIsIncluded() {
        #expect(CreditCostEstimate.credits(
            model: "gpt-5.6-sol", inputTokens: 100) == 7)
        #expect(CreditCostEstimate.outputBudgetSurcharge(
            model: "gpt-5.6-sol", maxOutputTokens: nil, baseCredits: 7) == 0)
    }

    @Test("the explicit 8k answer ceiling reserves the server tariff")
    func explicitAnswerBudgetIsTariffed() {
        #expect(CreditCostEstimate.baselineOutputTokens == 1_200)
        #expect(CreditCostEstimate.maximumOutputTokens == 8_000)
        #expect(CreditCostEstimate.credits(
            model: "gpt-5.6-sol", inputTokens: 100,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) == 9)
        #expect(CreditCostEstimate.credits(
            model: "gpt-5.4", inputTokens: 100,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) == 5)
        // This model's base already covers the bounded provider bill.
        #expect(CreditCostEstimate.credits(
            model: "gpt-5.4-mini", inputTokens: 100,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) == 2)
    }

    @Test("invalid and excessive output budgets follow the managed clamp")
    func outputBudgetIsClamped() {
        #expect(CreditCostEstimate.normalizedOutputBudget(nil) == 1_200)
        #expect(CreditCostEstimate.normalizedOutputBudget(-1) == 1_200)
        #expect(CreditCostEstimate.normalizedOutputBudget(1) == 256)
        #expect(CreditCostEstimate.normalizedOutputBudget(Int.max) == 8_000)
    }

    // MARK: - Layer: vision

    @Test("each attached image adds its own charge")
    func imagesAreCharged() {
        let base = CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100)
        #expect(CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100, imageCount: 1)
                == base + CreditCostEstimate.visionCreditsPerImage)
        #expect(CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100, imageCount: 3)
                == base + 3 * CreditCostEstimate.visionCreditsPerImage)
    }

    @Test("the image charge is capped, and a negative count cannot discount a prompt")
    func imageCountIsClamped() {
        let base = CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100)
        let capped = base + 8 * CreditCostEstimate.visionCreditsPerImage
        #expect(CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100, imageCount: 20) == capped)
        // The arithmetic must not run backwards on a bad count.
        #expect(CreditCostEstimate.credits(model: "gpt-5.4", inputTokens: 100, imageCount: -5) == base)
    }

    // MARK: - Layer: severity, judged against the balance

    @Test("with no balance to compare against, a price is stated but never alarmed")
    func noBalanceMeansNoAlarm() {
        // Direct-key builds, signed out, or a failed balance call. An alarm
        // here would be invented from nothing.
        #expect(CreditCostEstimate.severity(credits: 500, remaining: nil) == .routine)
        #expect(CreditCostEstimate.severity(credits: 500, remaining: 0) == .routine)
    }

    @Test("a prompt costing more than the balance is unaffordable")
    func overBalanceIsUnaffordable() {
        #expect(CreditCostEstimate.severity(credits: 11, remaining: 10) == .unaffordable)
    }

    @Test("severity is a share of what is left, not a fixed threshold")
    func severityScalesWithTheBalance() {
        // The whole point: 20 credits is trivial against 2,000 and alarming
        // against 100. A fixed token threshold fired constantly on big
        // balances, which taught people to ignore it.
        #expect(CreditCostEstimate.severity(credits: 20, remaining: 2_000) == .routine)
        #expect(CreditCostEstimate.severity(credits: 20, remaining: 100) == .notable)
    }

    @Test("the notable boundary is inclusive and does not flap around it")
    func severityBoundary() {
        let share = CreditCostEstimate.notableShareOfRemaining
        #expect(CreditCostEstimate.severity(credits: Int(100 * share), remaining: 100) == .notable)
        #expect(CreditCostEstimate.severity(credits: Int(100 * share) - 1, remaining: 100) == .routine)
    }

    // MARK: - Layer: the two tables must describe the same set of models

    @Test("every priced model has base, input, and output rates")
    func tablesCoverTheSameModels() {
        // A model listed in one table and missing from the other silently gets
        // the fallback for the other term — a wrong quote that looks deliberate.
        let base = Set(CreditCostEstimate.baseCredits.keys)
        let rates = Set(CreditCostEstimate.inputPerMillion.keys)
        let outputRates = Set(CreditCostEstimate.outputPerMillion.keys)
        let onlyBase = base.subtracting(rates).sorted()
        let onlyRates = rates.subtracting(base).sorted()
        #expect(base == rates,
                "only in baseCredits: \(onlyBase); only in inputPerMillion: \(onlyRates)")
        #expect(base == outputRates,
                "base/output table mismatch: \(base.symmetricDifference(outputRates).sorted())")
    }

    @Test("every model the app can actually select is priced")
    func catalogModelsArePriced() {
        // A model in the picker but not the table quotes the fallback price,
        // which is wrong in both directions depending on the model.
        for tier in [Tier.free, .pro, .premium, .ultra] {
            let selectable = LLMCatalog.available(for: tier)
            // Без этой строки проверка тихо вырождается: подними у всех моделей
            // minTier — и список для младшего уровня станет пустым, цикл не
            // выполнится ни разу, а тест останется зелёным. Каталог приезжает
            // сверху из Cruxwing, где уровни настоящие, так что это не
            // гипотеза, а обычный сценарий переноса.
            #expect(!selectable.isEmpty, "на уровне \(tier) не осталось моделей — проверять нечего")
            for model in selectable {
                #expect(CreditCostEstimate.baseCredits[model.id] != nil,
                        "\(model.id) is selectable on \(tier) but has no listed price")
            }
        }
    }

    @Test("prices are ordered sensibly: no flagship is cheaper than a mini")
    func pricingIsMonotonic() {
        let mini = CreditCostEstimate.baseCredits["gpt-4o-mini"] ?? 0
        for (model, credits) in CreditCostEstimate.baseCredits where !model.contains("mini") {
            #expect(credits >= mini, "\(model) costs \(credits), below the mini's \(mini)")
        }
    }
}
