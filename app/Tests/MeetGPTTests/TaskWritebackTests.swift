import Foundation
import Testing
import MCP
@testable import MeetGPT

/// The schema-driven task write-back: tool discovery + argument mapping. Pure —
/// the live MCP call is a manual E2E against a connected tracker.
@Suite("Task write-back")
struct TaskWritebackTests {
    private func tool(_ name: String, props: [String: String] = ["title": "string"]) -> Tool {
        // Build an object input schema: { properties: { key: { type: ... } } }
        let properties = Value.object(props.mapValues { Value.object(["type": .string($0)]) })
        return Tool(name: name, description: nil, inputSchema: .object(["properties": properties]))
    }

    private func item(_ task: String, owner: String? = nil, due: String? = nil,
                      doneCheck: String? = nil, sourceRef: String? = nil) -> TasksArtifact.Item {
        TasksArtifact.Item(task: task, owner: owner, due: due, doneCheck: doneCheck,
                           dependency: nil, sourceRef: sourceRef, tracked: nil)
    }

    // MARK: tool discovery

    @Test("prefers the per-server tool name, else falls back to the create heuristic")
    func pickTool() {
        let linearTools = [tool("search_issues"), tool("create_issue"), tool("update_issue")]
        #expect(TaskWriteback.pickCreateTool(from: linearTools, serverID: "linear")?.name == "create_issue")

        // Unknown server, no preference — fuzzy match on name.
        let fuzzy = [tool("list_things"), tool("createTaskItem")]
        #expect(TaskWriteback.pickCreateTool(from: fuzzy, serverID: "unknown")?.name == "createTaskItem")

        // Nothing creatable.
        #expect(TaskWriteback.pickCreateTool(from: [tool("search"), tool("fetch")], serverID: "linear") == nil)
    }

    @Test("isCreateTool matches create+issue/task names only")
    func isCreateTool() {
        #expect(tool("create_issue").isCreateTool)
        #expect(tool("createTask").isCreateTool)
        #expect(tool("jira_create_issue").isCreateTool)
        #expect(tool("update_issue").isCreateTool == false)
        #expect(tool("search_tasks").isCreateTool == false)   // no "create"
        #expect(tool("create_page").isCreateTool == false)    // create, but not issue/task
    }

    @Test("supportsWriteback covers the tracker servers only")
    func supports() {
        #expect(TaskWriteback.supportsWriteback("linear"))
        #expect(TaskWriteback.supportsWriteback("atlassian"))
        #expect(TaskWriteback.supportsWriteback("asana"))
        #expect(TaskWriteback.supportsWriteback("notion") == false)
        #expect(TaskWriteback.supportsWriteback("fireflies") == false)
    }

    // MARK: description folding

    @Test("describe folds stated metadata and drops the unstated placeholders")
    func describe() {
        let full = TaskWriteback.describe(item("Ship the beta", owner: "Alex",
                                               due: "Friday", doneCheck: "deployed to prod",
                                               sourceRef: "10:32 decision"))
        #expect(full.contains("Владелец: Alex"))
        #expect(full.contains("Срок: Friday"))
        #expect(full.contains("Готово, когда: deployed to prod"))
        #expect(full.contains("Источник: 10:32 decision"))
        #expect(full.contains("orakul"))

        // Placeholder markers never become written values.
        let placeholders = TaskWriteback.describe(item("Do it", owner: "[OWNER?]", due: "[DUE?]"))
        #expect(placeholders.contains("Owner:") == false)
        #expect(placeholders.contains("Due:") == false)
    }

    // MARK: argument building

    @Test("maps the title to the schema's string field and folds metadata into description")
    func buildArgs() {
        let t = tool("create_issue", props: ["title": "string", "description": "string", "teamId": "string"])
        let args = TaskWriteback.buildArguments(for: item("Fix onboarding", owner: "Sam"), tool: t,
                                                extra: ["teamId": .string("TEAM-1")])
        #expect(args?["title"] == .string("Fix onboarding"))
        // description folded from metadata.
        if case .string(let desc)? = args?["description"] { #expect(desc.contains("Владелец: Sam")) }
        else { Issue.record("expected a description arg") }
        // caller context merged in.
        #expect(args?["teamId"] == .string("TEAM-1"))
    }

    @Test("uses summary as the title field when the schema has no title (Jira)")
    func buildArgsSummary() {
        let jira = tool("createJiraIssue", props: ["summary": "string", "projectKey": "string"])
        let args = TaskWriteback.buildArguments(for: item("Investigate crash"), tool: jira)
        #expect(args?["summary"] == .string("Investigate crash"))
        #expect(args?["description"] == nil)   // schema has no description field
    }

    @Test("returns nil when the schema exposes no string field for the title")
    func buildArgsNoTitle() {
        let weird = tool("create_issue", props: ["count": "integer"])
        #expect(TaskWriteback.buildArguments(for: item("x"), tool: weird) == nil)
    }
}
