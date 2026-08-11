import Foundation

/// Engine for the structured buttons (A6): Tasks Follow-Up and Summarize Call.
/// Drafts against a typed JSON contract, then — only when `ArtifactValidator`
/// finds violations — runs one *targeted* repair pass on the fast model naming
/// exactly what to fix. Cheaper and sharper than the old blanket refine: a
/// clean draft costs one call, and repairs never get to "improve" prose, only
/// to fix named violations.
enum StructuredButtonService {
    enum Kind: String {
        case tasks, summary
    }

    private static let maxContextChars = 10_000

    // MARK: - Contracts

    private static func contract(for kind: Kind) -> String {
        switch kind {
        case .tasks:
            return """
            Produce the follow-up for this call. Extract action items in the speaker's own \
            wording; never invent an owner or due date — use "[OWNER?]" / "[DUE?]" when unstated \
            (an inferred date may be appended as "[DUE?] (suggest: …)"). Give each task a \
            Given/When/Then done-check, a dependency when one was stated, and the decision or \
            timestamp it traces to. Mark tasks that already exist in tracker background as \
            tracked. Log a DACI per decision. Finish with a one-paragraph Slack-ready summary. \
            Return ONLY minified JSON, no prose, no code fences:
            {"dacis":[{"decision":"...","driver":"name or null","approver":"name or null","contributors":["..."],"informed":["..."]}],"items":[{"task":"...","owner":"name or [OWNER?]","due":"stated date or [DUE?]","doneCheck":"Given/When/Then","dependency":"or null","sourceRef":"decision or timestamp","tracked":false}],"slackSummary":"one paragraph"}
            """
        case .summary:
            return """
            Summarize this call. TL;DR is at most 3 bullets of what changed. Every decision and \
            risk carries a SHORT VERBATIM quote from the transcript plus its speaker (and \
            timestamp when visible) — copy the words exactly, do not paraphrase inside "quote". \
            Actions take their stated owner and due, or null when unstated (rendered OPEN); mark \
            tracked=true for items already known to tracker background. Continuity reconciles \
            prior commitments from provided background as kept|slipped|reopened — omit the array \
            when no prior background exists. Return ONLY minified JSON, no prose, no code fences:
            {"tldr":["..."],"decisions":[{"text":"...","quote":"verbatim words","speaker":"name","timestamp":"HH:mm:ss or null"}],"actions":[{"task":"...","owner":"name or null","due":"or null","tracked":false}],"openQuestions":["..."],"risks":[{"text":"...","quote":"verbatim words","speaker":"name"}],"continuity":[{"commitment":"...","status":"kept|slipped|reopened"}],"parkingLot":["..."],"nextMeeting":"proposed agenda & date"}
            """
        }
    }

    // MARK: - Draft

    /// One skilled draft against the kind's JSON contract. `extraGuidance`
    /// carries the theme + role + button-skill layers.
    static func draft(kind: Kind, transcript: String, context: String,
                      extraGuidance: String?,
                      gateway: LLMGateway = LLMGatewayFactory.make(),
                      model: LLMModel = Config.selectedModel) async throws -> StructuredArtifact {
        var system = SystemInstructions.base + "\n\n" + contract(for: kind)
        if let extraGuidance, !extraGuidance.isEmpty { system += "\n\n" + extraGuidance }

        var user = "Transcript:\n\(transcript)"
        if !context.isEmpty { user += "\n\nAdditional context:\n\(String(context.prefix(maxContextChars)))" }

        let text = try await gateway.streamChat(
            system: system, user: user, model: model,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) { _ in }
        guard let artifact = decode(kind: kind, text: text) else {
            throw StructuredButtonError.unparseable(String(text.prefix(200)))
        }
        return artifact
    }

    // MARK: - Targeted repair

    /// Fix EXACTLY the named violations on the fast model. Returns nil when the
    /// repair fails to parse — the caller falls back to mechanical downgrade.
    static func repair(kind: Kind, artifact: StructuredArtifact,
                       violations: [ArtifactValidator.Violation],
                       transcript: String,
                       gateway: LLMGateway = LLMGatewayFactory.make(),
                       model: LLMModel? = nil) async -> StructuredArtifact? {
        guard !violations.isEmpty, let json = encode(artifact) else { return nil }
        let system = """
        You repair a structured meeting artifact. Fix EXACTLY the violations listed — nothing \
        else. Never invent data: an unverifiable quote gets replaced with the real verbatim words \
        from the transcript or removed; an ungrounded owner becomes the flag the schema uses. \
        Keep the SAME JSON schema and all other fields unchanged. Return ONLY the corrected \
        minified JSON.
        """
        let user = """
        Violations to fix:
        \(violations.map { "- \($0.description)" }.joined(separator: "\n"))

        Current JSON:
        \(json)

        Transcript (source of truth):
        \(String(transcript.suffix(10_000)))
        """
        let repairModel = model ?? LLMCatalog.background(for: Config.selectedModel)
        let text = try? await gateway.streamChat(
            system: system, user: user,
            model: repairModel,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) { _ in }
        guard let text else { return nil }
        return decode(kind: kind, text: text)
    }

    // MARK: - Codec

    private static func decode(kind: Kind, text: String) -> StructuredArtifact? {
        guard let json = JSONExtraction.firstObject(in: text), let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        switch kind {
        case .tasks:
            return (try? decoder.decode(TasksArtifact.self, from: data)).map { .tasks($0) }
        case .summary:
            return (try? decoder.decode(SummaryArtifact.self, from: data)).map { .summary($0) }
        }
    }

    private static func encode(_ artifact: StructuredArtifact) -> String? {
        let encoder = JSONEncoder()
        switch artifact {
        case .tasks(let value): return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        case .summary(let value): return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

}

enum StructuredButtonError: LocalizedError {
    case unparseable(String)

    var errorDescription: String? {
        switch self {
        case .unparseable(let detail):
            return "Couldn't build the structured output from the model's reply (\(detail))."
        }
    }
}
