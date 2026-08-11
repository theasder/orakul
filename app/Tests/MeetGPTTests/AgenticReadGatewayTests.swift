import Foundation
import MCP
import Testing
@testable import MeetGPT

/// The bounded read loop, wrapped around a gateway.
///
/// A decorator for the same reason `RedactingGateway` is one: wrap once at
/// construction and every caller is covered. It also keeps a retry loop out of
/// `AppState.run`, which is the riskiest place in the app to put one.
///
/// The tests that matter are the ones about what the USER sees. A protocol line
/// leaking into the answer, or an ordinary answer being held back, would both be
/// worse than not having the feature.
@Suite("Agentic read gateway")
struct AgenticReadGatewayTests {

    /// A gateway that returns scripted answers, one per call.
    private final class ScriptedGateway: LLMGateway, @unchecked Sendable {
        private let script: [String]
        private(set) var calls = 0
        private(set) var lastUser = ""
        private(set) var lastSystem = ""

        init(_ script: [String]) { self.script = script }

        func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                        onDelta: @escaping (String) -> Void) async throws -> String {
            lastSystem = system
            lastUser = user
            let answer = calls < script.count ? script[calls] : (script.last ?? "")
            calls += 1
            // Stream in small pieces, so the gate is exercised the way a real
            // provider drives it rather than in one convenient chunk.
            for chunk in answer.chunked(4) { onDelta(chunk) }
            return answer
        }

