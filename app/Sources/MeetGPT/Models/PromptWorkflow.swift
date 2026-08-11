import Foundation

/// The execution workflow behind a quick-prompt button. Where a `PromptSkill`
/// defines *how the model thinks*, a `PromptWorkflow` defines *how the button
/// runs*: which connected work-apps to ground from before drafting, and whether
/// the draft earns a second audit ("refine") pass before it's final.
///
/// Grounding sources follow the MIT-skills assessment's MCP-leverage findings
/// (docs/mit-skills-assessment.md): Tasks dedupes against live trackers, Summary
/// and Dispute anchor on prior Fireflies transcripts, Fact Check pulls the docs
/// and incident state it verifies against, etc. Grounding only runs for servers
/// that are actually connected — with nothing connected a button behaves exactly
/// as before (single skilled call), so there is zero added latency by default.
struct PromptWorkflow: Equatable, Sendable {
    /// The kind of connected information a prompt may need. This is kept on
    /// the workflow (rather than inferred from an app name at execution time)
    /// so custom MCP servers can be matched by their advertised tools too.
    enum SourceIntent: String, CaseIterable, Sendable {
        case calendar
        case documents
        case meetings
        case tasks
        case crm
        case incidents
        case teamChat
    }

    /// How the grounding search query is built (A4 — precision beats volume).
    /// `goal` is free; the other two spend one fast-model call to distill a
    /// sharper query from the recent transcript, falling back to `goal` when
    /// extraction yields nothing.
    enum QueryStrategy: Equatable, Sendable {
        /// The call goal (else the transcript tail) — broad, zero-cost.
        case goal
        /// The concrete topics/entities/ticket names being discussed right now —
        /// what trackers and docs should be searched for.
        case topics
        /// The checkable claims themselves — what a fact check must verify.
        case claims
    }

    /// Catalog server ids worth querying for this button (see MCPCatalog).
    let servers: Set<String>
    /// Read-only Google APIs worth consulting when their scopes are connected.
    /// These are direct APIs rather than MCP servers, so they stay separate
    /// from `servers` and can respect the user's granular OAuth grant.
    let googleServices: Set<GoogleService>
    /// Semantic source categories used to match arbitrary/custom MCP servers by
    /// their server name and tool capability text.
    let sourceIntents: Set<SourceIntent>
    /// Also query the token connectors (Slack, Confluence).
    let includeTeam: Bool
    /// Also inject the team's own recent Decision Ledger entries (A9): the
    /// cheapest, highest-signal continuity source — "we already decided this on
    /// June 12" — with no third-party dependency. Only fires when a backend is
    /// configured and the user is signed in.
    let includeLedger: Bool
    /// How to build this button's grounding query.
    let queryStrategy: QueryStrategy
    /// Per-source character budget — smaller for latency-sensitive buttons.
    let maxCharsPerSource: Int
    /// Audit instructions for a second pass over the draft; nil = draft is final.
    /// Used on buttons where the skill's quality bar is anti-fabrication
    /// (owners, dates, quotes) — the refine pass re-checks the draft against the
    /// transcript and fixes violations.
    let refine: String?

    /// Everything about this workflow that changes what grounding RETRIEVES.
    ///
    /// The grounding cache used to key on the prompt id, so blind spot, agenda
    /// and fact-check each re-queried the same sources for the same question.
    /// The id is not what shapes the result — these fields are — so two prompts
    /// that would fetch identical text now share one entry, and two that would
    /// not still cannot.
    var groundingShapeKey: String {
        let serverList = servers.sorted().joined(separator: ",")
        let googleList = googleServices.map(\.rawValue).sorted().joined(separator: ",")
        let intents = sourceIntents.map(\.rawValue).sorted().joined(separator: ",")
        let strategy: String
        switch queryStrategy {
        case .goal:   strategy = "goal"
        case .topics: strategy = "topics"
        case .claims: strategy = "claims"
        }
        // `refine` steers the connector query text, so it belongs here too.
        return [
            serverList, googleList, intents, strategy,
            includeTeam ? "team" : "-",
            includeLedger ? "ledger" : "-",
            String(maxCharsPerSource),
            refine ?? "-",
        ].joined(separator: "|")
    }

