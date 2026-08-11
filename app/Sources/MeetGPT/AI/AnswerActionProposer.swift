import Foundation

/// The model's half of the action row: given the answer and the tools the user
/// actually has, propose specific things worth doing that schema matching alone
/// would miss.
///
/// The schema matcher can see that Attio exposes `create_record`; it cannot see
/// that this particular answer is about the Acme renewal and that the record
/// should be titled accordingly. That judgement is what this call buys.
///
/// Everything it returns is verified before it reaches a chip: the tool must
/// exist on a connected server, every argument must appear in that tool's
/// schema, and every required argument must be present. A proposal that fails
/// any of those is dropped rather than repaired — a hallucinated argument name
/// becomes a failed write against someone's CRM, and the model is not the
/// authority on what the server accepts.
enum AnswerActionProposer {

    /// One proposal, before verification.
    private struct Wire: Decodable {
        let server: String
        let tool: String
        let title: String
        let why: String?
        let arguments: [String: String]?
    }

    private struct Envelope: Decodable {
        let actions: [Wire]?
    }

    /// A verified proposal with its arguments, ready to confirm.
    struct Proposal: Equatable {
        let action: AnswerActionPlanner.Action
        let arguments: [String: String]
    }

    static let maxProposals = 3
    private static let maxAnswerChars = 4_000

    static func systemPrompt() -> String {
        """
        You propose concrete next actions a meeting co-pilot can take in the user's \
        connected apps, based on an answer it just produced.

        You are given the EXACT tools available. Use only those — a tool or argument \
        name that is not in the list will be discarded, so inventing one wastes the \
        proposal. Fill arguments from the answer's actual content: real names, real \
        titles, the wording that was used. A proposal whose arguments are generic \
        ("Meeting notes", "Follow up") is worse than no proposal.

        Propose only what clearly follows from the answer. Two good actions beat five \
        speculative ones, and zero is a perfectly good response when the answer calls \
        for nothing. Never propose anything that deletes, closes or archives.

        Return STRICT minified JSON, no prose, no code fences:
        {"actions":[{"server":"<server id>","tool":"<exact tool name>","title":"<button text, <=48 chars>","why":"<one line>","arguments":{"<schema key>":"<value>"}}]}
        Nothing worth doing: {"actions":[]}
        At most \(maxProposals) actions.
        """
    }

    /// Render the tool inventory for the prompt. Only fillable write tools —
    /// the model should not be reasoning about `search_issues`.
    static func inventory(_ capabilities: [AnswerActionPlanner.ToolCapability]) -> String {
        capabilities.map { capability in
            let required = capability.requiredKeys.isEmpty
                ? ""
                : " required: \(capability.requiredKeys.joined(separator: ", "))."
            let description = capability.toolDescription.isEmpty
                ? ""
                : " — \(capability.toolDescription.prefix(140))"
            return "- server \"\(capability.serverID)\" (\(capability.serverName)) tool \"\(capability.toolName)\"\(description)\n"
                + "  arguments: \(capability.argumentKeys.sorted().joined(separator: ", ")).\(required)"
        }
        .joined(separator: "\n")
    }

    /// Ask for proposals. Returns [] on any failure — a proposer that cannot
    /// reach the model must leave the deterministic chips alone, not break them.
    static func propose(answer: String,
                        goal: String,
                        capabilities: [AnswerActionPlanner.ToolCapability],
                        model: LLMModel,
                        gateway: LLMGateway) async -> [Proposal] {
        let offerable = capabilities.filter {
            AnswerActionPlanner.isOfferableWriteCapability($0)
        }
        guard !offerable.isEmpty else { return [] }

        var sections = ["The answer:\n\(String(answer.prefix(maxAnswerChars)))"]
        if !goal.isEmpty { sections.append("The user's goal for this call:\n\(goal)") }
        sections.append("Available tools:\n\(inventory(offerable))")

        let reply = try? await gateway.streamChat(
            system: systemPrompt(),
            user: sections.joined(separator: "\n\n"),
            images: [],
            model: model
        ) { _ in }

        guard let reply else { return [] }
        return verify(reply, against: offerable)
    }

    /// Parse and validate against the live schemas.
    static func verify(_ reply: String,
                       against capabilities: [AnswerActionPlanner.ToolCapability]) -> [Proposal] {
        guard let json = extractJSONObject(reply), let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let wires = envelope.actions else {
            return []
        }

        var seen: Set<String> = []
        var proposals: [Proposal] = []

        for wire in wires.prefix(maxProposals) {
            // The tool must exist on a server the user is actually connected to.
            guard let capability = capabilities.first(where: {
                $0.serverID == wire.server && $0.toolName == wire.tool
            }) else { continue }
            // Never let a proposal smuggle in a destructive call.
            guard AnswerActionPlanner.isOfferableWriteCapability(capability) else { continue }

            let declared = Set(capability.argumentKeys)
            let supplied = wire.arguments ?? [:]
            // Every argument must be one the schema declares. A single unknown
            // key means the model was guessing about this tool, so none of its
            // arguments can be trusted for it.
            guard supplied.keys.allSatisfy({ declared.contains($0) }) else { continue }
            // Every required argument must be present, or the call 400s on click.
            guard capability.requiredKeys.allSatisfy({ supplied[$0]?.isEmpty == false }) else { continue }
            guard !supplied.isEmpty else { continue }

            let title = wire.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let id = "proposed:\(capability.serverID):\(capability.toolName):\(title)"
            guard seen.insert(id).inserted else { continue }

            let parts = AnswerActionPlanner.label(forTool: capability.toolName)
            proposals.append(Proposal(
                action: .init(
                    id: id,
                    serverID: capability.serverID,
                    serverName: capability.serverName,
                    toolName: capability.toolName,
                    title: String(title.prefix(48)),
                    systemImage: parts.symbol,
                    rationale: wire.why?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Proposed from this answer.",
                    isProposed: true),
                arguments: supplied))
        }
        return proposals
    }

    private static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
