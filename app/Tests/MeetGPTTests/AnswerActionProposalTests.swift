import Foundation
import Testing
@testable import MeetGPT

/// The three defects found by probing the planner with real tool names, plus
/// the guardrails on model-proposed actions.
@Suite("Answer action proposals")
struct AnswerActionProposalTests {

    private let taskAnswer = """
    Outcomes from the pricing call with the customer.

    - Draft the pricing page copy — owner: Ana, due Friday
    - Email the top 20 accounts about the change — owner: Bo, due next week
    - Update the billing FAQ — owner: Ana, due Friday
    """

    private let prose = String(
        repeating: "The rendering pipeline batches draw calls per frame. ", count: 8)

    private func capability(_ server: String, _ tool: String,
                            args: [String] = ["title", "description"],
                            required: [String] = ["title"]) -> AnswerActionPlanner.ToolCapability {
        AnswerActionPlanner.ToolCapability(
            serverID: server.lowercased(), serverName: server, toolName: tool,
            argumentKeys: args, requiredKeys: required)
    }

    // MARK: - Defect 1: CRM targeting

    @Test("CRM is offered only when the answer concerns a customer")
    func crmIsGated() {
        let hubspot = capability("HubSpot", "create_deal", args: ["name", "description"], required: ["name"])

        // Previously this scored 1 unconditionally and appeared under anything.
        #expect(AnswerActionPlanner.plan(answer: prose, capabilities: [hubspot]).isEmpty)
        #expect(!AnswerActionPlanner.plan(answer: taskAnswer, capabilities: [hubspot]).isEmpty)
    }

    @Test("customer language is what unlocks a CRM action")
    func customerDetection() {
        #expect(AnswerActionPlanner.concernsACustomer("the renewal is at risk"))
        #expect(AnswerActionPlanner.concernsACustomer("they raised a pricing objection"))
        #expect(!AnswerActionPlanner.concernsACustomer("the rendering pipeline batches draw calls"))
    }

    // MARK: - Defect 2: destination naming

