import Foundation

/// What the user thought of one answer.
///
/// Stored with the exchange in the session file and nowhere else. Nothing is
/// sent anywhere: the archive already holds the transcript, the prompt and the
/// answer, so the rating sits next to the evidence that explains it, and a
/// user who deletes the session deletes the feedback with it.
///
/// That local corpus is also the point. `ReflectionEval` already judges saved
/// sessions with deterministic critics; a human verdict on the same answers is
/// the label those critics can be checked against — the difference between
/// "the critics fire on 8% of answers" and "the critics agree with the user".
struct AnswerFeedback: Equatable, Codable {
    enum Rating: String, Codable, Equatable {
        case helpful
        case unhelpful
    }

    let rating: Rating
    /// The user's own words. Optional — most feedback is a single click, and
    /// requiring a note would collect far less of it.
    let note: String?
    let at: Date

    /// Long enough for a real thought, short enough that the session file
    /// cannot be grown without bound by one field.
    static let maximumNoteLength = 2000

    init(rating: Rating, note: String? = nil, at: Date = Date()) {
        self.rating = rating
        self.note = Self.sanitize(note)
        self.at = at
    }

    /// Trims and bounds the note, and treats whitespace-only input as absent
    /// so an empty text field does not persist as a note that says nothing.
    static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNoteLength))
    }

    var isHelpful: Bool { rating == .helpful }
}
