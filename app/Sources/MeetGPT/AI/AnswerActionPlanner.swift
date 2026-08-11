import Foundation

/// One-click actions offered underneath an answer, derived from what each
/// connected app ACTUALLY advertises rather than from a fixed list of apps.
///
/// The point is to close the gap between "the assistant told me what to do" and
/// "it is done". An answer listing four action items next to a connected tracker
/// is one click away from four issues; today that click is a copy, a browser and
/// a form.
///
/// Every offer is derived from the server's live tool schema — its name, its
/// description, and the arguments it declares. That is deliberate: hardcoding
/// "Linear means create_issue" works until Linear renames a tool, and offers
/// nothing at all for the custom MCP server someone added this morning. Reading
/// the schema means a newly connected app becomes actionable with no code
/// change, and a renamed tool stops being offered instead of being mis-called.
enum AnswerActionPlanner {

    /// A write-capable tool as advertised by a connected server. Plain strings
    /// so every rule here is testable without an MCP connection.
    struct ToolCapability: Equatable {
        let serverID: String
        let serverName: String
        let toolName: String
        let toolDescription: String
        /// Property names the tool's input schema declares.
        let argumentKeys: [String]
        /// Of those, the ones the schema marks required.
        let requiredKeys: [String]

        init(serverID: String, serverName: String, toolName: String,
             toolDescription: String = "", argumentKeys: [String] = [], requiredKeys: [String] = []) {
            self.serverID = serverID
            self.serverName = serverName
            self.toolName = toolName
            self.toolDescription = toolDescription
            self.argumentKeys = argumentKeys
            self.requiredKeys = requiredKeys
        }
    }

    /// Codable so an archived exchange can keep the actions planned from its
    /// own answer; every stored property is already a value type.
    struct Action: Identifiable, Equatable, Codable {
        let id: String
        let serverID: String
        let serverName: String
        let toolName: String
        /// Button text, e.g. "Create issue in Linear".
        let title: String
        let systemImage: String
        /// Why this was offered — shown on hover, so a surprising chip is
        /// explainable rather than mysterious.
        let rationale: String
        /// True when the answer enumerates work and this tool files work, so
        /// the action should create ONE item per action item rather than a
        /// single item containing the whole answer.
        let isPerItem: Bool
        /// Set when the model proposed this rather than the schema matcher.
        let isProposed: Bool

        /// Whether this action files trackable work — a task, issue or ticket.
        ///
        /// Derived from the same noun table that picks the label and icon, so
        /// a tool renamed there cannot drift away from this. Used to decide
        /// whether an answer that is itself a checklist may name the
        /// connection ("Turn these 5 into tasks").
        var createsTask: Bool {
            let noun = AnswerActionPlanner.label(forTool: toolName).noun
            return noun == "task" || noun == "issue" || noun == "ticket"
        }

        init(id: String, serverID: String, serverName: String, toolName: String,
             title: String, systemImage: String, rationale: String,
             isPerItem: Bool = false, isProposed: Bool = false) {
            self.id = id
            self.serverID = serverID
            self.serverName = serverName
            self.toolName = toolName
            self.title = title
            self.systemImage = systemImage
            self.rationale = rationale
            self.isPerItem = isPerItem
            self.isProposed = isProposed
        }
    }

    /// Answers shorter than this have nothing worth filing or sending.
    static let minimumAnswerChars = 120
    /// Ceiling on chips. Past three the row stops reading as "the obvious next
    /// step" and starts reading as a toolbar.
    static let maxActions = 3

    // MARK: - Verb classification

    /// Verbs that MUTATE something in the connected app. Only these are ever
    /// offered — a read tool under an answer does nothing the answer has not
    /// already done.
    private static let writeVerbs = [
        "create", "add", "send", "post", "append", "file", "schedule",
        "assign", "comment", "insert", "publish", "draft", "log", "record"
    ]

    /// Verbs that read. Checked first: several servers name tools like
    /// `get_or_create_page`, and treating that as a write is how you get a
    /// surprise mutation.
    private static let readVerbs = [
        "get", "list", "search", "fetch", "read", "query", "find",
        "retrieve", "describe", "lookup", "download", "export", "count"
    ]

    /// Verbs that destroy. Never offered from a one-click chip, whatever the
    /// answer says — a single misread click must not delete someone's data.
    private static let destructiveVerbs = [
        "delete", "remove", "archive", "close", "cancel", "revoke", "drop", "purge", "trash"
    ]

