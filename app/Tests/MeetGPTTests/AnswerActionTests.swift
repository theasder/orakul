import Foundation
import Testing
@testable import MeetGPT

/// One-click actions are derived from what each connected app ADVERTISES, not
/// from a hardcoded list of apps. These cover the two ways that goes wrong:
/// offering something destructive or unfillable (a chip that fails on click),
/// and offering nothing for a server whose tools are named unconventionally.
@Suite("Answer actions")
struct AnswerActionTests {

    private let taskAnswer = """
    Here is what came out of the call, with owners and dates so nothing is ambiguous.

    - Draft the pricing page copy — owner: Ana, due Friday
    - Email the top 20 accounts about the change — owner: Bo, due next week
    - Update the billing FAQ — owner: Ana, due Friday
    """

    private let proseAnswer = String(
        repeating: "Usage-based pricing shifts revenue recognition later in the quarter. ", count: 6)

    private func capability(_ server: String, _ tool: String,
                            args: [String] = ["title", "description"],
                            required: [String] = ["title"],
                            description: String = "") -> AnswerActionPlanner.ToolCapability {
        AnswerActionPlanner.ToolCapability(
            serverID: server.lowercased(), serverName: server, toolName: tool,
            toolDescription: description, argumentKeys: args, requiredKeys: required)
    }

    // MARK: - Write/read/destructive classification

    @Test("create and send tools are offerable")
    func offersWriteTools() {
        #expect(AnswerActionPlanner.isOfferableWriteTool(name: "create_issue"))
        #expect(AnswerActionPlanner.isOfferableWriteTool(name: "createIssue"))
        #expect(AnswerActionPlanner.isOfferableWriteTool(name: "create-page"))
        #expect(AnswerActionPlanner.isOfferableWriteTool(name: "send_message"))
        #expect(AnswerActionPlanner.isOfferableWriteTool(name: "append_block"))
    }

    @Test("read tools are never offered")
    func rejectsReadTools() {
        for name in ["get_issue", "list_issues", "search_pages", "fetch_document", "describe_project"] {
            #expect(!AnswerActionPlanner.isOfferableWriteTool(name: name), "\(name) should not be offerable")
        }
    }

    @Test("destructive tools are never offered, whatever the answer says")
    func rejectsDestructiveTools() {
        for name in ["delete_issue", "archive_page", "remove_task", "close_ticket", "purge_records"] {
            #expect(!AnswerActionPlanner.isOfferableWriteTool(name: name), "\(name) should not be offerable")
        }
    }

    @Test("objects an answer cannot become are never offered")
    func rejectsUnfillableObjects() {
        // Both halves of this shipped as one call's incidents:
        // notion-create-attachment was offered as "Create note in Notion" and
        // failed its schema; asana_create_project was offered the same way and
        // actually created a project.
        for name in ["notion-create-attachment", "asana_create_project", "upload_file",
                     "create_database", "create_webhook", "create_board"] {
            #expect(!AnswerActionPlanner.isOfferableWriteTool(name: name), "\(name) should not be offerable")
        }
    }

