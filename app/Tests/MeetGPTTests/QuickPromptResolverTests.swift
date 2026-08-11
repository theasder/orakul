import Foundation
import Testing
@testable import MeetGPT

/// Which quick prompts the configuration can actually run.
///
/// The named acceptance cases were: a disconnected CRM removes CRM-shaped
/// prompts, and an exhausted credit pool never offers a council. Both are here,
/// but the harder property is the one around them — the bias is toward SHOWING.
/// A button removed for a reason the app cannot state precisely teaches nobody
/// and looks like a missing feature, so anything merely uncertain stays and
/// fails honestly.
@Suite("Quick prompt resolver")
struct QuickPromptResolverTests {

    private func prompt(_ id: String) -> QuickPrompt {
        QuickPrompt(id: id, icon: "✨", title: id, tooltip: id, prompt: id)
    }

    private let everything = QuickPromptResolver.Configuration(
        tier: .ultra, connectorKeywords: ["crm", "tracker", "docs"], hasComputeCredits: true)

    // MARK: - The named acceptance cases

    @Test("a disconnected tracker removes the prompt that writes to one")
    func disconnectedTrackerRemovesTaskPrompt() {
        var configuration = everything
        configuration.connectorKeywords = ["crm", "docs"]

        let resolved = QuickPromptResolver.resolve([prompt("tasks"), prompt("summary")],
                                                   configuration: configuration)
        #expect(resolved.map(\.id) == ["summary"])
    }

    @Test("an exhausted credit pool never offers a council")
    func exhaustedPoolRemovesCouncil() {
        var configuration = everything
        configuration.hasComputeCredits = false

        let resolved = QuickPromptResolver.resolve([prompt("council"), prompt("summary")],
                                                   configuration: configuration)
        #expect(!resolved.map(\.id).contains("council"))
    }

    // MARK: - Reasons, not just counts