    /// Objects an ANSWER cannot become. Attachments and files need binary data
    /// we do not have; projects, databases and boards are containers, and
    /// creating one from a chip restructures somebody's workspace. Both shipped
    /// as real incidents from one call: `notion-create-attachment` was offered
    /// as "Create note in Notion" and failed schema validation, and
    /// `asana_create_project` was offered the same way and silently created a
    /// project — the fallback noun below labelled both as "note".
    private static let unfillableNouns = [
        "attachment", "file", "upload", "import", "project", "database",
        "webhook", "workspace", "repository", "repo", "board", "folder", "portfolio"
    ]

    /// The noun a tool acts on, mapped to how it should read and look. Longest
    /// match wins so `create_issue_comment` reads as a comment, not an issue.
    private static let nouns: [(fragment: String, label: String, symbol: String)] = [
        ("issue_comment", "comment", "text.bubble"),
        ("comment", "comment", "text.bubble"),
        // NOT a checkmark. A tick reads as "this is already done", which is the
        // opposite of a button that has not been pressed yet — the action is to
        // CREATE the task, not to complete it. The rest of the create actions
        // here are `.badge.plus`, so these join that family.
        ("issue", "issue", "text.badge.plus"),
        ("ticket", "ticket", "text.badge.plus"),
        ("task", "task", "text.badge.plus"),
        ("event", "event", "calendar.badge.plus"),
        ("meeting", "meeting", "calendar.badge.plus"),
        ("message", "message", "paperplane"),
        ("page", "page", "doc.badge.plus"),
        ("document", "document", "doc.badge.plus"),
        ("doc", "document", "doc.badge.plus"),
        ("note", "note", "note.text"),
        ("block", "note", "note.text"),
        ("record", "record", "tray.and.arrow.down"),
        ("deal", "deal", "briefcase"),
        ("contact", "contact", "person.crop.circle.badge.plus"),
        ("email", "email", "paperplane"),
        ("reminder", "reminder", "bell"),
        ("memo", "note", "note.text")
    ]

    /// Whether a tool writes something a chip could reasonably create.
    static func isOfferableWriteTool(name: String, description: String = "") -> Bool {
        let normalized = normalize(name)
        let tokens = normalized.split(separator: "_").map(String.init)

        if destructiveVerbs.contains(where: { tokens.contains($0) }) { return false }
        // An object we cannot fill from text disqualifies outright, before the
        // verb check — `create` + `attachment` is still not offerable.
        if unfillableNouns.contains(where: { tokens.contains($0) }) { return false }
        // A read verb anywhere in the name disqualifies: `get_or_create_x` is
        // ambiguous, and the safe reading of an ambiguous mutation is "do not".
        if readVerbs.contains(where: { tokens.contains($0) }) { return false }
        if writeVerbs.contains(where: { tokens.contains($0) }) { return true }

        // Fall back to the description only when the name is uninformative —
        // some servers name tools `linear_v2` and explain in prose.
        let prose = description.lowercased()
        guard !prose.isEmpty else { return false }
        if destructiveVerbs.contains(where: { prose.contains($0) }) { return false }
        return writeVerbs.contains { prose.hasPrefix($0) || prose.contains(" \($0) ") }
    }

    /// Server-aware write policy. Gmail's compose grant can technically send,
    /// but Cruxwing's post-connect feature is draft creation, never delivery.
    /// Keep generic send tools for explicitly connected chat/workflow apps while
    /// admitting only draft-shaped tools on the Gmail server.
    static func isOfferableWriteCapability(_ capability: ToolCapability) -> Bool {
        guard isOfferableWriteTool(
            name: capability.toolName, description: capability.toolDescription)
        else { return false }
        guard capability.serverID.lowercased() == "gmail" else { return true }
        let tool = normalize(capability.toolName)
        return tool.contains("draft") && !tool.contains("send")
    }

    /// Human label for a tool: "create_issue" in Linear becomes "Create issue".
    static func label(forTool name: String) -> (verb: String, noun: String, symbol: String) {
        let normalized = normalize(name)
        let tokens = normalized.split(separator: "_").map(String.init)
        let verb = writeVerbs.first(where: { tokens.contains($0) }) ?? "send"
        let matched = nouns.first { normalized.contains($0.fragment) }
        return (verb.capitalized, matched?.label ?? "note", matched?.symbol ?? "paperplane")
    }

