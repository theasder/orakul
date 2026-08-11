import Foundation

/// One speaker's turn, in seconds from the start of the recording.
///
/// Deliberately not FluidAudio's `TimedSpeakerSegment`: the mapping rules below
/// are the part worth testing, and they must be testable on a machine with no
/// CoreML models present.
struct SpeakerSegment: Equatable {
    let speakerID: String
    let startSeconds: Float
    let endSeconds: Float
}

/// Maps diarizer turns onto transcript lines (roadmap F5).
///
/// The mined pain is not "we want speaker labels" — it is that everyone's
/// labels are wrong the moment two people talk at once: "speaker attribution
/// broke down when people talked over each other, which is every product
/// review I run." So overlap is decided by who holds the LINE, not by who
/// happened to be talking at its first instant.
enum SpeakerAssignment {

    /// How much audio a transcript line is assumed to cover when the entry
    /// itself carries no duration. Long enough to span a spoken sentence,
    /// short enough that two adjacent lines rarely claim the same turn.
    static let defaultLineDuration: TimeInterval = 4

    /// Display form. Whatever the model calls a cluster — "speaker_2", "3" —
    /// the transcript says "Speaker X", the same shape the cloud pass emits,
    /// so exports and the renderer's cross-track suppression keep working.
    static func label(for speakerID: String) -> String {
        let trimmed = speakerID
            .replacingOccurrences(of: "speaker", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return "Speaker \(trimmed.isEmpty ? speakerID : trimmed)"
    }

    static func distinctSpeakers(in segments: [SpeakerSegment]) -> Int {
        Set(segments.map(\.speakerID)).count
    }

    /// Label the remote track from the diarizer's turns.
    ///
    /// Two rules protect the transcript from being made worse: the microphone
    /// track is never touched (that speaker is known — it is the user), and a
    /// line the diarizer says nothing about keeps whatever label it already
    /// had. A pass that can only add information cannot regress a session.
    static func apply(segments: [SpeakerSegment],
                      to entries: [TranscriptEntry],
                      sessionStart: Date,
                      lineDuration: TimeInterval = defaultLineDuration) -> [TranscriptEntry] {
        guard !segments.isEmpty else { return entries }

        return entries.map { entry in
            guard entry.source != .mic else { return entry }
            let from = Float(entry.timestamp.timeIntervalSince(sessionStart))
            let to = from + Float(lineDuration)

            var bestID: String?
            var bestOverlap: Float = 0
            for segment in segments {
                let overlap = min(to, segment.endSeconds) - max(from, segment.startSeconds)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestID = segment.speakerID
                }
            }
            guard let bestID else { return entry }
            return TranscriptEntry(id: entry.id, source: entry.source, text: entry.text,
                                   timestamp: entry.timestamp, speaker: label(for: bestID),
                                   transcriptionEngine: entry.transcriptionEngine)
        }
    }
}
