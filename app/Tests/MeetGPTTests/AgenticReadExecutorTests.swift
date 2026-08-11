import Foundation
import MCP
import Testing
@testable import MeetGPT

/// Running one requested read against connected apps.
///
/// The caller is injected, which is the point: the failure modes worth testing
/// here are a connector that errors, one that returns nothing, and a name that
/// resolves to something the user did not mean. A live server reproduces none of
/// those on demand.
///
/// `nearMissDoesNotResolve` is the one that matters most. Reading the wrong
/// connector because the model typed "Gmai" is not a degraded answer, it is
/// opening somebody's email on a guess.
@Suite("Agentic read executor")
struct AgenticReadExecutorTests {

    private func descriptor(id: String, name: String) -> MCPServerDescriptor {
        MCPServerDescriptor(id: id, name: name,
                            endpoint: URL(string: "https://example.com/mcp")!,
                            symbol: "app", isCustom: false)
    }

    private func tool(_ name: String) -> Tool {
        Tool(name: name, description: "Returns matching context.",
             inputSchema: .object([:]), annotations: .init())
    }

    private func executor(
        servers: [MCPServerDescriptor],
        tools: [String: [Tool]],
        call: @escaping AgenticReadExecutor.Caller = { _, _, _ in "result text" }
    ) -> AgenticReadExecutor {
        AgenticReadExecutor(servers: servers,
                            toolsForServer: { tools[$0] ?? [] },
                            call: call)
    }

    private var standard: AgenticReadExecutor {
        executor(servers: [descriptor(id: "slack", name: "Slack"),
                           descriptor(id: "gmail", name: "Gmail")],
                 tools: ["slack": [tool("search_messages"), tool("send_message")],
                         "gmail": [tool("search_threads")]])
    }

    // MARK: - Resolving names

    @Test("resolves a server by name, ignoring case and punctuation")
    func resolvesServer() {
        // The model is copying a name out of a prompt and will not reproduce
        // punctuation reliably.
        for spelling in ["Slack", "slack", "SLACK"] {
            #expect(standard.server(named: spelling)?.id == "slack")
        }
    }

    @Test("a near miss does NOT resolve")
    func nearMissDoesNotResolve() {
        // Deliberately not fuzzy. A near-match that silently picked a different
        // connector would read somebody's email because the model typed "Gmai".
        #expect(standard.server(named: "Gmai") == nil)
        #expect(standard.server(named: "Slak") == nil)
        #expect(standard.server(named: "") == nil)
    }

    @Test("a category word does NOT resolve to a connector")
    func categoryWordDoesNotResolve() {
        // What a blind model actually emits (measured, api scripts/
        // eval-tool-refusal.js): with no catalog it names the CATEGORY — "crm",
        // "email", "chat" — or echoes the placeholder "server". Each must refuse
        // rather than guess; "email" silently resolving to Gmail would read a
        // mailbox the model never named.
        for category in ["crm", "email", "chat", "docs", "server"] {
            #expect(standard.server(named: category) == nil, "\(category)")
        }
    }

    @Test("resolves by id when the display name does not match")
    func resolvesByID() {
        #expect(standard.server(named: "gmail")?.id == "gmail")
    }

    @Test("a tool on the wrong server does not resolve")
    func toolIsScopedToItsServer() {
        // search_threads exists, but not on Slack. Resolving across servers
        // would call a tool the user never connected for this purpose.
        let slack = standard.server(named: "Slack")!
        #expect(standard.tool(named: "search_threads", on: slack) == nil)
        #expect(standard.tool(named: "search_messages", on: slack) != nil)
    }

    // MARK: - Bounds are applied before anything runs

