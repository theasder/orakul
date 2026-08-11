import Foundation
import MCP
import Testing
@testable import MeetGPT

/// A bounded agentic read step.
///
/// The acceptance criteria were four, and each maps to a section below: a
/// per-turn tool budget, every call attributed with its source, read/write
/// classification enforced by the EXISTING policy rather than a second one, and
/// a latency ceiling on the live path.
///
/// The one that carries the most weight is `usesTheExistingPolicy`. A second
/// classifier here would be easy to write and would drift from the one the
/// import sheet uses — and the drift would stay invisible until the day it let
/// something write to a user's CRM.
@Suite("Agentic read step")
struct AgenticReadStepTests {

    private func tool(_ name: String,
                      description: String = "Returns matching context.",
                      readOnly: Bool? = nil,
                      destructive: Bool? = nil) -> Tool {
        Tool(name: name, description: description, inputSchema: .object([:]),
             annotations: .init(readOnlyHint: readOnly, destructiveHint: destructive))
    }

    // MARK: - The budget

    @Test("spends up to the budget and then refuses")
    func budgetIsEnforced() {
        var turn = AgenticReadStep.Turn()
        for _ in 0..<AgenticReadStep.maxCallsPerTurn {
            #expect(AgenticReadStep.decide(tool: tool("search_docs"), turn: turn,
                                           elapsed: 0, isRecording: false).isAllowed)
            turn.record(AgenticReadStep.Attribution(tool: "search_docs", server: "Drive",
                                                    producedResult: true))
        }
        // Without a bound, a model that keeps not-quite-finding what it wants
        // spends a connector quota and the user's patience on one question.
        #expect(AgenticReadStep.decide(tool: tool("search_docs"), turn: turn,
                                       elapsed: 0, isRecording: false)
                == .refuse(.budgetSpent))
    }

    @Test("a refusal does not spend the budget")
    func refusalsAreFree() {
        // A model that asks for a write tool has not made a lookup. Charging it
        // would let a badly-behaved model exhaust the budget without ever
        // reading anything, and the user loses the feature to no purpose.
        var turn = AgenticReadStep.Turn()
        turn.record(AgenticReadStep.Refusal.notAReadTool)
        #expect(turn.callsMade == 0)
        #expect(turn.remaining == AgenticReadStep.maxCallsPerTurn)
    }

    @Test("the budget is per turn, so one answer cannot starve the next")
    func budgetIsPerTurn() {
        var spent = AgenticReadStep.Turn()
        for _ in 0..<AgenticReadStep.maxCallsPerTurn {
            spent.record(AgenticReadStep.Attribution(tool: "get_page", server: "Notion",
                                                     producedResult: true))
        }
        #expect(spent.remaining == 0)
        // A fresh turn starts fresh.
        #expect(AgenticReadStep.Turn().remaining == AgenticReadStep.maxCallsPerTurn)
    }

    // MARK: - Read/write classification

    @Test("uses the existing import policy rather than a second classifier")
    func usesTheExistingPolicy() {
        // Pinned deliberately. Two classifiers for "is this a write" drift, and
        // the drift is invisible until something mutates a connected system.
        for name in ["create_issue", "send_message", "delete_page", "update_record"] {
            let candidate = tool(name)
            #expect(!MCPImportToolPolicy.isSafeForImport(candidate))
            #expect(AgenticReadStep.decide(tool: candidate, turn: AgenticReadStep.Turn(),
                                           elapsed: 0, isRecording: false)
                    == .refuse(.notAReadTool))
        }
        for name in ["search_messages", "get_document", "list_issues"] {
            let candidate = tool(name)
            #expect(MCPImportToolPolicy.isSafeForImport(candidate))
            #expect(AgenticReadStep.decide(tool: candidate, turn: AgenticReadStep.Turn(),
                                           elapsed: 0, isRecording: false).isAllowed)
        }
    }

    @Test("an unknown verb fails closed")
    func unknownVerbFailsClosed() {
        // The import policy requires a tool to identify itself positively as a
        // read. Inheriting that means a novel tool name is refused rather than
        // tried, which is the right default when the cost of being wrong is a
        // write to someone else's system.
        #expect(AgenticReadStep.decide(tool: tool("frobnicate_widget"),
                                       turn: AgenticReadStep.Turn(),
                                       elapsed: 0, isRecording: false)
                == .refuse(.notAReadTool))
    }

    @Test("a tool nobody offers is refused rather than attempted")
    func unknownToolRefused() {
        #expect(AgenticReadStep.decide(tool: nil, turn: AgenticReadStep.Turn(),
                                       elapsed: 0, isRecording: false)
                == .refuse(.unknownTool))
    }

    @Test("writes are refused, not made safe by this step")
    func writesRemainStaged() {
        // The boundary this step must not move: writes stay staged for human
        // confirmation. A bounded agentic READ step is not permission to write.
        #expect(AgenticReadStep.decide(tool: tool("send_email"), turn: AgenticReadStep.Turn(),
                                       elapsed: 0, isRecording: false)
                == .refuse(.notAReadTool))
    }

    // MARK: - The latency ceiling

    @Test("the live deadline is much tighter than the idle one")
    func liveDeadlineIsTighter() {
        // A blind spot arriving after the topic has moved on is not late
        // information, it is noise — the room has already decided.
        #expect(AgenticReadStep.liveDeadline < AgenticReadStep.idleDeadline)
        #expect(AgenticReadStep.deadline(isRecording: true)
                < AgenticReadStep.deadline(isRecording: false))
    }

    @Test("a call that cannot finish in time is refused before it starts")
    func deadlineRefusesEarly() {
        // Refused before starting rather than cancelled after: cancelling costs
        // the time anyway, which is the thing the ceiling exists to protect.
        let turn = AgenticReadStep.Turn()
        #expect(AgenticReadStep.decide(tool: tool("search_docs"), turn: turn,
                                       elapsed: AgenticReadStep.liveDeadline + 0.1,
                                       isRecording: true)
                == .refuse(.deadlinePassed))
    }

    @Test("the same elapsed time is fine when nobody is waiting")
    func idleAllowsLonger() {
        #expect(AgenticReadStep.decide(tool: tool("search_docs"), turn: AgenticReadStep.Turn(),
                                       elapsed: AgenticReadStep.liveDeadline + 0.1,
                                       isRecording: false).isAllowed)
    }

    @Test("budget is checked before the clock")
    func budgetBeforeDeadline() {
        // Both would refuse; the budget is the more useful thing to tell a
        // model, because waiting will not fix it.
        var turn = AgenticReadStep.Turn()
        for _ in 0..<AgenticReadStep.maxCallsPerTurn {
            turn.record(AgenticReadStep.Attribution(tool: "get_page", server: "Notion",
                                                    producedResult: true))
        }
        #expect(AgenticReadStep.decide(tool: tool("search_docs"), turn: turn,
                                       elapsed: 999, isRecording: true)
                == .refuse(.budgetSpent))
    }

    // MARK: - Attribution

    @Test("every call is named with its source")
    func callsAreAttributed() {
        // An answer that quietly consulted someone's inbox and did not say so is
        // a worse product than one that could not consult it at all.
        var turn = AgenticReadStep.Turn()
        turn.record(AgenticReadStep.Attribution(tool: "search_messages", server: "Slack",
                                                producedResult: true))
        #expect(turn.sourceNote.contains("Slack · search_messages"))
        #expect(turn.sourceNote.hasPrefix("Consulted:"))
    }

    @Test("a lookup that found nothing is distinguished from one never made")
    func emptyResultIsDistinct() {
        // "I looked and found nothing" is a different answer from "I did not
        // look", and only one of them means the user should look themselves.
        var turn = AgenticReadStep.Turn()
        turn.record(AgenticReadStep.Attribution(tool: "search_docs", server: "Drive",
                                                producedResult: false))
        #expect(turn.sourceNote.contains("no result"))
    }

    @Test("refusals are reported, not silently dropped")
    func refusalsAreReported() {
        // An answer missing information because a tool was refused reads as a
        // worse answer unless it says why.
        var turn = AgenticReadStep.Turn()
        turn.record(AgenticReadStep.Refusal.notAReadTool)
        #expect(turn.sourceNote.contains("Not consulted:"))
        #expect(turn.sourceNote.contains("staged for confirmation"))
    }

    @Test("a repeated refusal is noted once")
    func refusalsDeduplicate() {
        // A model that asks three times for the same forbidden tool should
        // produce one note, not three.
        var turn = AgenticReadStep.Turn()
        turn.record(AgenticReadStep.Refusal.notAReadTool)
        turn.record(AgenticReadStep.Refusal.notAReadTool)
        turn.record(AgenticReadStep.Refusal.budgetSpent)
        #expect(turn.refusals.count == 2)
    }

    @Test("an answer that used no tools gains no footer")
    func ordinaryAnswersAreUntouched() {
        // The overwhelming majority of answers. A source note on all of them is
        // noise that teaches people to skip the one that matters.
        #expect(AgenticReadStep.Turn().sourceNote.isEmpty)
    }

    @Test("every refusal reason has a human explanation")
    func everyRefusalExplains() {
        for refusal in [AgenticReadStep.Refusal.budgetSpent, .notAReadTool,
                        .deadlinePassed, .unknownTool] {
            #expect(!refusal.explanation.isEmpty)
            // Written for the person reading the answer, not the model.
            #expect(refusal.explanation.lowercased() != refusal.rawValue.lowercased())
        }
    }
}