    init(servers: Set<String>, includeTeam: Bool = false, includeLedger: Bool = false,
         queryStrategy: QueryStrategy = .goal,
         maxCharsPerSource: Int = 3000, refine: String? = nil,
         googleServices: Set<GoogleService> = [],
         sourceIntents: Set<SourceIntent> = []) {
        self.servers = servers
        self.googleServices = googleServices
        self.sourceIntents = sourceIntents
        self.includeTeam = includeTeam
        self.includeLedger = includeLedger
        self.queryStrategy = queryStrategy
        self.maxCharsPerSource = maxCharsPerSource
        self.refine = refine
    }

    /// Return a copy expanded with newly relevant MCP server ids. Connection
    /// events use this to add a freshly connected custom server without losing
    /// the workflow's Google scopes, budgets, or audit policy.
    func addingServers(_ additionalServers: Set<String>) -> PromptWorkflow {
        PromptWorkflow(
            servers: servers.union(additionalServers),
            includeTeam: includeTeam,
            includeLedger: includeLedger,
            queryStrategy: queryStrategy,
            maxCharsPerSource: maxCharsPerSource,
            refine: refine,
            googleServices: googleServices,
            sourceIntents: sourceIntents
        )
    }
}

enum PromptWorkflows {
    static func spec(for promptID: String) -> PromptWorkflow? {
        byID[promptID]
    }

    /// Resolve every prompt button to a workflow. Built-ins keep their curated
    /// specs; saved custom buttons and generated follow-ups are classified
    /// deterministically from their visible title + instruction body.
    static func spec(for prompt: QuickPrompt) -> PromptWorkflow {
        if let builtIn = spec(for: prompt.id) { return builtIn }

        let intents = inferIntents(from: prompt.title + "\n" + prompt.prompt)
        guard !intents.isEmpty else { return transcriptOnlyWorkflow }

        var servers: Set<String> = []
        var googleServices: Set<GoogleService> = []
        var includeTeam = false

        for intent in intents {
            switch intent {
            case .calendar:
                googleServices.insert(.calendar)
            case .documents:
                servers.formUnion(["notion", "atlassian"])
                googleServices.formUnion([.docs, .sheets, .drive])
                includeTeam = true       // Confluence
            case .meetings:
                servers.formUnion(["fireflies", "zoom"])
            case .tasks:
                servers.formUnion(["linear", "asana", "atlassian"])
                includeTeam = true       // trackers
            case .crm:
                servers.formUnion(["hubspot", "affinity", "attio", "intercom", "zapier"])
            case .incidents:
                servers.formUnion(["sentry", "linear", "atlassian"])
            case .teamChat:
                includeTeam = true       // Slack
            }
        }

        let usesTopicSearch = !intents.isDisjoint(with: [.tasks, .incidents])
        return PromptWorkflow(
            servers: servers,
            includeTeam: includeTeam,
            queryStrategy: usesTopicSearch ? .topics : .goal,
            maxCharsPerSource: 2500,
            googleServices: googleServices,
            sourceIntents: intents
        )
    }

    /// Decide whether an MCP server can contribute to a workflow. Catalog ids
    /// are exact matches; arbitrary custom servers are selected only when their
    /// visible name or advertised tool text expresses a workflow intent.
    ///
    /// `toolText` deliberately accepts plain strings so this model layer does
    /// not import or depend on the MCP SDK's `Tool` type. Callers may join tool
    /// names and descriptions into one string.
    static func isRelevant(serverID: String,
                           serverName: String = "",
                           toolText: String = "",
                           for workflow: PromptWorkflow) -> Bool {
        let canonicalID = normalize(serverID).replacingOccurrences(of: " ", with: "")
        if workflow.servers.contains(where: {
            normalize($0).replacingOccurrences(of: " ", with: "") == canonicalID
        }) {
            return true
        }

        let advertisedIntents = inferIntents(from: [serverID, serverName, toolText]
            .joined(separator: "\n"))
        guard !advertisedIntents.isEmpty else { return false }
        return !relevantIntents(for: workflow).isDisjoint(with: advertisedIntents)
    }