    @Test("a tool whose object is unrecognised ranks at zero")
    func unknownNounScoresZero() {
        // label() shows "note" for a miss; ranking must not follow it. The old
        // fallback let asana_create_project tie create_task and win on the
        // alphabet.
        let unknown = capability("Asana", "asana_create_gizmo", args: ["name", "description"])
        #expect(AnswerActionPlanner.matchedNoun(forTool: "asana_create_gizmo") == nil)
        #expect(AnswerActionPlanner.relevance(of: unknown, to: proseAnswer + proseAnswer) == 0)
        #expect(AnswerActionPlanner.plan(answer: proseAnswer + proseAnswer,
                                         capabilities: [unknown]).isEmpty)
    }

    @Test("hosted Notion's nested pages schema is fillable")
    func acceptsNotionPagesShape() {
        // No flat title/body keys — the payload nests under `pages`. The commit
        // path routes through NotionExport, so the planner must not reject it.
        let notion = capability("Notion", "notion-create-pages", args: ["pages"], required: ["pages"])
        #expect(AnswerActionPlanner.isFillable(notion))
        let actions = AnswerActionPlanner.plan(
            answer: String(repeating: "A long, durable answer worth keeping. ", count: 20),
            capabilities: [notion])
        #expect(actions.count == 1)
        #expect(actions.first?.toolName == "notion-create-pages")
        #expect(actions.first?.title == "Create page in Notion")
    }

    @Test("an ambiguous get-or-create tool is treated as a read")
    func rejectsAmbiguousTool() {
        // The safe reading of an ambiguous mutation is "do not".
        #expect(!AnswerActionPlanner.isOfferableWriteTool(name: "get_or_create_page"))
    }

    @Test("falls back to the description when the name says nothing")
    func usesDescriptionFallback() {
        #expect(AnswerActionPlanner.isOfferableWriteTool(
            name: "linear_v2", description: "Create an issue in the current team"))
        #expect(!AnswerActionPlanner.isOfferableWriteTool(
            name: "linear_v2", description: "List issues in the current team"))
    }

    @Test("labels read as a human verb and noun")
    func labelsTools() {
        let issue = AnswerActionPlanner.label(forTool: "create_issue")
        #expect(issue.verb == "Create")
        #expect(issue.noun == "issue")

        // Longest noun match wins so a comment is not filed as an issue.
        #expect(AnswerActionPlanner.label(forTool: "create_issue_comment").noun == "comment")
        #expect(AnswerActionPlanner.label(forTool: "postMessage").noun == "message")
    }

    // MARK: - Fillability

    @Test("a tool with nowhere to put the answer is not offered")
    func rejectsUnfillableTool() {
        let capability = capability("Linear", "create_issue", args: ["projectId", "labelIds"], required: [])
        #expect(!AnswerActionPlanner.isFillable(capability))
    }

    @Test("a tool requiring an identifier this app cannot supply is not offered")
    func rejectsToolNeedingPicker() {
        // A chip that fails on click is worse than one never shown.
        let capability = capability("Slack", "send_message",
                                    args: ["channel", "text"], required: ["channel", "text"])
        #expect(!AnswerActionPlanner.isFillable(capability))
    }

    @Test("a tool whose required fields are all fillable is offered")
    func acceptsFillableTool() {
        #expect(AnswerActionPlanner.isFillable(
            capability("Linear", "create_issue", args: ["title", "description"], required: ["title"])))
    }

    // MARK: - Planning

    @Test("an answer listing owned work offers issue creation")
    func plansTaskAction() {
        let actions = AnswerActionPlanner.plan(
            answer: taskAnswer,
            capabilities: [capability("Linear", "create_issue")])

        #expect(actions.count == 1)
        // Three bullets become three issues, not one issue holding the answer.
        #expect(actions[0].title == "Create 3 issues in Linear")
        #expect(actions[0].isPerItem)
        #expect(actions[0].toolName == "create_issue")
        #expect(!actions[0].rationale.isEmpty)
    }

    @Test("prose with no owned work does not offer issue creation")
    func doesNotPlanTasksForProse() {
        let actions = AnswerActionPlanner.plan(
            answer: proseAnswer,
            capabilities: [capability("Linear", "create_issue")])
        #expect(actions.isEmpty)
    }

    @Test("a calendar action appears only when the answer proposes meeting again")
    func plansEventOnlyWhenProposed() {
        let calendar = capability("Google Calendar", "create_event")

        #expect(AnswerActionPlanner.plan(answer: proseAnswer, capabilities: [calendar]).isEmpty)

        let withFollowUp = proseAnswer + "\n\nWe agreed to reconvene once legal has reviewed it."
        let actions = AnswerActionPlanner.plan(answer: withFollowUp, capabilities: [calendar])
        #expect(actions.count == 1)
        #expect(actions[0].title.contains("Google Calendar"))
    }

    @Test("a long answer can be saved to a document app")
    func plansPageAction() {
        let actions = AnswerActionPlanner.plan(
            answer: proseAnswer,
            capabilities: [capability("Notion", "create_page", args: ["title", "content"], required: ["title"])])
        #expect(actions.count == 1)
        #expect(actions[0].title == "Create page in Notion")
    }

    @Test("a short answer offers nothing at all")
    func skipsShortAnswers() {
        #expect(AnswerActionPlanner.plan(
            answer: "Yes.", capabilities: [capability("Linear", "create_issue")]).isEmpty)
    }

    @Test("no connected apps means no chips")
    func noCapabilitiesNoActions() {
        #expect(AnswerActionPlanner.plan(answer: taskAnswer, capabilities: []).isEmpty)
    }

    @Test("one server exposing many write tools gets one chip, not many")
    func onePerServer() {
        let actions = AnswerActionPlanner.plan(
            answer: taskAnswer,
            capabilities: [
                capability("Linear", "create_issue"),
                capability("Linear", "create_comment"),
                capability("Linear", "create_project")
            ])
        #expect(actions.count == 1)
    }

    @Test("never offers more chips than the cap")
    func respectsCap() {
        let servers = ["Linear", "Asana", "Notion", "Attio", "Intercom"]
        let actions = AnswerActionPlanner.plan(
            answer: taskAnswer,
            capabilities: servers.map { capability($0, "create_task") })
        #expect(actions.count <= AnswerActionPlanner.maxActions)
    }

    @Test("the same answer always produces the same chip order")
    func orderIsStable() {
        let capabilities = [
            capability("Notion", "create_page", args: ["title", "content"], required: ["title"]),
            capability("Linear", "create_issue"),
            capability("Asana", "create_task")
        ]
        let first = AnswerActionPlanner.plan(answer: taskAnswer, capabilities: capabilities)
        for _ in 0..<10 {
            #expect(AnswerActionPlanner.plan(answer: taskAnswer, capabilities: capabilities).map(\.id) == first.map(\.id))
        }
    }

    // MARK: - Answer shape

    @Test("markdown checkboxes count as actionable immediately")
    func detectsCheckboxes() {
        #expect(AnswerActionPlanner.containsActionableItems("- [ ] Ship the connector"))
    }

    @Test("a plain bulleted explanation is not a task list")
    func plainBulletsAreNotTasks() {
        #expect(!AnswerActionPlanner.containsActionableItems("""
        - Usage-based pricing is simpler to explain
        - Seat pricing caps expansion revenue
        """))
    }
}

/// Catalog discoverability. Several vendors sell one server covering several
/// products, so the product someone searches for is not the row they see.
@Suite("Connected app catalog")
struct MCPCatalogSearchTests {

    private func server(_ id: String) -> MCPServerDescriptor? {
        MCPCatalog.builtIn.first { $0.id == id }
    }

    @Test("Jira is findable, even though the row is called Atlassian")
    func findsJira() {
        let atlassian = server("atlassian")
        #expect(atlassian != nil)
        #expect(atlassian?.matches(search: "jira") == true)
        #expect(atlassian?.matches(search: "Jira") == true)
        #expect(atlassian?.matches(search: "confluence") == true)
    }

    @Test("a capability search surfaces every app that offers it")
    func findsByCapability() {
        let trackers = MCPCatalog.builtIn.filter { $0.matches(search: "tickets") }
        let ids = Set(trackers.map(\.id))
        #expect(ids.contains("linear"))
        #expect(ids.contains("atlassian"))

        let crms = MCPCatalog.builtIn.filter { $0.matches(search: "crm") }
        #expect(crms.contains { $0.id == "attio" })
    }

    @Test("an empty search shows everything")
    func emptySearchShowsAll() {
        #expect(MCPCatalog.builtIn.allSatisfy { $0.matches(search: "") })
        #expect(MCPCatalog.builtIn.allSatisfy { $0.matches(search: "   ") })
    }

    @Test("a term nobody offers matches nothing")
    func unknownTermMatchesNothing() {
        #expect(!MCPCatalog.builtIn.contains { $0.matches(search: "quickbooks") })
    }

    @Test("matching by name still works")
    func matchesByName() {
        #expect(server("notion")?.matches(search: "noti") == true)
    }
}
