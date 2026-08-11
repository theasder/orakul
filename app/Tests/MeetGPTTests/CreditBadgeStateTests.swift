import Foundation
import Testing
@testable import MeetGPT

/// What the credits rail says, and why it matters that it says the right thing.
///
/// Reported: "credits unavailable in the account where apps are connected,
/// even though I'm a developer using the dev promo code." Nothing was wrong
/// with the promo. The app had no Cruxwing account session at all — connected
/// apps are stored separately, so a workspace with Google, Notion and Asana
/// attached looked signed in — and the rail rendered that as "credits
/// unavailable", the same string it uses when the billing service is down.
///
/// One label for "sign in" and "we're broken" costs the reader an entire
/// debugging session, so the states are pinned apart here.
@Suite("Credit badge states")
struct CreditBadgeStateTests {

    @Test("signed out and service-down are different states with different words")
    func signedOutIsNotUnavailable() {
        #expect(CreditBadge.signedOut != CreditBadge.unavailable)
        for compact in [true, false] {
            let signedOut = CreditBadge.signedOut.label(compact: compact)
            let unavailable = CreditBadge.unavailable.label(compact: compact)
            #expect(signedOut != unavailable, "compact=\(compact)")
            #expect(signedOut.lowercased().contains("sign in"), "compact=\(compact): \(signedOut)")
        }
    }

    @Test("the signed-out state names an action; the failure state does not blame the user")
    func helpTextIsActionable() {
        #expect(CreditBadge.signedOut.isActionable)
        #expect(!CreditBadge.unavailable.isActionable)

        let signedOut = CreditBadge.signedOut.help.lowercased()
        #expect(signedOut.contains("sign in"))
        // The specific confusion to pre-empt: connected apps are a separate
        // sign-in, which is why the workspace looked authenticated.
        #expect(signedOut.contains("connected apps"))

        // A billing outage must not read as "you have no credits".
        let unavailable = CreditBadge.unavailable.help.lowercased()
        #expect(unavailable.contains("unaffected") || unavailable.contains("couldn't reach"))
    }

    @Test("no balance state ever renders as a credit count")
    func nonNumericStatesShowNoNumber() {
        for badge in [CreditBadge.loading, .stale, .signedOut, .unavailable] {
            for compact in [true, false] {
                let text = badge.label(compact: compact)
                #expect(!text.contains("0 cr"), "\(badge) rendered a zero balance: \(text)")
                #expect(!text.contains("0 credits"), "\(badge) rendered a zero balance: \(text)")
            }
        }
        // A real zero IS shown as a number — that is a balance, not an error.
        #expect(CreditBadge.remaining(0).label(compact: false).contains("0 credits"))
    }

    @Test("every state has a distinct compact and full label")
    func labelsAreDistinct() {
        let states: [CreditBadge] = [.loading, .remaining(5), .stale, .signedOut, .unavailable]
        for compact in [true, false] {
            let labels = states.map { $0.label(compact: compact) }
            #expect(Set(labels).count == labels.count,
                    "compact=\(compact) collides: \(labels)")
        }
        // notApplicable is the one state that renders nothing at all.
        #expect(CreditBadge.notApplicable.label(compact: true).isEmpty)
        #expect(!CreditBadge.notApplicable.isApplicable)
    }
}

/// The loader's phase transitions — which state each outcome lands in.
@Suite("Credit usage loader phases")
@MainActor
struct CreditUsageLoaderPhaseTests {

    private func loader(_ fetch: @escaping CreditUsageLoader.Fetch) -> CreditUsageLoader {
        CreditUsageLoader(fetch: fetch)
    }

    @Test("disabled means signed out, not unavailable")
    func disabledIsSignedOut() {
        // `refresh(enabled:)` is called with
        // `Config.llmViaBackend && state.wheesprConnected`. Both falsy paths
        // mean "there is nothing to ask" — which is not a failed request.
        let subject = loader { nil }
        subject.refresh(enabled: false)
        #expect(subject.phase == .signedOut)
        #expect(subject.usage == nil)
    }

    @Test("clearing on sign-out lands in signed out")
    func clearIsSignedOut() {
        let subject = loader { nil }
        subject.clear()
        #expect(subject.phase == .signedOut)
    }

    @Test("a failed fetch with no cached balance is unavailable, not signed out")
    func failureIsUnavailable() async {
        struct Boom: Error {}
        let subject = loader { throw Boom() }
        subject.refresh(enabled: true)
        // The request is dispatched to a Task; give it a turn to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(subject.phase == .unavailable)
    }

    /// Built by decoding, because PaywallUsage is a wire type — constructing it
    /// from JSON also checks the shape the server actually sends.
    private func usage(remaining: Int) throws -> PaywallUsage {
        let json = """
        {"tier":"pro",
         "allowances":{"copilotHours":20,"computeCredits":250,"groundedCycles":20},
         "used":{"computeCredits":8},
         "remaining":{"computeCredits":\(remaining)},
         "periodStart":"2026-08-01T00:00:00Z"}
        """
        return try JSONDecoder().decode(PaywallUsage.self, from: Data(json.utf8))
    }

    @Test("a successful fetch reports a fresh balance")
    func successIsFresh() async throws {
        let usage = try usage(remaining: 42)
        let subject = loader { usage }
        subject.refresh(enabled: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(subject.phase == .fresh)
        #expect(subject.usage?.remaining.computeCredits == 42)
    }
}
