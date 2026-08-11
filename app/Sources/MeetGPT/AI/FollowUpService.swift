import Foundation

/// Turns a finished button run into suggested next presses ("Follow up"):
/// one cheap fast-model call over EVERYTHING that produced the output — the
/// request, the material it used (context + connected-app grounding), and the
/// answer itself — so the suggestions reference this output's specifics, not
/// generic meeting advice.
enum FollowUpService {
    static let maxSuggestions = 3
    /// Inputs are clipped so the epilogue stays cheap on long calls.
    static let materialCap = 4_000
    static let outputCap = 6_000

    static let systemPrompt = """
    You design quick follow-up actions for a live meeting co-pilot. Given the user's request, \
    the material that was used to answer it, and the answer produced, propose exactly \
    \(maxSuggestions) follow-up actions the user would plausibly want next. Each must be \
    grounded in THIS answer's specifics (its open questions, named owners, risks, gaps) — never \
    generic. Each prompt must be a self-contained instruction that works against the live \
    transcript and context.
    Return ONLY a JSON array, no prose, no code fences:
    [{"icon":"<one emoji>","title":"<max 4 words>","prompt":"<full instruction>"}]
    """

    static func userMessage(request: String, material: String, output: String) -> String {
        var parts = ["Request:\n\(request)"]
        let trimmedMaterial = material.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMaterial.isEmpty {
            parts.append("Material used (context + connected-app grounding):\n\(String(trimmedMaterial.prefix(materialCap)))")
        }
        parts.append("Answer produced:\n\(String(output.prefix(outputCap)))")
        return parts.joined(separator: "\n\n")
    }

    private struct Suggestion: Decodable {
        let icon: String?
        let title: String
        let prompt: String
    }

    /// Defensive parse: tolerates code fences and prose around the array,
    /// drops malformed entries, caps count and title length.
    static func parse(_ raw: String) -> [QuickPrompt] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let json = Data(raw[start...end].utf8)
        guard let suggestions = try? JSONDecoder().decode([Suggestion].self, from: json) else { return [] }
        // Validate first, cap second — a malformed entry must not eat a slot.
        let valid: [QuickPrompt] = suggestions.compactMap { suggestion in
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = suggestion.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !prompt.isEmpty else { return nil }
            let icon = suggestion.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return QuickPrompt(
                id: "followup-" + UUID().uuidString,
                icon: icon.isEmpty ? "↩️" : String(icon.prefix(2)),
                title: String(title.prefix(40)),
                tooltip: String(prompt.prefix(80)),
                prompt: prompt
            )
        }
        return Array(valid.prefix(maxSuggestions))
    }
}
