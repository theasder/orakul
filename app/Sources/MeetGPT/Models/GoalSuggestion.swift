import Foundation

/// Pure helpers for the goal auto-suggest flow (assumption A3 in
/// docs/output-quality.md): the call goal is the keystone every layer keys off
/// (theme inference, grounding queries, the brainstormer), so when the user
/// hasn't set one the app proposes it — from the meeting name / calendar title,
/// or from the opening transcript. The Co-pilot chip still offers one-tap
/// accept into `callGoal`; AI features also use the suggestion immediately so
/// blind spots don't wait on an empty goal field.
enum GoalSuggestion {
    /// Max length a sane goal suggestion can have — beyond this the model
    /// rambled and the suggestion is worthless as a chip.
    static let maxLength = 80

    /// Clean a model-produced goal: strip wrapping quotes/punctuation, reject
    /// the NONE sentinel, multi-line prose, and over-long ramblings.
    static func sanitizeModelGoal(_ raw: String) -> String? {
        let unwrapped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’.,;: "))
        guard !unwrapped.isEmpty else { return nil }
        guard unwrapped.range(of: "\n") == nil else { return nil }
        guard unwrapped.uppercased() != "NONE" else { return nil }
        guard unwrapped.count <= maxLength else { return nil }
        return unwrapped
    }

    /// Whether a calendar event title is specific enough to serve as a goal.
    /// Generic blocks ("Busy", "1:1", "Sync") carry no goal signal.
    static func isUsableCalendarTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 90 else { return false }
        let generic: Set<String> = [
            "busy", "untitled", "no title", "meeting", "call", "sync", "1:1",
            "1-1", "one on one", "catch up", "catch-up", "check-in", "check in",
            "lunch", "hold", "blocked", "focus time", "ooo", "out of office", "standup"
        ]
        return !generic.contains(trimmed.lowercased())
    }

    /// Goal used by AI features when the Co-pilot field is empty:
    /// explicit → meeting name → inferred suggestion.
    static func resolveEffective(callGoal: String,
                                 meetingTitle: String,
                                 suggestedGoal: String?) -> String {
        let explicit = callGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return suggestedGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
