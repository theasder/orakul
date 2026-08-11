import Foundation

/// Untitled meetings stay untitled — nobody renames "Untitled meeting" mid-call.
/// Five minutes in, if the title is still empty, propose one derived from the
/// transcript (a chip next to the title field; the user accepts or dismisses —
/// never silently applied).
enum MeetingTitleProposal {
    /// How long to wait before proposing. Long enough that the meeting has a
    /// subject; short enough that the title is still useful during the call.
    static let delaySeconds: UInt64 = 300

    static func shouldPropose(title: String,
                              transcriptCharacters: Int,
                              isRecording: Bool) -> Bool {
        isRecording
            && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transcriptCharacters > 0   // no transcript → a title would be invented
    }

    static let systemPrompt = """
    Name this meeting from its transcript.
    Use 3 to 7 words in the transcript's language.
    Name the concrete subject being discussed, not "Meeting" or "Call".
    Return only the title: no quotation marks, label, markdown, or final period.
    """
}