    @Test("an unknown server is refused without calling anything")
    func unknownServerNeverCalls() async {
        var called = false
        let subject = executor(servers: [], tools: [:],
                               call: { _, _, _ in called = true; return "x" })
        let outcome = await subject.perform(
            .init(server: "Nowhere", tool: "search", query: "x"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(!called)
        #expect(outcome.refusal == .unknownTool)
        #expect(outcome.attribution == nil)
    }

    @Test("a write tool is refused without calling it")
    func writeToolNeverCalls() async {
        // The boundary. A bounded agentic READ step must never become a write
        // path, and the check happens before the connector is touched.
        var called = false
        let subject = executor(
            servers: [descriptor(id: "slack", name: "Slack")],
            tools: ["slack": [tool("send_message")]],
            call: { _, _, _ in called = true; return "sent" })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "send_message", query: "hi"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(!called, "a write tool must not be invoked")
        #expect(outcome.refusal == .notAReadTool)
    }

    @Test("a spent budget refuses without calling")
    func spentBudgetNeverCalls() async {
        var called = false
        var turn = AgenticReadStep.Turn()
        for _ in 0..<AgenticReadStep.maxCallsPerTurn {
            turn.record(AgenticReadStep.Attribution(tool: "search_messages",
                                                    server: "Slack", producedResult: true))
        }
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, _ in called = true; return "x" })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "search_messages", query: "x"),
            turn: turn, elapsed: 0, isRecording: false)
        #expect(!called)
        #expect(outcome.refusal == .budgetSpent)
    }

    @Test("a passed deadline refuses without calling")
    func lateRequestNeverCalls() async {
        var called = false
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, _ in called = true; return "x" })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "search_messages", query: "x"),
            turn: AgenticReadStep.Turn(),
            elapsed: AgenticReadStep.liveDeadline + 1, isRecording: true)
        #expect(!called)
        #expect(outcome.refusal == .deadlinePassed)
    }

    @Test("every refusal tells the model to answer without it")
    func refusalsInstructTheModel() async {
        // Otherwise the model asks again for something it will not get, and
        // spends the rest of the turn doing so.
        let outcome = await standard.perform(
            .init(server: "Slack", tool: "send_message", query: "hi"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(outcome.resultBlock?.contains("Answer without it") == true)
        #expect(outcome.resultBlock?.contains("say what you could not check") == true)
    }

    // MARK: - Executing

    @Test("a successful read is attributed and fed back")
    func successfulRead() async {
        let outcome = await standard.perform(
            .init(server: "Slack", tool: "search_messages", query: "migration"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(outcome.attribution == AgenticReadStep.Attribution(
            tool: "search_messages", server: "Slack", producedResult: true))
        #expect(outcome.resultBlock?.contains("result text") == true)
        #expect(outcome.refusal == nil)
    }

    @Test("the query is passed through as an argument")
    func queryIsPassed() async {
        var seen: [String: Value]?
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, args in seen = args; return "ok" })
        _ = await subject.perform(.init(server: "Slack", tool: "search_messages",
                                        query: "migration timeline"),
                                  turn: AgenticReadStep.Turn(), elapsed: 0,
                                  isRecording: false)
        #expect(seen?["query"] == .string("migration timeline"))
    }

    @Test("an argumentless request sends no arguments")
    func argumentlessRequest() async {
        var seen: [String: Value]? = ["sentinel": .string("x")]
        let subject = executor(servers: [descriptor(id: "linear", name: "Linear")],
                               tools: ["linear": [tool("list_issues")]],
                               call: { _, _, args in seen = args; return "ok" })
        _ = await subject.perform(.init(server: "Linear", tool: "list_issues", query: ""),
                                  turn: AgenticReadStep.Turn(), elapsed: 0,
                                  isRecording: false)
        #expect(seen == nil)
    }

    @Test("an empty result is attributed as a lookup that found nothing")
    func emptyResult() async {
        // Distinct from never looking. Only one of them means the user should
        // go and check themselves.
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, _ in "   \n  " })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "search_messages", query: "x"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(outcome.attribution?.producedResult == false)
        #expect(outcome.resultBlock?.contains("nothing found") == true)
    }

    @Test("a connector that throws degrades to an answer without it")
    func connectorErrorDegrades() async {
        // The user asked a question, not for a tool call. A failed lookup must
        // not become a failed answer.
        struct Boom: Error {}
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, _ in throw Boom() })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "search_messages", query: "x"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)
        #expect(outcome.attribution?.producedResult == false)
        #expect(outcome.refusal == nil, "an error is not a refusal — it was attempted")
        #expect(outcome.resultBlock?.contains("nothing found") == true)
    }

    @Test("an errored lookup still appears in the source note")
    func erroredLookupIsAttributed() async {
        struct Boom: Error {}
        let subject = executor(servers: [descriptor(id: "slack", name: "Slack")],
                               tools: ["slack": [tool("search_messages")]],
                               call: { _, _, _ in throw Boom() })
        let outcome = await subject.perform(
            .init(server: "Slack", tool: "search_messages", query: "x"),
            turn: AgenticReadStep.Turn(), elapsed: 0, isRecording: false)

        var turn = AgenticReadStep.Turn()
        if let attribution = outcome.attribution { turn.record(attribution) }
        // The answer must still say it looked — hiding a failed attempt would
        // let the reader assume the connector was never relevant.
        #expect(turn.sourceNote.contains("Slack · search_messages"))
        #expect(turn.sourceNote.contains("no result"))
    }
}