        func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                        maxOutputTokens: Int?,
                        onDelta: @escaping (String) -> Void) async throws -> String {
            try await streamChat(system: system, user: user, images: images,
                                 model: model, onDelta: onDelta)
        }
    }

    private func descriptor() -> MCPServerDescriptor {
        MCPServerDescriptor(id: "slack", name: "Slack",
                            endpoint: URL(string: "https://example.com/mcp")!,
                            symbol: "app", isCustom: false)
    }

    private func executor(result: String = "Ana: we slipped to Sept 14")
    -> AgenticReadExecutor {
        AgenticReadExecutor(
            servers: [descriptor()],
            // Both a read and a write tool, so a refusal test exercises the
            // write classification rather than an unresolved name.
            toolsForServer: { _ in
                ["search_messages", "send_message"].map {
                    Tool(name: $0, description: "Connector tool.",
                         inputSchema: .object([:]), annotations: .init())
                }
            },
            call: { _, _, _ in result })
    }

    private func request(_ body: String) -> String {
        "\(AgenticToolRequest.opening) \(body) \(AgenticToolRequest.closing)"
    }

    private var model: LLMModel {
        LLMModel(id: "gpt-5.4", label: "GPT", provider: .openAI,
                 minTier: .free, supportsVision: false)
    }

    // MARK: - Ordinary answers are untouched

    @Test("an answer with no request streams straight through")
    func ordinaryAnswerPassesThrough() async throws {
        let inner = ScriptedGateway(["Maria will send the contract by Friday."])
        var streamed = ""
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() })

        let answer = try await gateway.streamChat(system: "s", user: "u", images: [],
                                                  model: model) { streamed += $0 }
        #expect(answer == "Maria will send the contract by Friday.")
        #expect(streamed == answer, "every delta must reach the user")
        #expect(inner.calls == 1, "no extra round trip for an ordinary answer")
    }

    @Test("with no connected servers the loop is inert")
    func inertWithoutServers() async throws {
        // Telling a model about a capability it cannot use spends tokens to
        // invite requests that can only be refused.
        let inner = ScriptedGateway(["Plain answer."])
        let gateway = AgenticReadGateway(wrapping: inner, executor: { nil })
        var streamed = ""
        _ = try await gateway.streamChat(system: "s", user: "u", images: [],
                                         model: model) { streamed += $0 }
        #expect(streamed == "Plain answer.")
        #expect(!inner.lastSystem.contains(AgenticToolRequest.opening),
                "the instruction must not be appended when nothing can be read")
    }

    // MARK: - A request is machinery, not content

    @Test("the request line never reaches the user")
    func requestIsNotStreamed() async throws {
        // The failure this prevents: a line of protocol syntax appearing in the
        // answer where a sentence should be.
        let inner = ScriptedGateway([request("Slack/search_messages migration"),
                                     "They slipped to September 14."])
        var streamed = ""
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() })

        let answer = try await gateway.streamChat(system: "s", user: "u", images: [],
                                                  model: model) { streamed += $0 }
        #expect(!streamed.contains(AgenticToolRequest.opening))
        #expect(streamed == "They slipped to September 14.")
        #expect(answer == "They slipped to September 14.")
    }

    @Test("the lookup result is fed back to the model")
    func resultReEntersTheAnswer() async throws {
        let inner = ScriptedGateway([request("Slack/search_messages migration"),
                                     "They slipped to September 14."])
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() })
        _ = try await gateway.streamChat(system: "s", user: "u", images: [],
                                         model: model) { _ in }
        #expect(inner.calls == 2)
        #expect(inner.lastUser.contains("Ana: we slipped to Sept 14"))
        #expect(inner.lastUser.contains("Result of Slack/search_messages"))
    }

    @Test("the call is attributed to the finished turn")
    func turnIsReported() async throws {
        var reported: AgenticReadStep.Turn?
        let inner = ScriptedGateway([request("Slack/search_messages migration"),
                                     "They slipped to September 14."])
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() },
                                         onTurnComplete: { reported = $0 })
        _ = try await gateway.streamChat(system: "s", user: "u", images: [],
                                         model: model) { _ in }
        #expect(reported?.sourceNote.contains("Slack · search_messages") == true)
    }

    // MARK: - Bounds

    @Test("a model that only ever asks for tools still returns an answer")
    func loopTerminates() async throws {
        // The runaway case. Without a bound this is an infinite exchange, and
        // the user gets nothing at all.
        let inner = ScriptedGateway([request("Slack/search_messages a")])
        var reported: AgenticReadStep.Turn?
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() },
                                         onTurnComplete: { reported = $0 })
        var streamed = ""
        let answer = try await gateway.streamChat(system: "s", user: "u", images: [],
                                                  model: model) { streamed += $0 }
        #expect(inner.calls <= AgenticReadStep.maxCallsPerTurn + 1)
        #expect(!answer.contains(AgenticToolRequest.opening),
                "the protocol line must never be the answer")
        #expect(reported?.refusals.contains(.budgetSpent) == true)
    }

    @Test("a refused tool does not stop the answer")
    func refusedToolStillAnswers() async throws {
        // A write request must cost the answer nothing beyond a note.
        let inner = ScriptedGateway([request("Slack/send_message hello"),
                                     "I cannot send that, but here is the summary."])
        var reported: AgenticReadStep.Turn?
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() },
                                         onTurnComplete: { reported = $0 })
        let answer = try await gateway.streamChat(system: "s", user: "u", images: [],
                                                  model: model) { _ in }
        #expect(answer == "I cannot send that, but here is the summary.")
        #expect(reported?.refusals.contains(.notAReadTool) == true)
    }

    @Test("an error from the inner gateway is not swallowed")
    func innerErrorsPropagate() async {
        // A failed model call is a failed answer, and hiding it would show the
        // user an empty reply with no explanation.
        struct Boom: Error {}
        final class Failing: LLMGateway, @unchecked Sendable {
            func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                            onDelta: @escaping (String) -> Void) async throws -> String {
                throw Boom()
            }
            func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                            maxOutputTokens: Int?,
                            onDelta: @escaping (String) -> Void) async throws -> String {
                throw Boom()
            }
        }
        let gateway = AgenticReadGateway(wrapping: Failing(), executor: { self.executor() })
        await #expect(throws: (any Error).self) {
            _ = try await gateway.streamChat(system: "s", user: "u", images: [],
                                             model: self.model) { _ in }
        }
    }

    @Test("both streamChat overloads run the loop")
    func bothOverloadsCovered() async throws {
        // The token-capped overload carries the longest payloads. Covering only
        // one is how a wrapper silently misses half its traffic.
        let inner = ScriptedGateway([request("Slack/search_messages a"), "Answered."])
        let gateway = AgenticReadGateway(wrapping: inner, executor: { self.executor() })
        let answer = try await gateway.streamChat(system: "s", user: "u", images: [],
                                                  model: model, maxOutputTokens: 500) { _ in }
        #expect(answer == "Answered.")
        #expect(inner.calls == 2)
    }
}