    /// Convenience overload for callers that already have one capability string
    /// per tool (for example "search_issues Search project tickets").
    static func isRelevant(serverID: String,
                           serverName: String = "",
                           toolTexts: [String],
                           for workflow: PromptWorkflow) -> Bool {
        isRelevant(serverID: serverID, serverName: serverName,
                   toolText: toolTexts.joined(separator: "\n"), for: workflow)
    }

    /// Prompt-oriented convenience for execution and preview code.
    static func isRelevant(serverID: String,
                           serverName: String = "",
                           toolText: String = "",
                           for prompt: QuickPrompt) -> Bool {
        isRelevant(serverID: serverID, serverName: serverName,
                   toolText: toolText, for: spec(for: prompt))
    }

    /// Grounding query: the call goal when set, else the tail of the live
    /// transcript (what's being discussed right now). Pure for testability.
    static func groundingQuery(goal: String, recentTranscript: String) -> String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty { return trimmedGoal }
        let tail = recentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
        return String(tail)
    }

    /// System prompt for the fast-model query derivation (A4). nil for `.goal`
    /// (no derivation needed).
    static func derivationSystemPrompt(for strategy: PromptWorkflow.QueryStrategy) -> String? {
        switch strategy {
        case .goal:
            return nil
        case .topics:
            return """
            From the recent portion of a live meeting transcript, extract the 3-6 most searchable \
            concrete topics: project names, ticket ids, features, people, companies, deliverables \
            under discussion. Return ONLY a comma-separated list, at most 12 words total, no prose. \
            If nothing concrete is being discussed, return NONE.
            """
        case .claims:
            return """
            From the recent portion of a live meeting transcript, extract up to 3 concrete, \
            checkable factual claims (numbers, dates, commitments, named facts), most important \
            first. Return ONLY the claims joined by "; ", at most 40 words total, no prose. \
            If there are none, return NONE.
            """
        }
    }

    /// Clean a derived query: single line, no NONE sentinel, bounded length.
    /// nil means "fall back to the broad goal query".
    static func sanitizeDerivedQuery(_ raw: String, maxLength: Int = 300) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        guard !trimmed.isEmpty, trimmed.uppercased() != "NONE" else { return nil }
        guard trimmed.range(of: "\n") == nil else { return nil }
        guard trimmed.count <= maxLength else { return nil }
        return trimmed
    }

    /// Render grounding snippets as a context block for the user message.
    /// "2 minutes" / "31 minutes" — whole minutes, floor at one, because a
    /// cached source labelled "0 minutes ago" reads as fresh.
    static func minutesLabel(_ age: TimeInterval) -> String {
        let minutes = max(1, Int(age / 60))
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    static func renderGrounding(_ snippets: [GroundingSnippet],
                                query: String = "",
                                tier: Tier = Config.currentTier) -> String {
        let snippets = GroundingContextPolicy.optimizedSnippets(
            snippets, query: query, tier: tier)
        guard !snippets.isEmpty else { return "" }
        // `read for` is what makes a snippet evidence rather than more background.
        // Without it the model gets a wall of app output and treats every source
        // the same; with it, each one arrives with the question it answers.
        let blocks = snippets.map { snippet -> String in
            // A source served from cache because its app was unreachable says
            // so, in the header the model reads. Silently passing off half-hour
            // -old tracker state as current invites the worst failure this
            // pipeline has: the model reconciles the transcript against stale
            // data and reports the difference as a contradiction in the call.
            let freshness = snippet.staleAge.map { " · CACHED \(minutesLabel($0)) ago, app unreachable" } ?? ""
            guard let readFor = snippet.readFor, !readFor.isEmpty else {
                return "[\(snippet.serverName)\(freshness)] \(snippet.text)"
            }
            return "[\(snippet.serverName) · read for: \(readFor)\(freshness)]\n\(snippet.text)"
        }
        return "Live background from connected apps (use only if relevant, cite the app when you do). "
            + "Where a source carries \"read for\", that is the question it was pulled to answer — "
            + "if it contradicts the transcript, say so explicitly rather than averaging the two:\n"
            + blocks.joined(separator: "\n")
    }

    // MARK: - Custom/follow-up prompt inference

    /// Style-only or otherwise unrecognized custom prompts stay transcript-only.
    /// Fan-out requires an explicit source intent, preventing an innocent action
    /// such as "make this shorter" from querying every connected work app.
    private static let transcriptOnlyWorkflow = PromptWorkflow(servers: [])

    /// Intent phrases cover both human prompt copy and common MCP tool naming
    /// conventions. Matching is word/phrase bounded after camelCase, snake_case,
    /// and punctuation normalization, avoiding accidental substring matches.
    private static let intentKeywords: [PromptWorkflow.SourceIntent: Set<String>] = [
        .calendar: [
            "calendar", "calendars", "schedule", "schedules", "scheduling",
            "availability", "event", "events", "appointment", "appointments",
            "agenda", "agendas", "meeting time", "time slot", "time slots"
        ],
        .documents: [
            "doc", "docs", "document", "documents", "knowledge", "knowledge base",
            "notion", "confluence", "wiki", "spec", "specs", "brief", "briefs",
            "note", "notes", "research", "sheet", "sheets", "spreadsheet",
            "spreadsheets", "drive", "file", "files", "page", "pages", "handbook"
        ],
        .meetings: [
            "meeting", "meetings", "transcript", "transcripts", "recording",
            "recordings", "call", "calls", "fireflies", "zoom", "speaker",
            "speakers", "discussion", "discussions", "conversation", "conversations",
            "meeting minutes", "what was said"
        ],
        .tasks: [
            "task", "tasks", "project", "projects", "ticket", "tickets", "issue",
            "issues", "backlog", "sprint", "roadmap", "assignee", "assignees",
            "deadline", "deadlines", "action item", "action items", "jira", "linear",
            "asana", "repository", "repositories", "pull request",
            "pull requests", "milestone", "milestones", "work item", "work items"
        ],
        .crm: [
            "crm", "customer", "customers", "client", "clients", "account", "accounts",
            "deal", "deals", "lead", "leads", "pipeline", "renewal", "renewals",
            "churn", "contact", "contacts", "prospect", "prospects", "company", "companies",
            "hubspot", "attio", "affinity", "intercom", "salesforce", "sales"
        ],
        .incidents: [
            "incident", "incidents", "risk", "risks", "error", "errors", "bug", "bugs",
            "outage", "outages", "failure", "failures", "crash", "crashes", "sentry",
            "sev", "security", "vulnerability", "vulnerabilities", "blocker", "blockers",
            "alert", "alerts"
        ],
        .teamChat: [
            "team chat", "slack", "chat", "chats", "message", "messages",
            "thread", "threads", "channel", "channels", "team discussion", "discord",
            "microsoft teams"
        ]
    ]

    private static func inferIntents(from text: String) -> Set<PromptWorkflow.SourceIntent> {
        let searchable = " " + normalize(text) + " "
        return Set(intentKeywords.compactMap { intent, keywords in
            keywords.contains(where: { searchable.contains(" \($0) ") }) ? intent : nil
        })
    }

    private static func normalize(_ text: String) -> String {
        let splitCamelCase = text.replacingOccurrences(
            of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return splitCamelCase
            .folding(options: [.diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func relevantIntents(for workflow: PromptWorkflow) -> Set<PromptWorkflow.SourceIntent> {
        if !workflow.sourceIntents.isEmpty { return workflow.sourceIntents }

        var result: Set<PromptWorkflow.SourceIntent> = []
        for server in workflow.servers {
            switch normalize(server).replacingOccurrences(of: " ", with: "") {
            case "notion": result.insert(.documents)
            case "fireflies", "zoom": result.insert(.meetings)
            case "linear", "asana": result.insert(.tasks)
            case "atlassian": result.formUnion([.documents, .tasks])
            case "hubspot", "affinity", "attio", "intercom": result.insert(.crm)
            case "sentry": result.insert(.incidents)
            case "zapier": result.formUnion(PromptWorkflow.SourceIntent.allCases)
            default: break
            }
        }
        if workflow.googleServices.contains(.calendar) { result.insert(.calendar) }
        if !workflow.googleServices.isDisjoint(with: [.docs, .sheets, .drive]) { result.insert(.documents) }
        if workflow.includeTeam { result.insert(.teamChat) }
        return result
    }

    // MARK: - The per-button workflows

    static let byID: [String: PromptWorkflow] = [
        // Agenda: seed carry-overs from prior meetings + linked docs/trackers
        // + the team's own logged decisions.
        "agenda": PromptWorkflow(
            servers: ["fireflies", "zoom", "notion", "linear", "asana", "atlassian"],
            includeTeam: true, includeLedger: true,
            googleServices: [.calendar, .docs],
            sourceIntents: [.calendar, .documents, .meetings, .tasks, .teamChat]),
        // Brainstorm: parked ideas + committed work so nothing gets re-suggested.
        "brainstorm": PromptWorkflow(
            servers: ["fireflies", "linear", "asana", "atlassian", "hubspot", "attio"],
            includeTeam: true, googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .tasks, .crm, .teamChat]),
        // Unresolved: open tickets + incidents draw the blocked/parked line;
        // ledger decisions flag loops that reopen settled calls. Search by the
        // live topics, not the broad goal.
        "unresolved": PromptWorkflow(
            servers: ["fireflies", "zoom", "linear", "asana", "atlassian", "sentry"],
            includeTeam: true, includeLedger: true, queryStrategy: .topics,
            sourceIntents: [.meetings, .tasks, .incidents, .teamChat]),
        // What To Ask: prior transcript + docs mark already-settled assumptions.
        "whattoask": PromptWorkflow(
            servers: ["fireflies", "notion", "hubspot", "attio"], includeTeam: true,
            googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .crm, .teamChat]),
        // Fact Check: the sources claims get verified against (docs, incidents,
        // tickets, CRM) + Confluence via team connectors — queried by the
        // claims themselves, not the goal.
        "factcheck": PromptWorkflow(
            servers: ["notion", "fireflies", "sentry", "atlassian", "hubspot", "attio"],
            includeTeam: true, queryStrategy: .claims,
            googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .tasks, .crm, .incidents, .teamChat]),
        // Rhetoric: prior transcripts for self-contradiction checks.
        "rhetoric": PromptWorkflow(servers: ["fireflies"], sourceIntents: [.meetings]),
        // Answer: latency-sensitive — small per-source budget.
        "answer": PromptWorkflow(
            servers: ["notion", "fireflies", "hubspot", "attio"], maxCharsPerSource: 1500,
            googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .crm]),
        // Dispute: settle "what we agreed" from the team's own logged decisions
        // first, then transcripts/docs/tickets — searched by the disputed topic.
        "dispute": PromptWorkflow(
            servers: ["fireflies", "zoom", "notion", "linear", "atlassian"],
            includeTeam: true, includeLedger: true, queryStrategy: .topics,
            googleServices: [.docs],
            sourceIntents: [.documents, .meetings, .tasks, .teamChat]),
        // Risks: live incidents + blockers separate risks from issues — searched
        // by the plan's concrete topics.
        "risks": PromptWorkflow(
            servers: ["sentry", "linear", "atlassian", "asana", "fireflies"],
            includeTeam: true, queryStrategy: .topics,
            googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .tasks, .incidents, .teamChat]),
        // Advice: anchor first steps to open tickets + prior commitments.
        "advice": PromptWorkflow(
            servers: ["fireflies", "linear", "asana", "atlassian", "notion"],
            includeTeam: true, googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .tasks, .teamChat]),
        // Tasks: tracker state for dedupe (+Slack), searched by the live topics.
        // Anti-fabrication is enforced by the structured pipeline (A6):
        // ArtifactValidator + targeted repair replace the old blanket refine.
        // Goal inference (no button — runs once when the Co-pilot field is empty).
        // Prior calls are the strongest signal for what THIS one is for: a
        // recurring marketing sync reads as "raise qualified leads" only once
        // you have seen the last three. `.goal` strategy keeps it free — no
        // extra model call to build the query — and the budget is small because
        // the output is a single line, not a research answer.
        "goal": PromptWorkflow(
            servers: ["fireflies"], includeTeam: false, includeLedger: true,
            queryStrategy: .goal, maxCharsPerSource: 1200,
            sourceIntents: [.meetings, .documents]),
        "tasks": PromptWorkflow(
            servers: ["linear", "asana", "atlassian", "fireflies"], includeTeam: true,
            queryStrategy: .topics, googleServices: [.docs, .sheets, .drive],
            sourceIntents: [.documents, .meetings, .tasks, .teamChat]),
        // Log Decision: the ledger itself shows whether this reopens or
        // contradicts an earlier logged decision — searched by the decision's
        // topic. Latency-sensitive — small budget.
        "logdecision": PromptWorkflow(
            servers: ["fireflies", "notion"], includeTeam: true, includeLedger: true,
            queryStrategy: .topics, maxCharsPerSource: 1500, googleServices: [.docs],
            sourceIntents: [.documents, .meetings, .teamChat]),
        // Summary: prior-meeting continuity (incl. logged decisions).
        // Traceability is enforced by the structured pipeline (A6):
        // ArtifactValidator checks quotes verbatim against the transcript.
        "summary": PromptWorkflow(
            servers: ["fireflies", "zoom", "linear", "asana", "atlassian"],
            includeTeam: true, includeLedger: true,
            googleServices: [.calendar, .docs],
            sourceIntents: [.calendar, .documents, .meetings, .tasks, .teamChat]),
        // Steelman: the objections must bite on THIS room's situation, so ground
        // on the evidence a critic would reach for — prior decisions that already
        // settled part of it, and the docs/incidents behind the claims being made.
        // No refine: a weak objection costs the room a minute, and the skill's
        // own bar already forbids manufactured dissent.
        "steelman": PromptWorkflow(
            servers: ["fireflies", "notion", "atlassian", "sentry"],
            includeLedger: true, queryStrategy: .claims,
            googleServices: [.docs],
            sourceIntents: [.documents, .meetings, .incidents]),
        // Open commitments: this button is ONLY as good as its history, so it
        // pulls the widest continuity set — the ledger first (our own record),
        // then prior transcripts and every tracker. Topics strategy so the search
        // is about what is being discussed now, not the whole call goal.
        "commitments": PromptWorkflow(
            servers: ["fireflies", "zoom", "linear", "asana", "atlassian"],
            includeTeam: true, includeLedger: true, queryStrategy: .topics,
            refine: """
            Verify each listed commitment traces to a prior statement, ledger entry, or tracker \
            record present in the context — drop anything inferred. Anything without a verifiable \
            source must be marked UNCONFIRMED rather than reported as progress, and a commitment \
            passed over in silence on this call must stay flagged, not quietly resolved.
            """,
            sourceIntents: [.meetings, .tasks, .teamChat]),
        // Cross-meeting recall. The prior-meeting record is assembled LOCALLY
        // by DecisionRecallContext from saved sessions, so this spec is about
        // what else is worth having alongside it: our own ledger (the confirmed
        // decisions) and prior transcripts. Topics strategy, because the
        // question is about the subject under discussion rather than the whole
        // call goal. No tracker servers — a Linear ticket is not a record of
        // what a room decided, and pulling one invites the model to answer from
        // it.
        //
        // No inline refine, deliberately. A second pass costs a model call on
        // every press, and this button is meant to be asked casually and often.
        // It also does not need one the way `commitments` does: the answer is
        // grounded in verbatim excerpts that DecisionRecallContext puts into the
        // request, alongside an instruction to cite the meeting or admit the
        // record is silent. The evidence is already in front of the model.
        "recall": PromptWorkflow(
            servers: ["fireflies", "zoom"],
            includeTeam: false, includeLedger: true, queryStrategy: .topics,
            sourceIntents: [.meetings]),
    ]
}
