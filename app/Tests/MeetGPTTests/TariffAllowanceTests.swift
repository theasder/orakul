import Testing
import Foundation
@testable import MeetGPT

// Reported from a real call: "after credits were over, features such as blind
// spot were still working". The server rejects an exhausted pool with 429, but
// the background loops swallowed the error with `try?` and kept re-dialing
// every cadence — nothing latched, nothing was surfaced.
@Suite("Credit exhaustion recognition")
struct CreditExhaustionTests {
    @Test("a 429 with the server's upgrade message latches, with the message")
    func recognizesQuota() {
        let error = LLMError.http(
            "Brainstorm", 429,
            #"{"error":"You need 2 compute credits, but only 0 remain this period — upgrade or add credits to continue.","upgrade":true}"#)
        let message = CreditExhaustion.quotaMessage(from: error)
        #expect(message?.contains("upgrade or add credits") == true)
        // The JSON envelope is unwrapped — a banner must not show raw JSON.
        #expect(message?.contains("{") == false)
    }

    @Test("other failures never latch the quota gate")
    func ignoresOtherErrors() {
        #expect(CreditExhaustion.quotaMessage(from: LLMError.http("Backend", 503, "down")) == nil)
        #expect(CreditExhaustion.quotaMessage(from: LLMError.http("Backend", 403, "tier gate")) == nil)
        #expect(CreditExhaustion.quotaMessage(from: LLMError.badResponse("Backend")) == nil)
        #expect(CreditExhaustion.quotaMessage(from: URLError(.timedOut)) == nil)
    }

    @Test("a 429 with no readable body still latches with a usable sentence")
    func fallbackMessage() {
        let message = CreditExhaustion.quotaMessage(from: LLMError.http("Backend", 429, ""))
        #expect(message?.isEmpty == false)
        #expect(message?.contains("credit") == true)
    }
}

@Suite("Tariff allowances")
struct TariffAllowanceTests {
    @Test("every tier exposes the commercial copilot, compute, and grounding limits")
    func allowanceMatrix() {
        #expect(TariffAllowance.forTier(.free) == .init(
            copilotHours: 2, computeCredits: 15, groundedCycles: 3))
        #expect(TariffAllowance.forTier(.pro) == .init(
            copilotHours: 20, computeCredits: 250, groundedCycles: 20))
        #expect(TariffAllowance.forTier(.premium) == .init(
            copilotHours: 40, computeCredits: 750, groundedCycles: 100))
        #expect(TariffAllowance.forTier(.ultra) == .init(
            copilotHours: 60, computeCredits: 1_500, groundedCycles: 300))
    }

    @Test("remaining copilot time includes the active recording and never goes negative")
    func copilotRemaining() {
        let pro = TariffAllowance.forTier(.pro)
        #expect(pro.remainingCopilotSeconds(usedSeconds: 3_600, activeSeconds: 600)
            == 20 * 3_600 - 4_200)
        #expect(pro.remainingCopilotSeconds(usedSeconds: 100_000, activeSeconds: 0) == 0)
    }

    @Test("grounded research is allowed only below the monthly cycle limit")
    func groundedLimit() {
        let free = TariffAllowance.forTier(.free)
        #expect(free.canRunGroundedCycle(used: 2))
        #expect(!free.canRunGroundedCycle(used: 3))
    }

    @Test("paid usage windows follow the subscription activation anchor")
    func billingAnchor() {
        let formatter = ISO8601DateFormatter()
        let anchor = formatter.date(from: "2026-01-15T10:00:00Z")!
        let now = formatter.date(from: "2026-07-11T12:00:00Z")!
        #expect(formatter.string(from: TariffPeriod.currentStart(anchor: anchor, now: now))
            == "2026-06-15T10:00:00Z")
    }
}

@Suite("Copilot cadence")
struct CopilotCadenceTests {
    @Test("expensive background lenses run on bounded cadences")
    func cadence() {
        #expect(CopilotCadence.blindSpotSeconds == 120)
        #expect(CopilotCadence.blindSpotPaidSeconds == 90)
        #expect(CopilotCadence.agendaSeconds == 300)
        #expect(CopilotCadence.factCheckSeconds == 300)
        #expect(CopilotCadence.rhetoricSeconds == 300)
        #expect(CopilotCadence.facilitationSeconds == 300)
        #expect(CopilotCadence.maxGroundingSources == 2)
    }

