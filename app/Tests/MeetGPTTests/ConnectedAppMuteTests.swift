import Foundation
import Testing
@testable import MeetGPT

/// Muting a connected app: still connected, still authorised, deliberately not
/// consulted.
///
/// The point is that different calls draw on different apps. Before this, the
/// only way to keep Notion out of a hiring call was to disconnect it and redo
/// the OAuth afterwards — so nobody did, and every call paid for every app.
///
/// The invariant that matters most is that muting is enforced at ONE place. Ten
/// call sites read `researchableServers`; if the filter lived at the call sites
/// instead, a new consumer would silently ignore the mute.
@MainActor
@Suite("Connected app mute", .serialized)
struct ConnectedAppMuteTests {

    private let previous = Config.mutedConnectedApps
    private func restore() { Config.mutedConnectedApps = previous }

    private func state() -> AppState {
        Config.mutedConnectedApps = []
        return AppState(credentialStore: InMemoryKeychain())
    }

    // MARK: - The default

    @Test("nothing is muted until the user mutes it")
    func defaultsToUsingEverything() {
        defer { restore() }
        // Opt-OUT: connecting an app is already the act of saying yes to it.
        // An opt-in set would ignore an app the user had just authorised.
        #expect(state().mutedAppIDs.isEmpty)
    }

    @Test("muting one app leaves the others alone")
    func mutingIsPerApp() {
        defer { restore() }
        let state = state()
        state.setApp("mcp:linear", muted: true)
        #expect(state.isAppMuted("mcp:linear"))
        #expect(!state.isAppMuted("mcp:notion"))
        #expect(!state.isAppMuted(Config.googleAppID))
    }

    @Test("unmuting restores it")
    func unmuting() {
        defer { restore() }
        let state = state()
        state.setApp("mcp:linear", muted: true)
        state.setApp("mcp:linear", muted: false)
        #expect(!state.isAppMuted("mcp:linear"))
        #expect(state.mutedAppIDs.isEmpty)
    }

    @Test("the choice survives a relaunch")
    func persists() {
        defer { restore() }
        let first = state()
        first.setApp("mcp:notion", muted: true)
        // A toggle that silently resets between calls is worse than one that
        // stays where it was put.
        #expect(AppState(credentialStore: InMemoryKeychain()).isAppMuted("mcp:notion"))
    }

    @Test("a no-op set does not churn")
    func idempotent() {
        defer { restore() }
        let state = state()
        state.setApp("mcp:notion", muted: false)   // already unmuted
        #expect(state.mutedAppIDs.isEmpty)
    }

    // MARK: - Mute is distinct from the master pause

    @Test("muting every app is not the same as pausing apps")
    func distinctFromGlobalPause() {
        defer { restore() }
        // They answer different questions — "not right now" versus "not this
        // app on this call" — and collapsing them would force someone who
        // wants Notion but not Linear to disconnect Linear.
        let state = state()
        let masterBefore = state.useConnectedAppsInPrompts
        state.setApp("mcp:notion", muted: true)
        #expect(state.useConnectedAppsInPrompts == masterBefore,
                "muting one app must not touch the master switch, whichever way it is set")
    }

    // MARK: - Namespacing

    @Test("ids are namespaced so the three kinds cannot collide")
    func idsAreNamespaced() {
        // A Linear MCP server and a team connector called "linear" are
        // different things and must be mutable independently.
        #expect(Config.mutedAppID(mcpServer: "linear") != Config.mutedAppID(team: "linear"))
        #expect(Config.mutedAppID(mcpServer: "linear") == "mcp:linear")
        #expect(Config.mutedAppID(team: "slack") == "team:slack")
        #expect(Config.googleAppID == "google")
    }

    @Test("muting Google does not mute an MCP server of the same name")
    func googleIsItsOwnID() {
        defer { restore() }
        let state = state()
        state.setApp(Config.googleAppID, muted: true)
        #expect(!state.isAppMuted(Config.mutedAppID(mcpServer: "google")))
    }
}

/// The filter itself, at the choke point every consumer already goes through.
@MainActor
@Suite("Muted servers are withheld from usage", .serialized)
struct MutedServerFilterTests {

    private let previous = Config.mutedConnectedApps

    private func manager() -> MCPConnectionManager {
        MCPConnectionManager(tokenStore: InMemoryKeychain(),
                             notificationCenter: NotificationCenter())
    }

    @Test("a muted server is withheld from researchableServers")
    func mutedIsWithheld() {
        defer { Config.mutedConnectedApps = previous }
        let mcp = manager()
        Config.mutedConnectedApps = []
        let before = Set(mcp.researchableServers.map(\.id))
        guard let victim = before.first else { return }   // no connected servers here

        Config.mutedConnectedApps = [Config.mutedAppID(mcpServer: victim)]
        #expect(!mcp.researchableServers.map(\.id).contains(victim))
    }

    @Test("a muted server STAYS in the display list")
    func mutedStaysVisible() {
        defer { Config.mutedConnectedApps = previous }
        let mcp = manager()
        Config.mutedConnectedApps = []
        let all = Set(mcp.researchableServersIncludingMuted.map(\.id))
        guard let victim = all.first else { return }

        Config.mutedConnectedApps = [Config.mutedAppID(mcpServer: victim)]
        // Vanishing from the strip would leave no way to unmute it.
        #expect(mcp.researchableServersIncludingMuted.map(\.id).contains(victim))
    }

    @Test("muting one server never withholds another")
    func mutingIsNarrow() {
        defer { Config.mutedConnectedApps = previous }
        let mcp = manager()
        Config.mutedConnectedApps = ["mcp:something-not-connected"]
        #expect(Set(mcp.researchableServers.map(\.id))
                == Set(mcp.researchableServersIncludingMuted.map(\.id)))
    }
}

