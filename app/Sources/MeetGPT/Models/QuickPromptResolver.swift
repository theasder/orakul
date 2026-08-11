import Foundation

/// Which quick prompts to show, given the whole configuration.
///
/// Quick prompts already adapt to the recording type — a lecture gets learning
/// prompts, a meeting gets decision prompts. They ignore everything else the
/// app knows: whether a CRM is connected, whether the credit pool is spent,
/// which tier the account is on. So the button bar offers actions that cannot
/// run, and the failure arrives only after the click, as an error.
///
/// One resolver rather than conditions scattered through the view, because the
/// interesting cases are combinations — a CRM prompt on an exhausted pool has
/// two reasons to be absent and must not appear once for each.
///
/// The bias is toward SHOWING. A prompt is removed only when the app can say
/// concretely why it would fail; a hidden button teaches nobody, so anything
/// merely uncertain stays and fails honestly.
enum QuickPromptResolver {

    /// What a prompt needs before it is worth offering.
    struct Requirement: Equatable {
        /// Connector keyword that must be present — "crm", "tracker", "docs".
        /// Matched against the keywords the MCP catalogue already carries.
        var connectorKeyword: String?
        /// Spends from the compute pool, so it disappears when that is empty.
        var spendsComputeCredits: Bool
        /// Lowest tier that may run it.
        var minimumTier: Tier?

        init(connectorKeyword: String? = nil,
             spendsComputeCredits: Bool = false,
             minimumTier: Tier? = nil) {
            self.connectorKeyword = connectorKeyword
            self.spendsComputeCredits = spendsComputeCredits
            self.minimumTier = minimumTier
        }
    }

    /// Requirements by prompt id.
    ///
    /// Keyed by id rather than stored on `QuickPrompt` on purpose: that type is
    /// `Codable` and user-defined prompts are persisted with it, so adding a
    /// field would either break existing files or need another optional-decode
    /// migration for something the user never sets.
    static let requirements: [String: Requirement] = [
        // Writing to a tracker needs one connected.
        "tasks": Requirement(connectorKeyword: "tracker"),
        // A council run is the most expensive action in the product.
        "council": Requirement(spendsComputeCredits: true, minimumTier: .premium),
        // Fact-check spends compute on every claim it checks.
        "factcheck": Requirement(spendsComputeCredits: true),
    ]

    struct Configuration: Equatable {
        var tier: Tier
        /// Keywords of every CONNECTED app, lowercased.
        var connectorKeywords: Set<String>
        /// False when the compute pool is exhausted for this period.
        var hasComputeCredits: Bool

        init(tier: Tier = .free,
             connectorKeywords: Set<String> = [],
             hasComputeCredits: Bool = true) {
            self.tier = tier
            self.connectorKeywords = Set(connectorKeywords.map { $0.lowercased() })
            self.hasComputeCredits = hasComputeCredits
        }
    }

    /// Why a prompt was withheld. Returned rather than swallowed so the UI can
    /// explain an absence if it chooses to, and so a test can assert the
    /// REASON instead of only the count.
    enum Exclusion: Equatable {
        case missingConnector(String)
        case noComputeCredits
        case belowTier(Tier)
    }

    /// Whether this configuration can run the prompt, and why not if it cannot.
    static func exclusion(for promptID: String,
                          configuration: Configuration) -> Exclusion? {
        guard let requirement = requirements[promptID] else { return nil }

        if let keyword = requirement.connectorKeyword,
           !configuration.connectorKeywords.contains(keyword.lowercased()) {
            return .missingConnector(keyword)
        }
        if requirement.spendsComputeCredits, !configuration.hasComputeCredits {
            return .noComputeCredits
        }
        if let minimum = requirement.minimumTier,
           rank(configuration.tier) < rank(minimum) {
            return .belowTier(minimum)
        }
        return nil
    }

    /// The prompts worth offering, in the order given.
    ///
    /// Order is preserved rather than re-sorted: the catalogue order is a
    /// deliberate sequence, and shuffling buttons between calls costs more in
    /// muscle memory than any relevance gain gives back.
    static func resolve(_ prompts: [QuickPrompt],
                        configuration: Configuration) -> [QuickPrompt] {
        prompts.filter { exclusion(for: $0.id, configuration: configuration) == nil }
    }

    /// Everything withheld, with its reason — for a UI that wants to say "3
    /// more with a CRM connected" rather than silently showing fewer buttons.
    static func withheld(_ prompts: [QuickPrompt],
                         configuration: Configuration) -> [(QuickPrompt, Exclusion)] {
        prompts.compactMap { prompt in
            exclusion(for: prompt.id, configuration: configuration).map { (prompt, $0) }
        }
    }

    /// Keywords of the connected apps that are actually IN USE — connected,
    /// minus the ones the user muted for this call.
    ///
    /// Pure and here, rather than inline in AppState, because the mute feature
    /// created a second definition of "available" and this is where the two
    /// meet: a muted tracker is still connected, but a tasks prompt offered on
    /// its strength would either write through an app the user just silenced
    /// or fail oddly. Muted therefore counts as absent for prompt-offering,
    /// exactly as it does for grounding.
    static func connectorKeywords(connected: [MCPServerDescriptor],
                                  muted: Set<String>) -> Set<String> {
        var keywords: Set<String> = []
        for server in connected where !muted.contains(Config.mutedAppID(mcpServer: server.id)) {
            for keyword in server.keywords { keywords.insert(keyword.lowercased()) }
        }
        return keywords
    }

    private static func rank(_ tier: Tier) -> Int {
        switch tier {
        case .free: return 0
        case .pro: return 1
        case .premium: return 2
        case .ultra: return 3
        }
    }
}
