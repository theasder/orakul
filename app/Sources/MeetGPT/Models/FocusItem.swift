import Foundation

/// One ranked entry in the Focus panel. Recommendations remain in Co-pilot;
/// Focus is reserved for unique upcoming-meeting reminders and active alerts.
struct FocusItem: Identifiable {
    enum Kind {
        case reminder, risk, question, missingInfo, advice, alert

        var systemImage: String {
            switch self {
            case .reminder:    return "clock"
            case .risk:        return "exclamationmark.triangle"
            case .question:    return "questionmark.bubble"
            case .missingInfo: return "magnifyingglass"
            case .advice:      return "lightbulb"
            case .alert:       return "exclamationmark.triangle.fill"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let score: Double
    /// Retained for decoding/source compatibility; Focus no longer mirrors
    /// Co-pilot suggestions.
    let suggestionID: UUID?
    /// Google event id for a meeting reminder. Carrying it is what makes the row
    /// act on something: without it a reminder is a label with nothing behind it.
    let meetingID: String?

    init(id: String, kind: Kind, title: String, detail: String, score: Double,
         suggestionID: UUID?, meetingID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.score = score
        self.suggestionID = suggestionID
        self.meetingID = meetingID
    }

    /// Reminders are informational; everything else can be acted on.
    /// A meeting reminder is actionable once it knows WHICH meeting it is:
    /// picking it loads that event's title, agenda and attendees into the call
    /// context. Reminders without an event id stay informational.
    var isActionable: Bool { kind != .reminder || meetingID != nil }
}

/// Pure ranking of unique Focus items — kept independent of the view so the
/// ordering is testable.
enum FocusRanking {
    /// Only surface meetings starting within this window — a meeting hours out
    /// isn't "focus" material.
    static let meetingHorizonMinutes = 120.0
    static let maxItems = 5

    static func rank(meetings: [UpcomingMeeting],
                     alert: String?,
                     now: Date,
                     dismissedMeetingIDs: Set<String> = []) -> [FocusItem] {
        // A dismissed meeting stays out of Focus without being touched in
        // Google — the calendar is the user's, not ours to edit.
        let meetings = meetings.filter { !dismissedMeetingIDs.contains($0.id) }
        var items: [FocusItem] = []

        // Reactive alert — an active error needs attention now.
        if let alert, !alert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(FocusItem(id: "alert", kind: .alert,
                                   title: "Needs attention", detail: alert,
                                   score: 1000, suggestionID: nil))
        }

        // Proactive reminders — the sooner a meeting starts, the higher it ranks.
        // A meeting ALREADY underway outranks everything but an alert: the app
        // may have been launched mid-call, and "this call is happening now" is
        // the most actionable thing the panel can say.
        for meeting in meetings {
            if meeting.isInProgress(at: now) {
                let elapsed = Int((now.timeIntervalSince(meeting.start) / 60).rounded())
                items.append(FocusItem(id: "meeting-\(meeting.id)", kind: .reminder,
                                       title: meeting.title,
                                       detail: elapsed <= 1
                                           ? "in progress — just started"
                                           : "in progress — started \(elapsed) min ago",
                                       score: 500,
                                       suggestionID: nil,
                                       meetingID: meeting.id))
                continue
            }
            let minutes = meeting.start.timeIntervalSince(now) / 60
            guard minutes > 0, minutes <= meetingHorizonMinutes else { continue }
            items.append(FocusItem(id: "meeting-\(meeting.id)", kind: .reminder,
                                   title: meeting.title,
                                   detail: relativeStart(minutes: minutes),
                                   score: 130 - minutes,
                                   suggestionID: nil,
                                   meetingID: meeting.id))
        }

        return Array(items.sorted { $0.score > $1.score }.prefix(maxItems))
    }

    static func relativeStart(minutes: Double) -> String {
        let mins = Int(minutes.rounded())
        if mins <= 0 { return "starting now" }
        if mins < 60 { return "in \(mins) min" }
        let hours = mins / 60, remainder = mins % 60
        return remainder == 0 ? "in \(hours) hr" : "in \(hours) hr \(remainder) min"
    }
}
