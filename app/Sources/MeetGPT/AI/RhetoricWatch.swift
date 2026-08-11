import Foundation

/// The background Rhetoric watch: a compact, cheap check that flags the single
/// most important rhetorical problem in the live transcript — surfaced as one
/// short note, not the full markdown analysis the Rhetoric button produces.
/// Runs on the fast model tier (cost story) and only when the transcript grew.
enum RhetoricWatch {
    static let systemPrompt = """
    You are a rhetoric watchdog on a live meeting. From the recent transcript, flag the SINGLE most \
    important self-contradiction, unsupported claim, or logical gap — in ONE short sentence a \
    participant could act on right now. Be specific to what was said. If there is nothing worth \
    flagging, reply with exactly NONE.
    """

    /// Parse the model's reply into a note, or nil when it found nothing.
    /// Tolerant of a "NONE" sentinel (with or without trailing prose) and caps
    /// the length so the panel stays compact.
    static func parse(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.“”"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased() == "NONE" || trimmed.uppercased().hasPrefix("NONE ") { return nil }
        return String(trimmed.prefix(240))
    }
}
