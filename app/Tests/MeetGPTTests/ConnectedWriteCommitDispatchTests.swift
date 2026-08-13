import Foundation
import MCP
import Testing
@testable import MeetGPT

@MainActor
private final class FakeConnectedTool: AnswerActionDispatching {
    enum Failure: LocalizedError {
        case rejected

        var errorDescription: String? {
            "Fake connector rejected the edited payload."
        }
    }

    private(set) var requests: [AnswerActionDispatchRequest] = []
    var result = "accepted"
    var failure: Failure?
    var pausesBeforeResult = false
    var onDispatch: ((Int) -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    func dispatch(_ request: AnswerActionDispatchRequest) async throws -> String {
        requests.append(request)
        onDispatch?(requests.count)
        if pausesBeforeResult {
            await withCheckedContinuation { continuation = $0 }
        }
        if let failure { throw failure }
        return result
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite("Connected write commit dispatch")
struct ConnectedWriteCommitDispatchTests {
    private struct FieldScenario {
        let id: String
        let serverName: String
        let toolName: String
        let original: [String: String]
        let edited: [String: String]
    }

    private func pending(
        id: String,
        serverName: String,
        toolName: String,
        fields: [String: String] = [:],
        items: [TasksArtifact.Item] = [],
        connectionScope: UInt64? = nil
    ) -> AppState.PendingAnswerAction {
        let action = AnswerActionPlanner.Action(
            id: "\(id):\(toolName)",
            serverID: id,
            serverName: serverName,
            toolName: toolName,
            title: "Create in \(serverName)",
            systemImage: "square.and.arrow.up",
            rationale: "The user requested this connected write.",
            isPerItem: !items.isEmpty)
        return AppState.PendingAnswerAction(
            id: action.id,
            action: action,
            fields: fields,
            fieldOrder: fields.keys.sorted(),
            items: items,
            connectionScope: connectionScope)
    }

    @Test("edited confirmation dispatches exactly once for document, CRM, calendar, and Gmail-draft shapes")
    func editedFieldPayloadMatrix() async {
        let scenarios = [
            FieldScenario(
                id: "notion", serverName: "Notion", toolName: "create_page",
                original: ["title": "Original notes", "content": "Original body"],
                edited: ["title": "Edited launch notes", "content": "Decision: ship Friday."]),
            FieldScenario(
                id: "hubspot", serverName: "HubSpot", toolName: "create_record",
                original: ["name": "Old opportunity", "note": "Old note"],
                edited: ["name": "Falcon renewal", "note": "Buyer requested a security review."]),
            FieldScenario(
                id: "google-calendar", serverName: "Google Calendar", toolName: "create_event",
                original: ["title": "Follow-up", "details": "TBD", "start": "2026-08-08T09:00:00Z"],
                edited: ["title": "Falcon technical review", "details": "Include platform team", "start": "2026-08-10T14:30:00Z"]),
            FieldScenario(
                id: "gmail", serverName: "Gmail", toolName: "create_draft",
                original: ["subject": "Follow-up", "body": "Original draft"],
                edited: ["subject": "Falcon next steps", "body": "Thanks — here are the agreed actions."]),
        ]

        for scenario in scenarios {
            let fake = FakeConnectedTool()
            fake.result = "created https://fake.connected/\(scenario.id)/42"
            let state = AppState(
                credentialStore: InMemoryKeychain(),
                answerActionDispatcher: fake)
            let staged = pending(
                id: scenario.id,
                serverName: scenario.serverName,
                toolName: scenario.toolName,
                fields: scenario.original)
            state.pendingAnswerAction = staged

            state.applyConfirmEdits(fields: scenario.edited, items: [])
            await state.commitAnswerAction()

            #expect(fake.requests == [AnswerActionDispatchRequest(
                action: staged.action,
                payload: .fields(scenario.edited))], "\(scenario.id) must receive exactly the edited payload once")
            #expect(state.answerActionResult ==
                "Created in \(scenario.serverName) — https://fake.connected/\(scenario.id)/42")
            #expect(state.pendingAnswerAction == nil)
            #expect(state.runningAnswerAction == nil)
        }
    }

    @Test("an edited tracker item dispatches exactly once")
    func editedTrackerItemDispatchesOnce() async {
        let fake = FakeConnectedTool()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            answerActionDispatcher: fake)
        let original = TasksArtifact.Item(
            task: "Draft launch plan", owner: "[OWNER?]", due: "[DUE?]",
            doneCheck: nil, dependency: nil, sourceRef: "00:13", tracked: false)
        let edited = TasksArtifact.Item(
            task: "Publish the launch plan", owner: "Mina", due: "Friday",
            doneCheck: "Launch plan is shared", dependency: nil,
            sourceRef: "00:13", tracked: false)
        let staged = pending(
            id: "linear", serverName: "Linear", toolName: "create_issue",
            items: [original])
        state.pendingAnswerAction = staged

        state.applyConfirmEdits(fields: [:], items: [edited])
        await state.commitAnswerAction()

        #expect(fake.requests == [AnswerActionDispatchRequest(
            action: staged.action,
            payload: .trackerItem(edited))])
        #expect(state.answerActionResult == "Created 1 item(s) in Linear.")
    }

    @Test("rapid duplicate confirms cannot call the connected tool twice")
    func rapidDuplicateConfirmIsSingleFlight() async {
        let fake = FakeConnectedTool()
        fake.pausesBeforeResult = true
        fake.result = "created https://fake.connected/gmail/draft-42"
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            answerActionDispatcher: fake)
        let staged = pending(
            id: "gmail", serverName: "Gmail", toolName: "create_draft",
            fields: ["subject": "Old", "body": "Old body"])
        let edited = ["subject": "Edited once", "body": "The final draft body."]
        state.pendingAnswerAction = staged
        state.applyConfirmEdits(fields: edited, items: [])

        let first = Task { await state.commitAnswerAction() }
        for _ in 0..<100 where fake.requests.isEmpty { await Task.yield() }
        #expect(fake.requests.count == 1)
        #expect(state.runningAnswerAction == staged.id)

        // This models a second confirm Task already queued by a rapid double
        // click while the first connected call is still awaiting its response.
        await state.commitAnswerAction()
        #expect(fake.requests.count == 1)

        fake.resume()
        await first.value
        #expect(fake.requests == [AnswerActionDispatchRequest(
            action: staged.action,
            payload: .fields(edited))])
        #expect(state.runningAnswerAction == nil)
    }

    @Test("cancel is non-mutating and never reaches the connected tool")
    func cancelNeverDispatches() async {
        let fake = FakeConnectedTool()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            answerActionDispatcher: fake)
        state.pendingAnswerAction = pending(
            id: "hubspot", serverName: "HubSpot", toolName: "create_record",
            fields: ["name": "Do not create", "note": "Canceled by user"])

        state.cancelAnswerAction()
        await state.commitAnswerAction()

        #expect(fake.requests.isEmpty)
        #expect(state.pendingAnswerAction == nil)
        #expect(state.runningAnswerAction == nil)
        #expect(state.answerActionResult == nil)
        #expect(state.lastError == nil)
    }

    @Test("connected-tool failure is surfaced and the write is not reported as successful")
    func failureSurfaces() async {
        let fake = FakeConnectedTool()
        fake.failure = .rejected
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            answerActionDispatcher: fake)
        let staged = pending(
            id: "hubspot", serverName: "HubSpot", toolName: "create_record",
            fields: ["name": "Falcon renewal", "note": "Edited note"])
        state.pendingAnswerAction = staged

        await state.commitAnswerAction()

        #expect(fake.requests.count == 1)
        #expect(state.answerActionResult == nil)
        #expect(state.lastError ==
            "Create in HubSpot: не удалось — Fake connector rejected the edited payload.")
        #expect(state.runningAnswerAction == nil)
    }

    @Test("an account change invalidates an already-reviewed connected write")
    func accountChangeInvalidatesReviewedDestination() async throws {
        let notifications = NotificationCenter()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: notifications,
            connectionAttemptOverride: { _ in
                [Tool(name: "create_record", description: "Write CRM record",
                      inputSchema: .object([:]),
                      annotations: .init(readOnlyHint: false, destructiveHint: false))]
            })
        let server = try #require(
            MCPCatalog.providerContracts.first { $0.id == "hubspot" }?.descriptor)
        await manager.connect(server)

        let state = AppState(
            credentialStore: InMemoryKeychain(),
            notificationCenter: notifications)
        state.mcp = manager
        let reviewedScope = manager.groundingCacheScope
        let staged = pending(
            id: "hubspot", serverName: "HubSpot", toolName: "create_record",
            fields: ["name": "Falcon renewal"])
        state.prepareAnswerAction(staged.action)
        #expect(state.pendingAnswerAction?.connectionScope == reviewedScope,
                "the production staging path must capture the reviewed account namespace")

        notifications.post(name: .wheesprAccountContextChanged, object: nil)
        #expect(manager.groundingCacheScope != reviewedScope)

        await state.commitAnswerAction()

        #expect(state.pendingAnswerAction == nil)
        #expect(state.runningAnswerAction == nil)
        #expect(state.answerActionResult == nil)
        #expect(state.lastError ==
            "The HubSpot account changed after this action was reviewed. Open the action again to confirm its destination.")
    }

    @Test("an account change between tracker items prevents every remaining write")
    func accountChangeStopsRemainingTrackerItems() async throws {
        let notifications = NotificationCenter()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: notifications,
            connectionAttemptOverride: { _ in
                [Tool(name: "create_issue", description: "Create tracker item",
                      inputSchema: .object([:]),
                      annotations: .init(readOnlyHint: false, destructiveHint: false))]
            })
        let server = try #require(MCPCatalog.builtIn.first { $0.id == "linear" })
        await manager.connect(server)

        let fake = FakeConnectedTool()
        fake.onDispatch = { count in
            if count == 1 {
                notifications.post(name: .wheesprAccountContextChanged, object: nil)
            }
        }
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            notificationCenter: notifications,
            answerActionDispatcher: fake)
        state.mcp = manager
        let first = TasksArtifact.Item(
            task: "Create the migration issue", owner: "Mina", due: "Friday",
            doneCheck: nil, dependency: nil, sourceRef: nil, tracked: false)
        let second = TasksArtifact.Item(
            task: "Create the rollout issue", owner: "Noah", due: "Monday",
            doneCheck: nil, dependency: nil, sourceRef: nil, tracked: false)
        state.pendingAnswerAction = pending(
            id: "linear", serverName: "Linear", toolName: "create_issue",
            items: [first, second],
            connectionScope: manager.groundingCacheScope)

        await state.commitAnswerAction()

        #expect(fake.requests.count == 1,
                "the second item must not cross the account-switch boundary")
        #expect(fake.requests.first?.payload == .trackerItem(first))
        #expect(state.answerActionResult ==
            "Created 1 of 2 in Linear. Failed: Create the rollout issue")
        #expect(state.lastError ==
            "The Linear account changed after this action was reviewed. Open the action again to confirm its destination.")
    }
}