private extension String {
    /// Split into fixed-size pieces, to drive the delta gate the way a provider does.
    func chunked(_ size: Int) -> [String] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(size, count - offset))
            return String(self[start..<end])
        }
    }
}

/// Where the loop sits in the gateway stack.
@Suite("Agentic read wiring", .serialized)
struct AgenticReadWiringTests {

    @Test("inert until something configures it")
    func inertByDefault() async {
        // The default for tests and for builds with no connectors wired. An
        // uninitialised context must not append a tool instruction to every
        // prompt in the app.
        AgenticReadContext.shared.reset()
        #expect(await AgenticReadContext.shared.executor() == nil)
        #expect(await AgenticReadContext.shared.isRecording() == false)
    }

    @Test("the loop runs INSIDE the redactor")
    func loopIsInsideTheRedactor() {
        // Order matters and is easy to get backwards. A tool result re-enters
        // the conversation as user text and is sent on the next round trip, so
        // it must pass through the redactor like anything else. If the loop sat
        // outside, that second request would carry an unredacted connector
        // payload — an inbox or a CRM record — straight to the provider.
        //
        // Pinned as a source fact because the ordering is invisible at runtime
        // until the day something leaks.
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetGPT/AI/BackendGateway.swift"),
            encoding: .utf8)
        guard let source else { return }
        #expect(source.contains("RedactingGateway(wrapping: agentic"),
                "the redactor must wrap the agentic loop, not the other way round")
    }

    @Test("the executor is supplied through the async provider, per request")
    func executorRoundTrips() async {
        // The provider is async so it can build the executor on the MainActor
        // (the connection manager is MainActor-isolated) without a data race.
        // This proves the round trip: configure in, executor out.
        var built = 0
        AgenticReadContext.shared.configure(
            executor: {
                built += 1
                return AgenticReadExecutor(
                    servers: [MCPServerDescriptor(
                        id: "slack", name: "Slack",
                        endpoint: URL(string: "https://example.com/mcp")!,
                        symbol: "app", isCustom: false)],
                    toolsForServer: { _ in [] },
                    call: { _, _, _ in "" })
            },
            isRecording: { false },
            onTurnComplete: { _ in })
        defer { AgenticReadContext.shared.reset() }

        #expect(await AgenticReadContext.shared.executor() != nil)
        // Per request, not cached: a second ask builds again, so a mid-session
        // connect is seen rather than frozen at first use.
        _ = await AgenticReadContext.shared.executor()
        #expect(built == 2)
    }

    @Test("recording state is read per request, not captured")
    func recordingIsLive() async {
        // The deadline depends on it and a call starts and stops mid-session.
        // Capturing it at construction would apply the idle deadline during a
        // live call, which is the case the ceiling exists for.
        var recording = false
        AgenticReadContext.shared.configure(executor: { nil },
                                            isRecording: { recording },
                                            onTurnComplete: { _ in })
        defer { AgenticReadContext.shared.reset() }
        #expect(await AgenticReadContext.shared.isRecording() == false)
        recording = true
        #expect(await AgenticReadContext.shared.isRecording() == true)
    }
}