    /// The noun that ACTUALLY matched, or nil. `label(forTool:)` papers over a
    /// miss with "note" for display; ranking must not — a chip whose object we
    /// cannot name is a chip whose click we cannot predict.
    static func matchedNoun(forTool name: String) -> String? {
        nouns.first { normalize(name).contains($0.fragment) }?.label
    }

    /// The app a tool actually writes to, when the tool name says so.
    ///
    /// Meta-connectors are the reason this exists. Zapier's server exposes one
    /// tool per configured Zap — `slack_send_direct_message`,
    /// `google_calendar_create_detailed_event` — so labelling by SERVER produces
    /// "Send message in Zapier" for something that posts to Slack. Zapier is the
    /// transport; the tokens before the verb are the destination.
    ///
    /// Returns nil when the tool carries no prefix (`create_issue`), or when the
    /// prefix just repeats the server (`asana_create_task` on Asana).
    static func destination(ofTool name: String, serverName: String) -> String? {
        let normalized = normalize(name)
        let tokens = normalized.split(separator: "_").map(String.init)
        guard let verbIndex = tokens.firstIndex(where: { writeVerbs.contains($0) }), verbIndex > 0 else {
            return nil
        }
        let prefix = tokens[0..<verbIndex]
        // A one-token prefix that is itself a noun we recognise is describing
        // the object, not an app ("issue_create" is not an app called Issue).
        if prefix.count == 1, nouns.contains(where: { $0.fragment == prefix[0] }) { return nil }

        let label = prefix.map { $0.capitalized }.joined(separator: " ")
        let compact = label.replacingOccurrences(of: " ", with: "").lowercased()
        let server = serverName.replacingOccurrences(of: " ", with: "").lowercased()
        // Same app: "Asana · asana_create_task" needs no "via".
        if server.contains(compact) || compact.contains(server) { return nil }
        return label
    }

    private static func normalize(_ name: String) -> String {
        // camelCase -> snake_case, then unify separators, so `createIssue`,
        // `create-issue` and `create_issue` classify identically.
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty, out.last != "_" { out.append("_") }
            out.append(Character(character.lowercased()))
        }
        return out.replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Fillability

    /// Argument names that can carry the answer's title.
    static let titleKeys = ["title", "summary", "name", "subject", "heading"]
    /// Argument names that can carry the answer's body.
    static let bodyKeys = ["description", "body", "content", "text", "message", "details", "note", "comment"]

    /// A tool is only offerable if the answer can actually fill it. Two rules:
    /// there has to be somewhere to PUT the answer, and every required argument
    /// has to be one this app can supply — a tool demanding `projectId` or
    /// `channel` needs a picker, and a chip that fails on click is worse than a
    /// chip that was never shown.
    static func isFillable(_ capability: ToolCapability) -> Bool {
        let keys = Set(capability.argumentKeys)
        // Hosted Notion's create-pages nests everything under a `pages` array,
        // so no flat title/body key exists. NotionExport knows the shape; the
        // commit path routes through it.
        if keys.contains("pages") { return true }
        let fillable = Set(titleKeys + bodyKeys)
        guard !keys.isEmpty, !keys.isDisjoint(with: fillable) else { return false }
        return capability.requiredKeys.allSatisfy { fillable.contains($0) }
    }

    // MARK: - Planning

    /// Rank and pick the actions worth offering for a finished answer.
    static func plan(answer: String, capabilities: [ToolCapability]) -> [Action] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumAnswerChars else { return [] }

        let candidates = capabilities
            .filter(isOfferableWriteCapability)
            .filter(isFillable)

        let ranked: [(capability: ToolCapability, score: Int)] = candidates
            .map { (capability: $0, score: relevance(of: $0, to: trimmed)) }
            .filter { $0.score > 0 }

