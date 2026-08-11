import Foundation
import MCP

/// Fail-closed policy for the one-click "Add source → Connected app" sheet.
///
/// Import is presented as a read: one click may copy context into Cruxwing, but
/// must never change the connected system. MCP annotations are only hints from
/// an untrusted server, so a `readOnlyHint` can strengthen a decision but can
/// never turn an ambiguous or write-shaped name into a safe tool.
enum MCPImportToolPolicy {
    /// Verbs whose presence means the tool may mutate external state. Exact
    /// normalized tokens avoid rejecting harmless words such as `settings` or
    /// `created_at`, while still catching snake_case, kebab-case and camelCase.
    private static let mutatingTokens: Set<String> = [
        "accept", "acknowledge", "activate", "add", "append", "approve", "assign",
        "attach", "block", "bookmark", "cancel", "change", "clear", "clone", "close",
        "comment", "complete", "connect", "copy", "create", "deploy", "disable",
        "disconnect", "dismiss", "draft", "duplicate", "edit", "enable", "execute",
        "favorite", "file", "follow", "forward", "grant", "hide", "import",
        "increment", "insert", "invite", "join", "label", "leave", "like", "link",
        "lock", "log", "mark", "merge", "message", "modify", "move", "mute",
        "mutate", "notify", "patch", "pin", "post", "promote", "publish", "put",
        "react", "record", "reject", "rename", "replace", "reply", "report",
        "resolve", "restore", "revoke", "run", "save", "schedule", "send", "set",
        "share", "start", "stop", "submit", "subscribe", "sync", "tag", "transfer",
        "trigger", "unarchive", "unblock", "unfollow", "unhide", "unlink", "unlock",
        "unmute", "unpin", "unsubscribe", "update", "upload", "upsert", "vote", "write"
    ]

    private static let destructiveTokens: Set<String> = [
        "archive", "ban", "delete", "destroy", "drop", "erase", "kick", "purge",
        "remove", "reset", "terminate", "trash", "wipe"
    ]

    /// A tool must positively identify itself as a read. Unknown verbs fail
    /// closed instead of being shown merely because no dangerous word matched.
    private static let readingTokens: Set<String> = [
        "check", "count", "describe", "download", "export", "fetch", "find",
        "get", "inspect", "list", "load", "lookup", "query", "read",
        "retrieve", "search", "show", "status", "view"
    ]

    /// Hosted GA4 names its read calls `run_report` / `run_realtime_report`.
    /// `run` is otherwise denied because it commonly executes an automation.
    private static let readOnlyRunObjects: Set<String> = ["report"]

    /// These words can be write verbs or ordinary read-result nouns. Ordering
    /// disambiguates them: `get_record` reads, while `record_call` writes.
    private static let nounLikeMutationTokens: Set<String> = [
        "comment", "draft", "file", "label", "log", "message", "record", "report"
    ]

    /// Prose is not structured enough for positional verb analysis. Reject
    /// explicit mutation language, but omit noun-like words ("returns a
    /// record") that are common in honest read-tool descriptions.
    private static let proseMutationTokens: Set<String> = [
        "add", "adds", "adding", "append", "appends", "appending", "approve",
        "approves", "assign", "assigns", "cancel", "cancels", "close", "closes",
        "connect", "connects", "copy", "copies", "create", "creates", "disable",
        "disables", "disconnect", "disconnects", "edit", "edits", "enable",
        "enables", "execute", "executes", "grant", "grants", "import", "imports",
        "insert", "inserts", "invite", "invites", "merge", "merges", "modify",
        "modifies", "modifying", "move", "moves", "mutate", "mutates", "patch",
        "patches", "post", "posts", "publish", "publishes", "put", "reject",
        "rejects", "rename", "renames", "revoke", "revokes", "schedule",
        "schedules", "send", "sends", "set", "sets", "share", "shares", "start",
        "starts", "stop", "stops", "subscribe", "subscribes", "trigger", "triggers",
        "unsubscribe", "unsubscribes", "update", "updates", "updating", "upload",
        "uploads", "upsert", "upserts", "write", "writes", "writing"
    ]

    static func isSafeForImport(_ tool: Tool) -> Bool {
        let nameTokens = tokens(in: tool.name)
        guard !nameTokens.isEmpty else { return false }

        // An explicit write/destructive annotation is a hard refusal. A true
        // readOnlyHint is not a hard grant: the MCP spec calls annotations
        // untrusted hints, and custom servers can be wrong or malicious.
        if tool.annotations.readOnlyHint == false || tool.annotations.destructiveHint == true {
            return false
        }

        let nameTokenSet = Set(nameTokens)
        let proseTokens = Set(tokens(in: tool.description ?? ""))
        if !nameTokenSet.isDisjoint(with: destructiveTokens)
            || !proseTokens.isDisjoint(with: destructiveTokens) {
            return false
        }

        // A read-looking name with a write clause (`get_or_create_page`) is
        // ambiguous and therefore unsafe. Description writes are denied too,
        // catching tools whose harmless name hides "updates the record".
        let isPinnedReportRead = nameTokens.first == "run"
            && !Set(nameTokens.dropFirst()).isDisjoint(with: readOnlyRunObjects)
        let alwaysMutating = mutatingTokens
            .subtracting(nounLikeMutationTokens)
            .subtracting(["run"])
        if !nameTokenSet.isDisjoint(with: alwaysMutating) { return false }
        let unsafeProse = proseMutationTokens
            .union(mutatingTokens.subtracting(nounLikeMutationTokens).subtracting(["run"]))
        if !proseTokens.isDisjoint(with: unsafeProse) { return false }

        if nameTokens.contains("run") && !isPinnedReportRead { return false }

        // `report_issue` reports (writes) an issue; `get_report` merely uses
        // report as the object and is read-shaped. Apply the same rule to
        // record/log/file/draft.
        let firstReadIndex = nameTokens.firstIndex { readingTokens.contains($0) }
        for (index, token) in nameTokens.enumerated()
            where nounLikeMutationTokens.contains(token) {
            if isPinnedReportRead && token == "report" { continue }
            guard let firstReadIndex, firstReadIndex < index else { return false }
        }

        return !nameTokenSet.isDisjoint(with: readingTokens)
            || isPinnedReportRead
    }

    static func filter(_ tools: [Tool]) -> [Tool] {
        tools.filter(isSafeForImport)
    }

    /// camelCase → snake_case, then split every non-alphanumeric separator.
    /// Keeping this here (rather than substring matching) is what makes
    /// `list_deleted_items` readable while `delete_items` remains forbidden.
    private static func tokens(in text: String) -> [String] {
        let camelSplit = text.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1_$2",
            options: .regularExpression)
        return camelSplit
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