    @Test("says WHY a prompt was withheld")
    func reportsTheReason() {
        // The reason is returned rather than swallowed so the UI can say "3
        // more with a CRM connected" instead of silently showing fewer buttons.
        var configuration = everything
        configuration.connectorKeywords = []

        #expect(QuickPromptResolver.exclusion(for: "tasks", configuration: configuration)
                == .missingConnector("tracker"))
    }

    @Test("reports the tier a prompt needs, not merely that it is blocked")
    func reportsRequiredTier() {
        var configuration = everything
        configuration.tier = .free

        #expect(QuickPromptResolver.exclusion(for: "council", configuration: configuration)
                == .belowTier(.premium))
    }

    @Test("the connector reason wins when several apply")
    func reasonsHaveAStableOrder() {
        // A council on a free tier with an empty pool has two reasons. Reporting
        // one stable reason keeps the UI from saying the same absence twice.
        var configuration = everything
        configuration.tier = .free
        configuration.hasComputeCredits = false

        #expect(QuickPromptResolver.exclusion(for: "council", configuration: configuration)
                == .noComputeCredits)
    }

    @Test("lists everything withheld with its reason")
    func listsWithheld() {
        var configuration = everything
        configuration.connectorKeywords = []
        configuration.hasComputeCredits = false

        let withheld = QuickPromptResolver.withheld(
            [prompt("tasks"), prompt("council"), prompt("summary")],
            configuration: configuration)

        #expect(withheld.count == 2)
        #expect(!withheld.map(\.0.id).contains("summary"))
    }

    // MARK: - The bias toward showing

    @Test("a prompt with no requirements is always offered")
    func unconstrainedPromptsAlwaysShow() {
        let bare = QuickPromptResolver.Configuration(
            tier: .free, connectorKeywords: [], hasComputeCredits: false)

        let resolved = QuickPromptResolver.resolve(
            [prompt("summary"), prompt("agenda"), prompt("whattoask")],
            configuration: bare)
        // Most of the catalogue needs nothing. On the worst configuration the
        // bar must not empty out.
        #expect(resolved.count == 3)
    }

    @Test("an unknown prompt id is shown rather than hidden")
    func unknownPromptsAreShown() {
        // Custom user prompts, and any built-in added later without a
        // requirements entry. Defaulting to hidden would make a new prompt
        // invisible until someone remembered this table.
        let bare = QuickPromptResolver.Configuration(
            tier: .free, connectorKeywords: [], hasComputeCredits: false)
        #expect(QuickPromptResolver.resolve([prompt("custom-abc123")],
                                            configuration: bare).count == 1)
    }

    @Test("an empty catalogue resolves to nothing without complaint")
    func emptyInput() {
        #expect(QuickPromptResolver.resolve([], configuration: everything).isEmpty)
    }

    // MARK: - Matching

    @Test("connector matching ignores case")
    func connectorMatchingIsCaseInsensitive() {
        // Catalogue keywords and connected-app metadata are not consistently
        // cased, and a case mismatch would silently hide a working prompt.
        let configuration = QuickPromptResolver.Configuration(
            tier: .ultra, connectorKeywords: ["TRACKER"], hasComputeCredits: true)
        #expect(QuickPromptResolver.exclusion(for: "tasks", configuration: configuration) == nil)
    }

    @Test("tier comparison is by rank, not by name")
    func tierIsRanked() {
        for tier in [Tier.premium, .ultra] {
            var configuration = everything
            configuration.tier = tier
            #expect(QuickPromptResolver.exclusion(for: "council", configuration: configuration) == nil,
                    "\(tier) should clear a premium minimum")
        }
        for tier in [Tier.free, .pro] {
            var configuration = everything
            configuration.tier = tier
            #expect(QuickPromptResolver.exclusion(for: "council", configuration: configuration) != nil,
                    "\(tier) should not clear a premium minimum")
        }
    }

    @Test("credits gate only the prompts that actually spend them")
    func creditsGateOnlySpenders() {
        var configuration = everything
        configuration.hasComputeCredits = false

        // factcheck spends per claim; summary does not.
        #expect(QuickPromptResolver.exclusion(for: "factcheck", configuration: configuration)
                == .noComputeCredits)
        #expect(QuickPromptResolver.exclusion(for: "summary", configuration: configuration) == nil)
    }

    // MARK: - Order

    @Test("preserves catalogue order")
    func preservesOrder() {
        // The catalogue order is a deliberate sequence, and buttons that move
        // between calls cost more in muscle memory than any relevance gain
        // returns.
        let input = ["agenda", "summary", "whattoask", "risks"].map(prompt)
        let resolved = QuickPromptResolver.resolve(input, configuration: everything)
        #expect(resolved.map(\.id) == ["agenda", "summary", "whattoask", "risks"])
    }

    // MARK: - The real catalogue

    @Test("the shipped catalogue never empties, on the worst configuration")
    func realCatalogueSurvivesWorstCase() {
        // Free tier, nothing connected, no credits. Someone in that state must
        // still have a usable button bar.
        let worst = QuickPromptResolver.Configuration(
            tier: .free, connectorKeywords: [], hasComputeCredits: false)
        let resolved = QuickPromptResolver.resolve(QuickPrompts.all, configuration: worst)

        #expect(resolved.count >= QuickPrompts.all.count - QuickPromptResolver.requirements.count)
        #expect(!resolved.isEmpty)
    }

    @Test("every requirement names a prompt that exists or is a known future id")
    func requirementsAreNotStale() {
        // A requirement keyed to an id that no longer exists silently does
        // nothing, and would be found only by someone reading both files.
        let catalogueIDs = Set(QuickPrompts.all.map(\.id))
        let knownFuture: Set<String> = ["council"]
        for id in QuickPromptResolver.requirements.keys {
            #expect(catalogueIDs.contains(id) || knownFuture.contains(id),
                    "requirement for '\(id)' matches no prompt")
        }
    }
    // MARK: - Wiring

    @MainActor
    @Test("app state assembles a configuration the resolver can use")
    func stateProvidesConfiguration() {
        // A resolver nothing calls is worse than no resolver: the rules look
        // enforced and are not. This asserts the state seam exists and reads a
        // consistent snapshot.
        let state = AppState(credentialStore: InMemoryKeychain())
        let configuration = state.quickPromptConfiguration

        #expect(configuration.tier == state.currentTier)
        // No MCP manager in a bare state, so nothing is connected — and that
        // must be an empty set rather than a crash.
        #expect(configuration.connectorKeywords.isEmpty)
    }

    @MainActor
    @Test("a quota message is treated as an empty pool")
    func quotaMessageMeansNoCredits() {
        // copilotQuotaMessage is the app already knowing the pool is spent;
        // offering a council after that is offering a guaranteed failure.
        let state = AppState(credentialStore: InMemoryKeychain())
        #expect(state.quickPromptConfiguration.hasComputeCredits == (state.copilotQuotaMessage == nil))
    }

}

