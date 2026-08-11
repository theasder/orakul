import Foundation

/// Asks, once, how the first real meeting went.
///
/// The product question this exists to answer is not "do people download it" —
/// a download is not a user, and a downloader who never launches teaches
/// nothing. It is "did the first real call work", which only somebody who has
/// just finished one can answer.
///
/// So it hangs off `UsageTracker.recordMeeting()`, which already fires only for
/// a call of ten seconds or more. It shows once, ever, and a dismissal counts:
/// asking twice reads as nagging, and the second answer would be worse than the
/// first anyway.
///
/// Unlike ``AnswerFeedback``, which stays on disk on purpose, this is meant to
/// reach us — that is the point of asking. Until an endpoint exists it is
/// recorded locally and marked unsent, so nothing is lost and nothing is
/// silently dropped. ``unsent`` is what a later uploader drains.
enum FirstMeetingPrompt {
    enum Rating: String, Codable, Equatable {
        case good
        case bad
    }

    /// One answer. `sentAt` stays nil until it has actually reached the server,
    /// so a failed upload stays distinguishable from one that never ran.
    struct Response: Codable, Equatable {
        let rating: Rating
        /// The user's own words. Optional: most people click and move on, and
        /// requiring prose would collect far less of it.
        let note: String?
        /// Optional, and asked for last. Making it required turns a feedback
        /// prompt into a lead form — a different, much less answered question.
        let email: String?
        let at: Date
        var sentAt: Date?
    }

    private enum Key {
        static let asked = "feedback.firstMeeting.asked"
        static let response = "feedback.firstMeeting.response"
    }

    /// Where the answer lives. Settable so tests can point at a throwaway suite
    /// rather than the developer's real defaults — a static store shared with
    /// the running app makes a test run leave "already asked" behind on the
    /// machine, which then hides the prompt in manual testing.
    static var defaults: UserDefaults = .standard

    private static var d: UserDefaults { defaults }

    /// True once the prompt has been shown, answered or not.
    static var hasBeenAsked: Bool { d.bool(forKey: Key.asked) }

    /// Whether to show the prompt now, given the meeting count.
    ///
    /// Takes the count rather than reading it, so the decision is testable
    /// without touching `UsageTracker` or the meeting that triggered it.
    static func shouldAsk(meetingsSoFar: Int) -> Bool {
        meetingsSoFar == 1 && !hasBeenAsked
    }

    /// Record that the prompt was shown — called when it appears, not when it
    /// is answered, because a dismissal has to close it permanently too.
    static func markAsked() { d.set(true, forKey: Key.asked) }

    /// Store an answer. Overwrites any previous one; there is only ever one.
    static func record(rating: Rating, note: String?, email: String?, at: Date = Date()) {
        let response = Response(
            rating: rating,
            note: trimmedOrNil(note),
            email: trimmedOrNil(email),
            at: at,
            sentAt: nil)
        guard let data = try? JSONEncoder().encode(response) else { return }
        d.set(data, forKey: Key.response)
        markAsked()
    }

    static var stored: Response? {
        guard let data = d.data(forKey: Key.response) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    /// The answer still waiting to be uploaded, if any.
    static var unsent: Response? {
        guard let response = stored, response.sentAt == nil else { return nil }
        return response
    }

    /// Mark the stored answer as delivered. Separate from `record` so a failed
    /// upload leaves it queued rather than looking sent.
    static func markSent(at: Date = Date()) {
        guard var response = stored else { return }
        response.sentAt = at
        guard let data = try? JSONEncoder().encode(response) else { return }
        d.set(data, forKey: Key.response)
    }

    /// Blank and whitespace-only input becomes nil, not "". An empty string
    /// would otherwise travel as a real answer and read as somebody who
    /// deliberately typed nothing.
    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Test seam. Not for production paths.
    static func resetForTesting() {
        d.removeObject(forKey: Key.asked)
        d.removeObject(forKey: Key.response)
    }
}