    @Test("all 16 Settings combinations reallocate only the funded hourly budget")
    func adaptiveBlindSpotCadenceBudget() {
        let tiers: [Tier] = [.free, .pro, .premium, .ultra]
        for tier in tiers {
            for mask in 0..<16 {
                let agenda = mask & 1 != 0
                let factCheck = mask & 2 != 0
                let rhetoric = mask & 4 != 0
                let facilitation = mask & 8 != 0
                let interval = CopilotCadence.blindSpotSeconds(
                    for: tier,
                    agendaEnabled: agenda,
                    factCheckEnabled: factCheck,
                    rhetoricEnabled: rhetoric,
                    facilitationEnabled: facilitation)
                let scans = 3_600 / Int(interval)
                let specialists = (factCheck ? 12 : 0)
                    + (agenda ? 4 : 0)
                    + (rhetoric ? 4 : 0)
                    + (facilitation ? 4 : 0)
                let spend = scans * CopilotCadence.blindSpotCreditsPerScan(for: tier)
                    + specialists
                #expect(spend <= CopilotCadence.copilotCreditsPerHour(for: tier),
                        "\(tier) mask \(mask) spent \(spend)")
            }
        }
    }

    @Test("disabling optional watches makes Blind Spot faster; all-on preserves tariffs")
    func adaptiveBlindSpotCadenceEndpoints() {
        let tiers: [Tier] = [.free, .pro, .premium, .ultra]
        let allOff = tiers.map {
            CopilotCadence.blindSpotSeconds(
                for: $0, agendaEnabled: false, factCheckEnabled: false,
                rhetoricEnabled: false, facilitationEnabled: false)
        }
        let allOn = tiers.map {
            CopilotCadence.blindSpotSeconds(
                for: $0, agendaEnabled: true, factCheckEnabled: true,
                rhetoricEnabled: true, facilitationEnabled: true)
        }
        let defaultAgendaOnly = tiers.map {
            CopilotCadence.blindSpotSeconds(
                for: $0, agendaEnabled: true, factCheckEnabled: false,
                rhetoricEnabled: false, facilitationEnabled: false)
        }

        #expect(allOff == [67, 75, 79, 82])
        #expect(defaultAgendaOnly == [72, 79, 80, 82])
        #expect(allOn == [CopilotCadence.blindSpotSeconds, 90, 90, 90])
        #expect(zip(allOff, allOn).allSatisfy { $0 <= $1 })
    }

    // MARK: - Agreement with the server

    @Test("every tier's allowance matches the shared contract")
    func allowancesMatchTheContract() {
        // These numbers were correct, but nothing checked them. The app held its
        // own copy and this suite asserted that copy against itself, so a server
        // change would have drifted silently — the user is billed by the server
        // and told what they have by the app, which is the worst pair to let
        // disagree.
        let contract = SharedContract.allowances
        guard !contract.isEmpty else { return }

        for (name, tier) in [("free", Tier.free), ("pro", .pro),
                             ("premium", .premium), ("ultra", .ultra)] {
            guard let expected = contract[name] else { continue }
            let actual = TariffAllowance.forTier(tier)
            #expect(actual.copilotHours == expected.copilotHours, "\(name) copilotHours")
            #expect(actual.computeCredits == expected.computeCredits, "\(name) computeCredits")
            #expect(actual.groundedCycles == expected.groundedCycles, "\(name) groundedCycles")
        }
    }

    @Test("the contract carries an annual plan for every paid tier")
    func annualPlansExist() {
        // Backlog item 23: the annual plans are SOLD but never offered. This
        // pins that they exist server-side, so the UI work is wiring rather
        // than billing, and so nobody removes them believing them unused.
        let plans = SharedContract.plans
        guard !plans.isEmpty else { return }

        for tier in ["pro", "premium", "ultra"] {
            let monthly = plans.first { $0.tier == tier && $0.interval == "month" }
            let annual = plans.first { $0.tier == tier && $0.interval == "year" }
            #expect(monthly != nil, "\(tier) monthly")
            #expect(annual != nil, "\(tier) annual")
            guard let monthly, let annual else { continue }
            // Ten monthly payments. If this ratio changes, item 24 decided the
            // discount depth and the marketing footnote must change with it.
            #expect(annual.priceCents == monthly.priceCents * 10,
                    "\(tier) annual is not ten monthly payments")
        }
    }
}