/// The mute integration: a muted app counts as ABSENT for prompt-offering.
///
/// The mute feature created a second definition of "available" — connected but
/// deliberately not consulted — and this is the seam where the two meet. A
/// tasks prompt offered on the strength of a muted tracker would either write
/// through an app the user just silenced or fail oddly on click.
@Suite("Muted apps and prompt offering")
struct MutedConnectorPromptTests {

    private let tracker = MCPServerDescriptor(
        id: "linear", name: "Linear",
        endpoint: URL(string: "https://mcp.linear.app/mcp")!,
        symbol: "square.grid.2x2", isCustom: false, keywords: ["tracker", "issues"])
    private let crm = MCPServerDescriptor(
        id: "attio", name: "Attio",
        endpoint: URL(string: "https://mcp.attio.com/mcp")!,
        symbol: "person.2", isCustom: false, keywords: ["crm"])

    @Test("a muted app's keywords are withheld")
    func mutedKeywordsAbsent() {
        let keywords = QuickPromptResolver.connectorKeywords(
            connected: [tracker, crm],
            muted: [Config.mutedAppID(mcpServer: "linear")])
        #expect(!keywords.contains("tracker"))
        #expect(keywords.contains("crm"), "muting one app must not silence another")
    }

    @Test("unmuting restores the keywords")
    func unmutedKeywordsReturn() {
        let keywords = QuickPromptResolver.connectorKeywords(
            connected: [tracker], muted: [])
        #expect(keywords.contains("tracker"))
        #expect(keywords.contains("issues"))
    }

    @Test("a muted tracker removes the tasks prompt end to end")
    func mutedTrackerRemovesTasksPrompt() {
        // Through the real resolver, not just the keyword set: the offered
        // buttons are what the user sees.
        let muted = QuickPromptResolver.Configuration(
            tier: .pro,
            connectorKeywords: QuickPromptResolver.connectorKeywords(
                connected: [tracker], muted: [Config.mutedAppID(mcpServer: "linear")]),
            hasComputeCredits: true)
        #expect(QuickPromptResolver.exclusion(for: "tasks", configuration: muted)
                == .missingConnector("tracker"))

        let live = QuickPromptResolver.Configuration(
            tier: .pro,
            connectorKeywords: QuickPromptResolver.connectorKeywords(
                connected: [tracker], muted: []),
            hasComputeCredits: true)
        #expect(QuickPromptResolver.exclusion(for: "tasks", configuration: live) == nil)
    }

    @Test("a mute id from another namespace never hides an MCP server")
    func namespacesStaySeparate() {
        // Muting the "google" app or a team connector named "linear" must not
        // reach the MCP server of the same name.
        let keywords = QuickPromptResolver.connectorKeywords(
            connected: [tracker],
            muted: ["google", Config.mutedAppID(team: "linear")])
        #expect(keywords.contains("tracker"))
    }
}
