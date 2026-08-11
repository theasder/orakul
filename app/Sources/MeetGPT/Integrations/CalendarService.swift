import Foundation

/// A calendar event distilled into agenda context.
struct CalendarAgenda {
    let title: String
    let summary: String
    /// Number of invited attendees on the event (0 when the field is absent) —
    /// a diarization hint for the remote-audio track.
    var attendeeCount: Int = 0
    /// The Google event id this agenda came from ("" when the payload omits it).
    ///
    /// Carried so the workspace knows WHICH meeting named the call. Without it
    /// hiding a meeting in Focus could only hide a row: the title, the context
    /// file and the attendee count it had already written stayed behind, and the
    /// next recording pulled the same event again.
    var id: String = ""
}

enum MeetingTitlePolicy {
    private static let replaceableTitles = ["", "untitled", "untitled meeting"]
    private static let unusableCalendarTitles = ["calendar event", "meeting"]

    static func applyingCalendarTitle(_ candidate: String, to current: String) -> String {
        let cleanCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCandidate.isEmpty,
              !unusableCalendarTitles.contains(cleanCandidate.lowercased()),
              replaceableTitles.contains(cleanCurrent.lowercased()) else {
            return current
        }
        return cleanCandidate
    }

    /// A placeholder Google gives events with no real name — not worth
    /// announcing in the co-pilot.
    static func isUnusableCalendarTitle(_ title: String) -> Bool {
        unusableCalendarTitles.contains(
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

enum CalendarError: LocalizedError {
    case http(Int)
    case noEvent

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Google Calendar responded \(code)."
        case .noEvent:        return "No calendar event found near now."
        }
    }
}

/// Reads the event closest to "now" from the primary calendar and folds its
/// title / agenda / attendees into a context string. Mirrors the extension's
/// `pullAgenda` op.
enum CalendarService {
    /// - Parameter excluding: event ids the user hid in Focus. A hidden meeting
    ///   is not "the call I am on", so it must not name the call or feed its
    ///   agenda into context — the search falls through to the next event in the
    ///   window instead, and throws `.noEvent` when every candidate is hidden.
    static func currentAgenda(accessToken: String,
                              excluding: Set<String> = [],
                              session: URLSession = .shared) async throws -> CalendarAgenda {
        let now = Date()
        // Google applies timeMin to the event END, so using now keeps an event
        // already in progress while excluding events that have already ended.
        let timeMin = ISO8601DateFormatter().string(from: now)
        let timeMax = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            .init(name: "timeMin", value: timeMin),
            .init(name: "timeMax", value: timeMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime")
        ]
        guard let url = components.url else { throw CalendarError.noEvent }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CalendarError.http(http.statusCode)
        }
        return try parse(data, excluding: excluding)
    }

