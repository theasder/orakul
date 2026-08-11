import Foundation

/// Runs continuously during a call (no user action) and surfaces two things the
/// user might miss: LOADED / BIASED FRAMING in what's being said, and AGENDA
/// drift from the meeting's apparent purpose. LLM-only — this is pure analysis
/// of the transcript, so no retrieval is needed. Findings flow into the same
/// proactive suggestions surface as the brainstormer (Co-pilot + Focus panel).
enum AgendaCheckService {
    private static let maxTranscriptChars = 8000
    private static let maxFindings = 3

    static func findings(transcript: String, priorTitles: [String]) async throws -> [Suggestion] {
        let clip = String(transcript.suffix(maxTranscriptChars))
        guard !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let prior = priorTitles.isEmpty ? "" :
            "\n\nAlready surfaced — do NOT repeat:\n- " + priorTitles.suffix(40).joined(separator: "\n- ")
        let system = """
        You are a silent analyst on a live call. Scan ONLY the transcript for two things:
        1. FRAMING — loaded or biased language, cherry-picked or one-sided framing, unsupported \
        spin, or manipulative rhetoric. Quote the phrase and name the tactic neutrally.
        2. AGENDA — the discussion drifting from its apparent purpose, going in circles, or a \
        structure/time problem. Say what drifted and how to steer back.
        Surface at most \(maxFindings) NEW, specific items grounded in what was actually said. \
        Write in the same language as the transcript. Every finding MUST include an exact 4-20 \
        word quote copied from the transcript as evidence. \
        No generic media-literacy tips. Do NOT assign partisan or ideological labels \
        (liberal/conservative/etc.) — describe the concrete framing, not a political side. If \
        nothing is genuinely new, return an empty list. Return ONLY JSON:
        {"findings":[{"title":"<=8 words","detail":"1-2 sentences","kind":"framing|agenda","evidence":"exact transcript quote"}]}\(prior)
        """
        let user = "Transcript so far:\n\(clip)"

        let text = try await LLMGatewayFactory.make().streamChat(
            system: system, user: user,
            model: LLMCatalog.background(for: Config.selectedModel)) { _ in }
        guard let json = JSONExtraction.firstObject(in: text),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return (decoded.findings ?? []).compactMap {
            map($0, transcript: clip)
        }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let title: String?
            let detail: String?
            let kind: String?
            let evidence: String?
        }
        let findings: [Item]?
    }

    private static func map(_ item: Response.Item, transcript: String) -> Suggestion? {
        guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        guard SuggestionGrounding.contains(evidence: item.evidence, in: transcript) else { return nil }
        // framing → risk (watch this rhetoric); agenda → advice (steer back).
        let kind: SuggestionKind = (item.kind == "framing") ? .risk : .advice
        return Suggestion(title: title, detail: item.detail ?? "", kind: kind)
    }

    /// Pull the first `{ … }` object out of a model reply (handles code fences).
}
