import Foundation

/// The background Facilitation watch: a live meeting-facilitator that reads the
/// goal + recent transcript and flags the SINGLE most important way the meeting
/// is going off the rails right now — drift from the goal, a circular loop, a
/// decision left hanging, or time sunk on a low-value tangent. Surfaced as one
/// short steering note, not a full agenda draft (that's the Current Agenda
/// button). Runs on the fast model tier (cost story) and only when the
/// transcript grew.
enum FacilitationWatch {
    static let systemPrompt = """
    You are a meeting facilitator watching a live call. You are given the meeting's \
    goal and the recent transcript. Flag the SINGLE most important facilitation \
    problem happening right now — drift away from the goal, a circular/looping \
    discussion, a decision left unresolved, an agenda item being skipped, or time \
    sunk on a low-value tangent. Reply with ONE short, specific sentence the \
    facilitator could act on immediately (e.g. "You've drifted onto pricing — the \
    goal was scope; steer back."). If the meeting is on track, reply with exactly NONE.
    """

    /// Compose the user turn from the goal and recent transcript. The goal
    /// anchors what "on track" means; an empty goal falls back to a neutral cue.
    static func userPrompt(goal: String, transcript: String) -> String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalLine = trimmedGoal.isEmpty ? "(no explicit goal set)" : trimmedGoal
        return "Meeting goal: \(goalLine)\n\nRecent transcript:\n\(transcript)"
    }

    /// Parse the model's reply into a steering note, or nil when it found the
    /// meeting on track. Tolerant of a "NONE" sentinel and caps the length so
    /// the panel stays compact.
    static func parse(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.“”"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased() == "NONE" || trimmed.uppercased().hasPrefix("NONE ") { return nil }
        return String(trimmed.prefix(240))
    }
}