        // Stable: score, then server, then tool — a chip row that reshuffles
        // between identical answers looks broken.
        let scored = ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.capability.serverID != rhs.capability.serverID {
                return lhs.capability.serverID < rhs.capability.serverID
            }
            return lhs.capability.toolName < rhs.capability.toolName
        }

        // At most one chip per server, so a server exposing eight write tools
        // cannot crowd out every other app.
        var seenServers: Set<String> = []
        var actions: [Action] = []
        let itemCount = AnswerActionItems.parse(trimmed).count
        for entry in scored {
            guard !seenServers.contains(entry.capability.serverID) else { continue }
            seenServers.insert(entry.capability.serverID)
            let parts = label(forTool: entry.capability.toolName)
            let destination = destination(ofTool: entry.capability.toolName,
                                          serverName: entry.capability.serverName)
            // Naming the destination, not just the transport: a Zapier tool that
            // posts to Slack must not read "Send message in Zapier".
            let title: String
            if let destination {
                title = "\(parts.verb) \(destination) \(parts.noun) via \(entry.capability.serverName)"
            } else {
                title = "\(parts.verb) \(parts.noun) in \(entry.capability.serverName)"
            }
            let perItem = ["issue", "ticket", "task"].contains(parts.noun) && itemCount > 1
            actions.append(Action(
                id: "\(entry.capability.serverID):\(entry.capability.toolName)",
                serverID: entry.capability.serverID,
                serverName: entry.capability.serverName,
                toolName: entry.capability.toolName,
                title: perItem
                    ? "\(parts.verb) \(itemCount) \(parts.noun)s in \(entry.capability.serverName)"
                    : title,
                systemImage: parts.symbol,
                rationale: rationale(for: entry.capability, answer: trimmed),
                isPerItem: perItem))
            if actions.count == maxActions { break }
        }
        return actions
    }

    /// How well a tool fits THIS answer. Zero means "do not offer".
    static func relevance(of capability: ToolCapability, to answer: String) -> Int {
        // No recognised object, no chip. The old fallback scored unknown nouns
        // as "note", which is how `asana_create_project` — tied on score,
        // earlier in the alphabet — beat `asana_create_task` and created a
        // project from an answer.
        guard let noun = matchedNoun(forTool: capability.toolName) else { return 0 }
        var score = 1  // fillable write tool on a connected app: always plausible

        switch noun {
        case "issue", "ticket", "task":
            // Only when the answer enumerates work someone has to do.
            guard containsActionableItems(answer) else { return 0 }
            score += 3
        case "event", "meeting":
            guard proposesFollowUpMeeting(answer) else { return 0 }
            score += 3
        case "deal", "contact", "record":
            // CRM used to fall through to the default and score 1 on ANY answer,
            // so "Create deal in HubSpot" appeared under prose with no customer
            // in it. Writing junk into a CRM is worse than most clutter — it is
            // shared, and somebody else has to clean it up.
            guard concernsACustomer(answer) else { return 0 }
            score += 3
        case "message", "comment":
            score += 1
        case "page", "document", "note":
            // Long answers are worth filing somewhere durable.
            if answer.count > 600 { score += 2 }
        default:
            break
        }
        return score
    }

    /// Whether the answer is about a customer, account or deal — the only case
    /// where offering to write to a CRM is not a guess.
    static func concernsACustomer(_ answer: String) -> Bool {
        let body = answer.lowercased()
        return customerMarkers.contains { body.contains($0) }
    }

    /// Deliberately excludes bare "pipeline" — it matches "rendering pipeline"
    /// and "CI pipeline" far more often than a sales one, and a false positive
    /// here writes junk into a CRM other people share.
    private static let customerMarkers = [
        "customer", "client", "deal", "prospect", "renewal",
        "contract", "pricing", "objection", "sales pipeline", "churn", "upsell",
        "procurement", "buyer", "vendor", "account manager", "the account"
    ]

    private static func rationale(for capability: ToolCapability, answer: String) -> String {
        let parts = label(forTool: capability.toolName)
        switch parts.noun {
        case "issue", "ticket", "task":
            return "This answer lists work with owners or dates — \(capability.serverName) can take it as \(parts.noun)s."
        case "event", "meeting":
            return "This answer proposes meeting again — \(capability.serverName) can schedule it."
        case "page", "document", "note":
            return "Saves the full answer into \(capability.serverName) via \(capability.toolName)."
        default:
            return "Sends the answer to \(capability.serverName) via \(capability.toolName)."
        }
    }

    // MARK: - Answer shape

    /// Whether the answer enumerates work someone has to do.
    ///
    /// Delegates to the same parser that FILES the items. They used to be
    /// separate heuristics, which meant the chip could appear claiming work
    /// existed while the parser found nothing to create — an action that opens a
    /// confirm sheet listing zero items. One source of truth removes that.
    static func containsActionableItems(_ answer: String) -> Bool {
        !AnswerActionItems.parse(answer).isEmpty
    }

    /// Whether the answer proposes meeting again — the only case where offering
    /// to create a calendar event is not a guess.
    static func proposesFollowUpMeeting(_ answer: String) -> Bool {
        let body = answer.lowercased()
        return ["next meeting", "follow-up meeting", "follow up meeting",
                "schedule a call", "reconvene", "next sync"].contains { body.contains($0) }
    }
}