    /// Lists timed events starting between now and `horizon` from now, soonest
    /// first, for scheduling pre-meeting reminders. All-day events (no
    /// `start.dateTime`) are skipped — they have no meaningful "N minutes before".
    static func upcomingEvents(accessToken: String,
                               horizon: TimeInterval = 24 * 3600,
                               maxResults: Int = 25,
                               session: URLSession = .shared) async throws -> [UpcomingMeeting] {
        let now = Date()
        let timeMin = ISO8601DateFormatter().string(from: now)
        let timeMax = ISO8601DateFormatter().string(from: now.addingTimeInterval(horizon))

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            .init(name: "timeMin", value: timeMin),
            .init(name: "timeMax", value: timeMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: String(maxResults))
        ]
        guard let url = components.url else { throw CalendarError.noEvent }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CalendarError.http(http.statusCode)
        }
        return parseUpcoming(data, after: now)
    }

    static func parseUpcoming(_ data: Data, after now: Date) -> [UpcomingMeeting] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { event -> UpcomingMeeting? in
            guard let id = event["id"] as? String,
                  let start = event["start"] as? [String: Any],
                  let dateTime = start["dateTime"] as? String,   // skips all-day (uses "date")
                  let startDate = rfc3339(dateTime) else { return nil }
            let endDate = ((event["end"] as? [String: Any])?["dateTime"] as? String)
                .flatMap(rfc3339)
            // Keep future events AND events already underway (started, not
            // ended) — launching the app mid-call must still surface the call.
            // Google's timeMin bounds the event END, so in-progress events are
            // present in the response; only genuinely finished ones drop here.
            let inProgress = startDate <= now && (endDate.map { $0 > now } ?? false)
            guard startDate > now || inProgress else { return nil }
            let title = (event["summary"] as? String) ?? "Meeting"
            return UpcomingMeeting(id: id, title: title, start: startDate, end: endDate,
                                   attendees: counterparties(in: event))
        }
    }

    /// The addresses of people actually expected in the room.
    ///
    /// Google's `attendees[]` is messier than it looks, and every kind of row it
    /// contains would poison a lookup keyed on "who am I meeting":
    ///   - the authenticated user's own row (`self: true`) — looking the user up
    ///     in their own CRM
    ///   - conference rooms (`resource: true`) — an address nobody reads
    ///   - rows with no address at all, which Google allows
    ///   - people who declined, who will not be there
    ///
    /// `needsAction` is deliberately KEPT: no answer is not a no, and those
    /// people usually show up.
    static func counterparties(in event: [String: Any]) -> [String] {
        guard let rows = event["attendees"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for row in rows where result.count < UpcomingMeeting.maxAttendees {
            if row["self"] as? Bool == true { continue }
            if row["resource"] as? Bool == true { continue }
            if row["responseStatus"] as? String == "declined" { continue }
            guard let raw = row["email"] as? String else { continue }
            let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, seen.insert(email).inserted else { continue }
            result.append(email)
        }
        return result
    }

    /// Google returns RFC 3339 timestamps, sometimes with fractional seconds.
    private static func rfc3339(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func parse(_ data: Data, excluding: Set<String> = []) throws -> CalendarAgenda {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw CalendarError.noEvent
        }
        // First event the user has NOT hidden. Events without an id cannot be
        // hidden, so they stay eligible.
        guard let event = items.first(where: { event in
            guard let id = event["id"] as? String else { return true }
            return !excluding.contains(id)
        }) else {
            throw CalendarError.noEvent
        }
        return agenda(from: event)
    }

    /// Single-event response (`/events/{id}`) — the object IS the event, with no
    /// `items` wrapper. Split out so picking a meeting in Focus reads exactly the
    /// same fields as the automatic "current agenda" sync.
    static func parseEvent(_ data: Data) throws -> CalendarAgenda {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["summary"] != nil || event["description"] != nil || event["attendees"] != nil
        else { throw CalendarError.noEvent }
        return agenda(from: event)
    }

    private static func agenda(from event: [String: Any]) -> CalendarAgenda {
        let title = (event["summary"] as? String) ?? "Calendar event"
        var lines: [String] = ["Event: \(title)"]
        if let description = event["description"] as? String, !description.isEmpty {
            lines.append("Agenda:\n\(description)")
        }
        let attendees = (event["attendees"] as? [[String: Any]]) ?? []
        let emails = attendees.compactMap { $0["email"] as? String }
        if !emails.isEmpty { lines.append("Attendees: \(emails.joined(separator: ", "))") }
        return CalendarAgenda(title: title, summary: lines.joined(separator: "\n"),
                              attendeeCount: attendees.count,
                              id: (event["id"] as? String) ?? "")
    }

    /// Fetch ONE event by its Google event id — what a Focus row carries.
    ///
    /// `currentAgenda` searches a now→+1h window and takes the first hit, which
    /// cannot serve a row the user picked deliberately: the meeting may start in
    /// forty minutes, or two events may overlap. Addressing the event directly
    /// removes that ambiguity.
    static func agenda(eventID: String,
                       accessToken: String,
                       session: URLSession = .shared) async throws -> CalendarAgenda {
        let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        guard let url = URL(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(encoded)")
        else { throw CalendarError.noEvent }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CalendarError.http(http.statusCode)
        }
        return try parseEvent(data)
    }
}
