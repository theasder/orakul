import Foundation
import MCP

/// Write-back: turn a Tasks-button action item into a real tracker issue/task
/// (Linear / Jira / Asana) via an MCP tool-call — the one place MeetGPT writes
/// to a connected app, always behind the human-confirm the UI enforces. Tool
/// names and argument shapes are resolved from the server's LIVE schema (not
/// hardcoded), so a schema change degrades gracefully instead of mis-calling.
enum TaskWriteback {
    /// Per-server preferred create-tool names; anything not listed falls back to
    /// the `isCreateTool` name heuristic. These are the hosted-MCP trackers whose
    /// task creation we support.
    static let createToolPreferences: [String: [String]] = [
        "linear":    ["create_issue", "createIssue"],
        "atlassian": ["createJiraIssue", "jira_create_issue", "create_issue"],
        // V2 currently advertises the batch-shaped `create_tasks` tool. Keep
        // the singular spellings behind it because Asana explicitly says the
        // live tools/list schema is authoritative and tool names may evolve.
        "asana":     ["create_tasks", "create_task", "createTask"],
    ]

    /// True for servers we offer write-back on.
    static func supportsWriteback(_ serverID: String) -> Bool {
        createToolPreferences[serverID] != nil
    }

    /// Pick the create tool from a server's live tool list: a preferred name
    /// first, else the first tool that looks like an issue/task creator.
    static func pickCreateTool(from tools: [Tool], serverID: String) -> Tool? {
        for name in createToolPreferences[serverID] ?? [] {
            if let tool = tools.first(where: { $0.name == name }) { return tool }
        }
        return tools.first(where: { $0.isCreateTool })
    }

    /// Fold a task's metadata into a description block. Placeholder markers
    /// ("[OWNER?]", "[DUE?]") are dropped — never write an unstated value.
    static func describe(_ item: TasksArtifact.Item) -> String {
        var lines: [String] = []
        if let owner = item.owner, !owner.contains("[OWNER?]"), !owner.isEmpty {
            lines.append("Владелец: \(owner)")
        }
        if let due = item.due, !due.contains("[DUE?]"), !due.isEmpty {
            lines.append("Срок: \(due)")
        }
        if let check = item.doneCheck, !check.isEmpty { lines.append("Готово, когда: \(check)") }
        if let ref = item.sourceRef, !ref.isEmpty { lines.append("Источник: \(ref)") }
        lines.append("Заведено со звонка в orakul.")
        return lines.joined(separator: "\n")
    }

    /// Build the MCP tool arguments from a task + the tool's schema, merging any
    /// caller-supplied context (teamId / projectId chosen in the confirm UI —
    /// some trackers require it). nil when the schema exposes no string field to
    /// carry the title.
    static func buildArguments(for item: TasksArtifact.Item, tool: Tool,
                               extra: [String: Value] = [:]) -> [String: Value]? {
        // Asana V2's create_tasks input is { tasks: [{ name, ... }], ... }.
        // Resolve that shape from the live schema rather than special-casing
        // the server id, so a compatible schema continues to work if the tool
        // is renamed. Context such as project_id belongs to the task object;
        // default_project and other batch controls remain at the top level.
        if let taskProperties = tool.objectArrayItemProperties(for: "tasks"),
           let titleKey = taskProperties.stringPropertyKey(
               preferring: ["name", "title", "summary"]) {
            var task: [String: Value] = [titleKey: .string(item.task)]
            for key in ["description", "html_notes", "notes", "details"]
                where taskProperties[key] != nil {
                task[key] = .string(describe(item))
                break
            }

            var args: [String: Value] = [:]
            for (key, value) in extra {
                if taskProperties[key] != nil {
                    task[key] = value
                } else {
                    args[key] = value
                }
            }
            args["tasks"] = .array([.object(task)])
            return args
        }

        guard let titleKey = tool.stringArgumentKey(preferring: ["title", "summary", "name"]) else {
            return nil
        }
        var args: [String: Value] = [titleKey: .string(item.task)]
        // Fold the metadata into a description-like field when the schema has one.
        for key in ["description", "body", "content", "details"] where tool.hasArgument(key) {
            args[key] = .string(describe(item))
            break
        }
        // Caller-supplied context wins — it carries required identifiers.
        for (key, value) in extra { args[key] = value }
        return args
    }
}

extension Tool {
    /// Whether this looks like a tracker "create issue/task" tool.
    var isCreateTool: Bool {
        let n = name.lowercased()
        return n.contains("create") && (n.contains("issue") || n.contains("task"))
    }

    /// Properties of an object stored as the items of an array argument.
    /// JSON Schema producers do not consistently repeat `type: object`, so the
    /// structural `properties` member is the compatibility boundary here.
    func objectArrayItemProperties(for argument: String) -> [String: Value]? {
        guard let spec = schemaProperties?[argument],
              case .object(let arraySchema) = spec,
              case .object(let itemSchema)? = arraySchema["items"],
              case .object(let properties)? = itemSchema["properties"] else { return nil }
        return properties
    }
}

private extension Dictionary where Key == String, Value == MCP.Value {
    func stringPropertyKey(preferring preferred: [String]) -> String? {
        for name in preferred {
            guard let spec = self[name], case .object(let details) = spec,
                  case .string(let type)? = details["type"], type == "string" else { continue }
            return name
        }
        for (name, spec) in sorted(by: { $0.key < $1.key }) {
            if case .object(let details) = spec,
               case .string(let type)? = details["type"], type == "string" {
                return name
            }
        }
        return nil
    }
}

extension MCPConnectionManager {
    /// Connected tracker servers that actually expose a create tool right now —
    /// the valid write-back targets for the confirm UI.
    func writebackTargets() -> [MCPServerDescriptor] {
        researchableServers.filter { server in
            TaskWriteback.supportsWriteback(server.id)
                && TaskWriteback.pickCreateTool(from: tools(for: server.id), serverID: server.id) != nil
        }
    }

    /// Create a tracker issue/task from a meeting task via the server's create
    /// tool. Caller (the confirm UI) supplies any required context ids. Returns
    /// the tool's text result — usually the created item's URL or id.
    @discardableResult
    func createTrackerItem(_ item: TasksArtifact.Item, on server: MCPServerDescriptor,
                           extra: [String: Value] = [:],
                           requiredConnectionScope: UInt64? = nil) async throws -> String {
        if let requiredConnectionScope {
            try requireReviewedConnection(
                server, scope: requiredConnectionScope,
                acceptsOverrideTransport: false)
        } else if !isConnected(server.id) {
            await connect(server)
        }
        guard let tool = TaskWriteback.pickCreateTool(from: tools(for: server.id), serverID: server.id) else {
            throw MCPConnectionError.notConnected(server.name, "No task-creation tool is available.")
        }
        guard let args = TaskWriteback.buildArguments(for: item, tool: tool, extra: extra) else {
            throw MCPConnectionError.toolFailed(tool.name, "The tool schema has no title field.")
        }
        return try await callToolText(
            server: server,
            tool: tool.name,
            arguments: args,
            requiredConnectionScope: requiredConnectionScope)
    }
}
