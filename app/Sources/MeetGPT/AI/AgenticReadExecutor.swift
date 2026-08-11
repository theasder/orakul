import Foundation
import MCP

/// Resolves and runs one requested read, under the bounds of `AgenticReadStep`.
///
/// Split from the controller because the decision is pure and the execution is
/// not: every bound — budget, deadline, read/write — is decided by testable
/// logic before anything touches a connected system, and this type only carries
/// out a decision already made.
///
/// The caller is injected so the whole path is testable without a live MCP
/// server. That matters more here than usual: the failure modes worth testing
/// are a tool that hangs, one that returns nothing, and a name that resolves to
/// something the user did not mean — none of which a real server reproduces on
/// demand.
struct AgenticReadExecutor {

    /// Runs a tool and returns its flattened text.
    typealias Caller = (_ server: MCPServerDescriptor, _ tool: String,
                        _ arguments: [String: Value]?) async throws -> String

    /// What a completed attempt produced.
    struct Outcome: Equatable {
        let attribution: AgenticReadStep.Attribution?
        let refusal: AgenticReadStep.Refusal?
        /// Text to hand back to the model, or nil when nothing should be.
        let resultBlock: String?
    }

    private let servers: [MCPServerDescriptor]
    private let toolsForServer: (String) -> [Tool]
    private let call: Caller

    init(servers: [MCPServerDescriptor],
         toolsForServer: @escaping (String) -> [Tool],
         call: @escaping Caller) {
        self.servers = servers
        self.toolsForServer = toolsForServer
        self.call = call
    }

    /// Find the server the model named.
    ///
    /// Matched case- and separator-insensitively, because the model is copying a
    /// name out of a prompt and will not reproduce punctuation reliably. This is
    /// deliberately NOT fuzzy beyond that: a near-match that silently picks a
    /// different connector would read someone's email because the model typed
    /// "Gmai".
    func server(named name: String) -> MCPServerDescriptor? {
        let wanted = Self.normalise(name)
        guard !wanted.isEmpty else { return nil }
        return servers.first { Self.normalise($0.name) == wanted }
            ?? servers.first { Self.normalise($0.id) == wanted }
    }

    func tool(named name: String, on server: MCPServerDescriptor) -> Tool? {
        let wanted = Self.normalise(name)
        return toolsForServer(server.id).first { Self.normalise($0.name) == wanted }
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Decide, then run. Returns what to record and what to feed back.
    ///
    /// Never throws: a failed lookup must degrade to an answer without it, not
    /// to a failed answer. The user asked a question, not for a tool call.
    func perform(_ request: AgenticToolRequest.Parsed,
                 turn: AgenticReadStep.Turn,
                 elapsed: TimeInterval,
                 isRecording: Bool) async -> Outcome {
        guard let descriptor = server(named: request.server),
              let candidate = tool(named: request.tool, on: descriptor) else {
            return Outcome(attribution: nil, refusal: .unknownTool,
                           resultBlock: refusalBlock(.unknownTool))
        }

        let decision = AgenticReadStep.decide(tool: candidate, turn: turn,
                                              elapsed: elapsed, isRecording: isRecording)
        if case let .refuse(reason) = decision {
            return Outcome(attribution: nil, refusal: reason,
                           resultBlock: refusalBlock(reason))
        }

        let arguments: [String: Value]? = request.query.isEmpty
            ? nil : ["query": .string(request.query)]
        let text: String
        do {
            text = try await call(descriptor, candidate.name, arguments)
        } catch {
            // A connector that errors is reported as "looked, found nothing"
            // rather than surfaced as a failure: the answer is still worth
            // giving, and the source note already says the lookup happened.
            return Outcome(
                attribution: AgenticReadStep.Attribution(tool: candidate.name,
                                                         server: descriptor.name,
                                                         producedResult: false),
                refusal: nil,
                resultBlock: AgenticToolRequest.resultBlock(
                    server: descriptor.name, tool: candidate.name, result: ""))
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
            attribution: AgenticReadStep.Attribution(tool: candidate.name,
                                                     server: descriptor.name,
                                                     producedResult: !trimmed.isEmpty),
            refusal: nil,
            resultBlock: AgenticToolRequest.resultBlock(server: descriptor.name,
                                                        tool: candidate.name,
                                                        result: trimmed))
    }

    /// Told to the model, so it answers without the lookup rather than asking
    /// again for something it will not get.
    private func refusalBlock(_ reason: AgenticReadStep.Refusal) -> String {
        "That lookup was not made — \(reason.explanation). Answer without it, "
            + "and say what you could not check."
    }
}