/// Parsing the model's read request out of an answer.
///
/// The tests that matter here are the refusals. This runs over every answer the
/// product generates, in a tool whose users discuss prompts and syntax as
/// ordinary work — so a parser that fires on a model TALKING about the protocol
/// would make calls nobody asked for.
@Suite("Agentic tool request parsing")
struct AgenticToolRequestTests {

    private func line(_ body: String) -> String {
        "\(AgenticToolRequest.opening) \(body) \(AgenticToolRequest.closing)"
    }

    @Test("parses a well-formed request")
    func parsesRequest() {
        let parsed = AgenticToolRequest.parse(line("Slack/search_messages migration timeline"))
        #expect(parsed == AgenticToolRequest.Parsed(server: "Slack",
                                                    tool: "search_messages",
                                                    query: "migration timeline"))
    }

    @Test("parses a request with no query")
    func parsesArgumentlessRequest() {
        // "list my open issues" needs no argument, and refusing it would push
        // the model into inventing one.
        #expect(AgenticToolRequest.parse(line("Linear/list_issues"))
                == AgenticToolRequest.Parsed(server: "Linear", tool: "list_issues", query: ""))
    }

    @Test("finds the request among ordinary answer text")
    func findsAmongProse() {
        let answer = """
        Let me check that.
        \(line("Drive/search_files Q3 plan"))
        """
        #expect(AgenticToolRequest.parse(answer)?.tool == "search_files")
    }

    // MARK: - The refusals that matter

    @Test("ignores the syntax mentioned inside a sentence")
    func ignoresInlineMention() {
        // The failure this exists to prevent. This is a meeting tool used by
        // teams who discuss prompts as work, so a model explaining the protocol
        // is ordinary output — and must not trigger a call.
        let answer = "You can ask for data with \(line("Slack/search_messages foo")) inline."
        #expect(AgenticToolRequest.parse(answer) == nil)
    }

    @Test("ignores a request that names no tool")
    func ignoresMissingTool() {
        #expect(AgenticToolRequest.parse(line("Slack/")) == nil)
        #expect(AgenticToolRequest.parse(line("/search_messages x")) == nil)
    }

    @Test("ignores a request with no server separator")
    func ignoresMissingSeparator() {
        #expect(AgenticToolRequest.parse(line("search_messages migration")) == nil)
        // The measured shape (api scripts/eval-tool-refusal.js): a model given
        // only server names emits "server query" with no /tool. Not a request —
        // it must fall through to the answer path, never fire a call.
        #expect(AgenticToolRequest.parse(line("gmail last email thread promise in writing")) == nil)
    }

    @Test("ignores an unterminated marker")
    func ignoresUnterminated() {
        // A truncated stream must not produce a half-parsed call.
        #expect(AgenticToolRequest.parse("\(AgenticToolRequest.opening) Slack/search x") == nil)
    }

    @Test("an ordinary answer parses to nothing, cheaply")
    func ordinaryAnswerHasNoRequest() {
        let answer = """
        Maria will send the contract by Friday. The launch moves to September
        after the Postgres backfill, and legal has not signed the DPA yet.
        """
        #expect(AgenticToolRequest.parse(answer) == nil)
    }

    @Test("markdown and code in an answer never parse as a request")
    func codeIsNotARequest() {
        let answer = """
        ```swift
        let x = readValue("server/tool")
        ```
        See `read: server/tool` in the docs.
        """
        #expect(AgenticToolRequest.parse(answer) == nil)
    }

    // MARK: - What the user sees

    @Test("the request line is removed from the visible answer")
    func requestIsStripped() {
        // The protocol is machinery. Leaving it in would show the user a line
        // of syntax where a sentence should be.
        let answer = """
        Checking that now.
        \(line("Drive/search_files Q3 plan"))
        """
        let visible = AgenticToolRequest.stripped(from: answer)
        #expect(visible == "Checking that now.")
        #expect(!visible.contains(AgenticToolRequest.opening))
    }

    @Test("stripping leaves an ordinary answer byte-identical")
    func strippingIsANoOpOnOrdinaryText() {
        // It runs on every answer, so it must not quietly reformat them.
        let answer = "Maria will send the contract by Friday."
        #expect(AgenticToolRequest.stripped(from: answer) == answer)
    }

    // MARK: - Feeding the result back

    @Test("the result is labelled as a lookup, not pasted in as knowledge")
    func resultIsLabelled() {
        // An answer that cannot tell its own knowledge from a lookup cannot
        // attribute it either, and attribution is an acceptance criterion.
        let block = AgenticToolRequest.resultBlock(server: "Slack", tool: "search_messages",
                                                   result: "Ana: we slipped to Sept 14")
        #expect(block.contains("Result of Slack/search_messages"))
        #expect(block.contains("Ana: we slipped to Sept 14"))
    }

    @Test("an empty result says so and tells the model to say so")
    func emptyResultIsExplicit() {
        // Otherwise the model treats silence as "nothing relevant exists" and
        // answers confidently from nothing.
        let block = AgenticToolRequest.resultBlock(server: "Drive", tool: "search_files",
                                                   result: "   ")
        #expect(block.contains("nothing found"))
        #expect(block.contains("say that you looked"))
    }

    @Test("the instruction and the parser describe the same syntax")
    func instructionMatchesParser() {
        // Two descriptions of one protocol drift, and the drift shows up as a
        // model emitting requests the parser silently ignores.
        #expect(AgenticToolRequest.instruction.contains(AgenticToolRequest.opening))
        #expect(AgenticToolRequest.instruction.contains(AgenticToolRequest.closing))
    }

    @Test("the instruction tells the model writes are not available here")
    func instructionExcludesWrites() {
        #expect(AgenticToolRequest.instruction.lowercased().contains("change data"))
    }
}