/// What a brand-new user is told about credits.
@Suite("Signed-out credit label")
struct SignedOutCreditLabelTests {

    @Test("the signed-out label offers credits rather than hiding them")
    func offersRatherThanHides() {
        // "sign in to see credits" implies a balance exists and is being
        // withheld. For someone who has never signed in nothing is hidden —
        // there is an offer they have not taken, and the label should say so.
        // Only the full label carries the offer. The compact form stays
        // "sign in" — CreditBadgeStateTests requires both forms to name the
        // action, and a compact badge has no room for the reason as well.
        let label = CreditBadge.signedOut.label(compact: false)
        #expect(label.contains("free credits"))
        #expect(!label.contains("see credits"))
        #expect(CreditBadge.signedOut.label(compact: true).lowercased().contains("sign in"))
    }

    @Test("a real balance still reads as a number")
    func balanceStillWins() {
        // The fix must not leak into the state that HAS an answer.
        #expect(CreditBadge.remaining(12).label(compact: false).contains("12"))
        #expect(!CreditBadge.remaining(12).label(compact: false).contains("free credits"))
    }

    @Test("signed-out stays distinguishable from unavailable")
    func signedOutIsNotUnavailable() {
        // Only one of the two is fixable by signing in, and conflating them
        // once sent someone hunting a promo-code bug that did not exist.
        #expect(CreditBadge.signedOut.isActionable)
        #expect(!CreditBadge.unavailable.isActionable)
        #expect(CreditBadge.signedOut.label(compact: false)
                != CreditBadge.unavailable.label(compact: false))
    }
}

/// What an anonymous trial user is told about credits.
///
/// The whole point of the codeless trial is that a first-time user has credits
/// without an account. Telling them to "sign in for free credits" while they
/// are spending free credits is the failure this pins shut.
@Suite("Trial credit badge")
struct TrialCreditBadgeTests {

    @Test("the badge leads with what the user HAS")
    func leadsWithTheBalance() {
        let label = CreditBadge.trial(remaining: 12, monthly: 15).label(compact: false)
        #expect(label.contains("12"))
        // The number comes before the ask, in both label forms.
        let credits = try! #require(label.range(of: "12"))
        let signUp = try! #require(label.range(of: "sign up"))
        #expect(credits.lowerBound < signUp.lowerBound)
    }

    @Test("the upsell names the monthly number, not a vague 'more'")
    func namesTheMonthlyNumber() {
        // A trial grant is one-off, so the difference is not three credits —
        // it is three credits EVERY MONTH versus never again.
        let label = CreditBadge.trial(remaining: 12, monthly: 15).label(compact: false)
        #expect(label.contains("15"))
        #expect(label.contains("month"))
    }

    @Test("an unknown monthly allowance degrades instead of inventing one")
    func degradesWithoutTheCatalogue() {
        // The number is an entitlement the server enforces. Printing a guess
        // would eventually promise something the backend will not deliver.
        let label = CreditBadge.trial(remaining: 12, monthly: nil).label(compact: false)
        #expect(label.contains("12"))
        #expect(label.contains("every month"))
        #expect(!label.contains("15"))
    }

    @Test("the compact form keeps the balance and the action")
    func compactKeepsBoth() {
        let label = CreditBadge.trial(remaining: 12, monthly: 15).label(compact: true)
        #expect(label.contains("12"))
        #expect(label.lowercased().contains("sign up"))
    }

    @Test("a trial never renders as the signed-out prompt")
    func neverSaysSignInForFreeCredits() {
        // The bug in one line: someone spending free credits being told to
        // sign in to get free credits.
        let label = CreditBadge.trial(remaining: 12, monthly: 15).label(compact: false)
        #expect(!label.contains("sign in for free credits"))
        #expect(CreditBadge.trial(remaining: 12, monthly: 15) != .signedOut)
    }

    @Test("the hover text admits the credits do not renew")
    func helpNamesTheCatch() {
        // The one thing a balance alone never says.
        let help = CreditBadge.trial(remaining: 12, monthly: 15).help.lowercased()
        #expect(help.contains("не восполняется"))
        #expect(help.contains("аккаунт не нужен"))
    }

    @Test("a trial is actionable, like signed-out and unlike a broken balance")
    func actionable() {
        #expect(CreditBadge.trial(remaining: 12, monthly: 15).isActionable)
        #expect(!CreditBadge.unavailable.isActionable)
    }

    // MARK: - Telling a trial account from a real one

    @Test("the synthetic trial address identifies a device trial")
    func detectsTrialSession() {
        // The server cannot answer this: a trial reports tier "free" and
        // overrides only the allowances.
        #expect(session(email: "trial+abc@device.cruxwing.local").isDeviceTrial)
        #expect(session(email: "TRIAL+ABC@DEVICE.CRUXWING.LOCAL").isDeviceTrial)
    }

    @Test("a real account is never mistaken for a trial")
    func realAccountIsNotATrial() {
        #expect(!session(email: "someone@gmail.com").isDeviceTrial)
        #expect(!session(email: "").isDeviceTrial)
        // A lookalike domain must not match — the suffix is anchored.
        #expect(!session(email: "a@device.cruxwing.local.evil.com").isDeviceTrial)
    }

    private func session(email: String) -> WheesprSession {
        WheesprSession(accessToken: "a", refreshToken: "r",
                       accessExpiry: Date().addingTimeInterval(900),
                       email: email, displayName: nil)
    }
}
