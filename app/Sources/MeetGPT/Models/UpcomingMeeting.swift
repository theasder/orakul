import Foundation

/// A calendar event distilled to what reminders and the Focus panel need: a
/// stable id (the Google event id, used as the notification identifier so
/// re-polling reconciles instead of duplicating), a title, and its start/end.
///
/// `end` exists so an event that has already STARTED can still be recognized —
/// launching the app mid-call must surface "this call is happening now", not
/// pretend the calendar is empty. (Reminders themselves still fire only for
/// future starts; the scheduler guards that independently.)
struct UpcomingMeeting: Identifiable, Equatable {
    /// Upper bound on `attendees`. A 200-person all-hands would otherwise become
    /// a 200-key lookup fan-out in every source a pre-call brief consults, and
    /// the hundredth address on an all-hands says nothing the first ten did not.
    static let maxAttendees = 25

    let id: String
    let title: String
    let start: Date
    /// Event end. `nil` when Google supplies no timed end — such an event is
    /// never considered "in progress".
    let end: Date?
    /// Lowercased addresses of the people expected in the room, excluding the
    /// user themselves, resource rooms, and anyone who declined.
    ///
    /// This is the join key for everything a pre-call brief draws on — a CRM
    /// cannot be asked "what do we know about these people" without it, and our
    /// own prior transcripts with the same room are found the same way. Empty
    /// for a solo block, which is still a meeting worth surfacing.
    let attendees: [String]

    init(id: String, title: String, start: Date, end: Date? = nil,
         attendees: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }

    /// True while the event is underway: started, not yet ended.
    func isInProgress(at now: Date = Date()) -> Bool {
        guard let end else { return false }
        return start <= now && now < end
    }
}