    @Test("a meta-connector chip names the destination app, not the transport")
    func namesDestinationNotTransport() {
        #expect(AnswerActionPlanner.destination(ofTool: "slack_send_direct_message",
                                                serverName: "Zapier") == "Slack")
        #expect(AnswerActionPlanner.destination(ofTool: "google_calendar_create_detailed_event",
                                                serverName: "Zapier") == "Google Calendar")
    }

    @Test("a tool on its own app needs no destination prefix")
    func noRedundantDestination() {
        #expect(AnswerActionPlanner.destination(ofTool: "asana_create_task", serverName: "Asana") == nil)
        #expect(AnswerActionPlanner.destination(ofTool: "create_issue", serverName: "Linear") == nil)
        // "issue_create" describes the object, not an app called Issue.
        #expect(AnswerActionPlanner.destination(ofTool: "issue_create", serverName: "Linear") == nil)
    }

    @Test("the Zapier chip reads as the destination it writes to")
    func zapierChipTitle() {
        let zapier = AnswerActionPlanner.ToolCapability(
            serverID: "zapier", serverName: "Zapier", toolName: "slack_send_direct_message",
            argumentKeys: ["text"], requiredKeys: ["text"])
        let actions = AnswerActionPlanner.plan(answer: taskAnswer, capabilities: [zapier])
        #expect(actions.count == 1)
        #expect(actions[0].title == "Send Slack message via Zapier")
    }

    // MARK: - Defect 3: one item per action item

    @Test("a multi-item answer files N tasks, not one blob")
    func filesPerItem() {
        let actions = AnswerActionPlanner.plan(
            answer: taskAnswer, capabilities: [capability("Asana", "asana_create_task")])
        #expect(actions.count == 1)
        #expect(actions[0].isPerItem)
        #expect(actions[0].title == "Create 3 tasks in Asana")
    }

    @Test("a single-item answer stays a single write")
    func singleItemIsNotPerItem() {
        let answer = """
        One thing came out of the call, and it needs an owner so it does not drift.

        - Draft the pricing page copy — owner: Ana, due Friday
        """
        let actions = AnswerActionPlanner.plan(
            answer: answer, capabilities: [capability("Asana", "asana_create_task")])
        #expect(actions.count == 1)
        #expect(actions[0].isPerItem == false)
        #expect(actions[0].title == "Create task in Asana")
    }

    // MARK: - Item parsing

    @Test("parses owner and due out of a bullet")
    func parsesOwnerAndDue() {
        let items = AnswerActionItems.parse(taskAnswer)
        #expect(items.count == 3)
        #expect(items[0].task == "Draft the pricing page copy")
        #expect(items[0].owner == "Ana")
        #expect(items[0].due?.contains("Friday") == true)
    }

    @Test("checkboxes count even without an owner")
    func parsesCheckboxes() {
        let items = AnswerActionItems.parse("""
        - [ ] Ship the connector
        - [ ] Write the migration note
        """)
        #expect(items.count == 2)
        #expect(items[0].owner == nil)
    }

    @Test("a bulleted explanation yields no tasks")
    func prosebulletsYieldNothing() {
        let items = AnswerActionItems.parse("""
        - Usage-based pricing is simpler to explain
        - Seat pricing caps expansion revenue
        """)
        #expect(items.isEmpty)
    }

    @Test("never invents an owner that was not stated")
    func neverInventsOwner() {
        let items = AnswerActionItems.parse("- [ ] Ship the connector")
        #expect(items.count == 1)
        #expect(items[0].owner == nil)
        #expect(items[0].due == nil)
    }

    @Test("caps how many items one answer can file")
    func capsItems() {
        let many = (0..<40).map { "- [ ] Task number \($0)" }.joined(separator: "\n")
        #expect(AnswerActionItems.parse(many).count == AnswerActionItems.maxItems)
    }

    // MARK: - Proposer verification

    private let inventory = [
        AnswerActionPlanner.ToolCapability(
            serverID: "attio", serverName: "Attio", toolName: "create_record",
            argumentKeys: ["title", "content"], requiredKeys: ["title"])
    ]

    @Test("a well-formed proposal survives verification")
    func acceptsValidProposal() {
        let reply = """
        {"actions":[{"server":"attio","tool":"create_record","title":"Log the Acme renewal",\
        "why":"The call was about the Acme renewal","arguments":{"title":"Acme renewal","content":"Pricing objection raised."}}]}
        """
        let proposals = AnswerActionProposer.verify(reply, against: inventory)
        #expect(proposals.count == 1)
        #expect(proposals[0].action.title == "Log the Acme renewal")
        #expect(proposals[0].arguments["title"] == "Acme renewal")
        #expect(proposals[0].action.isProposed)
    }

    @Test("a hallucinated argument name discards the whole proposal")
    func rejectsUnknownArgument() {
        // One invented key means the model was guessing about this tool, so none
        // of its arguments can be trusted for it.
        let reply = """
        {"actions":[{"server":"attio","tool":"create_record","title":"Log it",\
        "arguments":{"title":"Acme","dealStage":"negotiation"}}]}
        """
        #expect(AnswerActionProposer.verify(reply, against: inventory).isEmpty)
    }

    @Test("a tool on no connected server is discarded")
    func rejectsUnknownTool() {
        let reply = """
        {"actions":[{"server":"salesforce","tool":"create_opportunity","title":"Log it",\
        "arguments":{"title":"Acme"}}]}
        """
        #expect(AnswerActionProposer.verify(reply, against: inventory).isEmpty)
    }

    @Test("a missing required argument is discarded rather than guessed")
    func rejectsMissingRequired() {
        let reply = """
        {"actions":[{"server":"attio","tool":"create_record","title":"Log it",\
        "arguments":{"content":"Pricing objection raised."}}]}
        """
        #expect(AnswerActionProposer.verify(reply, against: inventory).isEmpty)
    }

    @Test("a destructive proposal is refused even when the schema allows it")
    func refusesDestructiveProposal() {
        let destructive = [AnswerActionPlanner.ToolCapability(
            serverID: "attio", serverName: "Attio", toolName: "delete_record",
            argumentKeys: ["title"], requiredKeys: ["title"])]
        let reply = """
        {"actions":[{"server":"attio","tool":"delete_record","title":"Remove the stale record",\
        "arguments":{"title":"Acme"}}]}
        """
        #expect(AnswerActionProposer.verify(reply, against: destructive).isEmpty)
    }

    @Test("an empty or unparseable reply proposes nothing")
    func handlesEmptyReply() {
        #expect(AnswerActionProposer.verify(#"{"actions":[]}"#, against: inventory).isEmpty)
        #expect(AnswerActionProposer.verify("I could not think of anything.", against: inventory).isEmpty)
        #expect(AnswerActionProposer.verify("", against: inventory).isEmpty)
    }

    @Test("never returns more proposals than the cap")
    func capsProposals() {
        let one = """
        {"server":"attio","tool":"create_record","title":"T%@","arguments":{"title":"A%@"}}
        """
        let many = (0..<8).map { index in
            one.replacingOccurrences(of: "%@", with: String(index))
        }.joined(separator: ",")
        let proposals = AnswerActionProposer.verify("{\"actions\":[\(many)]}", against: inventory)
        #expect(proposals.count <= AnswerActionProposer.maxProposals)
    }

    @Test("the tool inventory names servers, tools and required arguments")
    func rendersInventory() {
        let text = AnswerActionProposer.inventory(inventory)
        #expect(text.contains("attio"))
        #expect(text.contains("create_record"))
        #expect(text.contains("title"))
        #expect(text.contains("required: title"))
    }
}
