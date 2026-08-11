import Foundation

/// Runs a `MeetingSkill` against the live-call transcript and returns a typed
/// `MeetingArtifact`. This is the in-call action surface: "Recap deck",
/// "Minutes", and "Action-item sheet" all route through `generate`.
///
/// The flow mirrors `BrainstormService`: clip the transcript, use the skill's
/// guidance as the system prompt, stream a completion through the shared
/// `LLMGateway`, then decode the JSON contract into a structured artifact.
/// Optional `GroundingSnippet`s (pulled from connected MCP apps via
/// `MCPConnectionManager.groundingSnippets(goal:)`) are appended as background so
/// the artifact can reference CRM notes, prior docs, or linked tickets.
enum MeetingArtifactService {
    private static let maxTranscriptChars = 12_000
    private static let maxGroundingChars = 4_000

    /// Generate the artifact for `skill` from the current call.
    /// - Parameters:
    ///   - skill: which bundled skill to apply (deck / minutes / sheet).
    ///   - goal: the call's stated goal, used to bias content selection.
    ///   - transcript: the running transcript (only the tail is used).
    ///   - grounding: optional background from connected work apps.
    ///   - model: the LLM to use; defaults to the user's selected model.
    static func generate(skill: MeetingSkill,
                         goal: String,
                         transcript: String,
                         grounding: [GroundingSnippet] = [],
                         model: LLMModel = Config.selectedModel,
                         // Injectable for the same reason AppState's is: the
                         // consequence ranking and the numbers guard both apply
                         // at the decode below, and without a seam here that
                         // wiring could only be verified by reading it.
                         gateway: LLMGateway = LLMGatewayFactory.make()) async throws -> MeetingArtifact {
        let clipped = String(transcript.suffix(maxTranscriptChars))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingArtifactError.emptyTranscript
        }

        let system = skill.guidance
        let user = buildUserPrompt(goal: goal, transcript: clipped, grounding: grounding)

        let text = try await gateway.streamChat(
            system: system, user: user, model: model) { _ in }
        guard let json = extractJSONObject(text), let data = json.data(using: .utf8) else {
            throw MeetingArtifactError.unparseable(String(text.prefix(200)))
        }
        return try decode(kind: skill.kind, data: data, transcript: clipped)
    }

    // MARK: - Prompt

    private static func buildUserPrompt(goal: String, transcript: String, grounding: [GroundingSnippet]) -> String {
        var parts: [String] = []
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty { parts.append("Meeting goal: \(trimmedGoal)") }

        if !grounding.isEmpty {
            let grounding = GroundingContextPolicy.optimizedSnippets(
                grounding,
                query: trimmedGoal,
                tier: Config.currentTier,
                characterLimit: maxGroundingChars)
            var budget = maxGroundingChars
            var lines = ["Background from connected apps (use only if relevant):"]
            for snippet in grounding where budget > 0 {
                let chunk = String(snippet.text.prefix(budget))
                budget -= chunk.count
                lines.append("[\(snippet.serverName)] \(chunk)")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        parts.append("Transcript:\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Decode

    private static func decode(kind: MeetingSkill.Kind, data: Data, transcript: String) throws -> MeetingArtifact {
        let decoder = JSONDecoder()
        do {
            switch kind {
            case .deck: return .deck(try decoder.decode(DeckArtifact.self, from: data))
            // .ranked(): consequence-ordered, deterministic, pure permutation
            // (roadmap F4) — "sunset the API" must not render below "lunch
            // moved to Thursdays". .auditingNumbers: every figure the minutes
            // state and the transcript does not contain gets a visible
            // verify-this footer (F10) — deterministic, not a model call.
            case .minutes: return .minutes(try decoder.decode(MinutesArtifact.self, from: data)
                .ranked()
                .auditingNumbers(against: transcript))
            case .sheet: return .sheet(try decoder.decode(SheetArtifact.self, from: data))
            }
        } catch {
            throw MeetingArtifactError.unparseable("schema mismatch: \(error.localizedDescription)")
        }
    }

    /// Pull the first `{ … }` object out of a model reply (handles code fences),
    /// matching the tolerant extraction the other in-call services use.
    private static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

enum MeetingArtifactError: LocalizedError {
    case emptyTranscript
    case unparseable(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "There's no transcript yet to build from."
        case .unparseable(let detail):
            return "Couldn't build the document from the model's reply (\(detail))."
        }
    }
}
