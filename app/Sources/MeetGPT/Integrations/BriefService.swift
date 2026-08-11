import Foundation

/// Asks the backend for a pre-call brief (`POST /api/brief`).
///
/// The connector snippets travel WITH the request. MCP connections live in this
/// app's Keychain, so the backend cannot reach them — it never pretends
/// otherwise, and a brief generated server-side without the app running gets the
/// calendar and ledger halves only.
///
/// The endpoint is designed not to fail: past the daily cap, out of credits, or
/// with the model down it still returns 200 carrying the free ledger half and a
/// `degraded` reason. So callers treat a non-2xx as "no brief this time" and
/// simply show nothing, rather than surfacing an error ten minutes before a
/// meeting the user is about to walk into.
enum BriefService {
    enum Failure: Error, Equatable {
        case notConfigured
        case http(Int)
        case malformed
    }

    /// A connector snippet gathered in-app, sent as quoted evidence.
    struct Source: Encodable, Sendable {
        let server: String
        let text: String
        let readFor: String?
    }

    private struct Request: Encodable {
        let eventId: String
        let title: String
        let startsAt: String
        let attendees: [String]
        let agendaText: String?
        let sources: [Source]
    }

    /// Request (or re-serve) the brief for one meeting.
    ///
    /// Idempotent server-side within its TTL: asking twice inside the window
    /// returns the stored brief and spends nothing, which is what makes it safe
    /// to call on both app launch and reminder tap.
    static func brief(for meeting: UpcomingMeeting,
                      agendaText: String? = nil,
                      sources: [Source] = [],
                      base: String,
                      token: String,
                      session: URLSession = BackendPinning.shared) async throws -> BriefResponse {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !root.isEmpty, let url = URL(string: "\(root)/api/brief") else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Shorter than the ledger calls on purpose. A brief that arrives after
        // the meeting starts has missed its entire purpose, so giving up early
        // and showing nothing beats blocking the panel.
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            eventId: meeting.id,
            title: meeting.title,
            startsAt: ISO8601DateFormatter().string(from: meeting.start),
            attendees: meeting.attendees,
            agendaText: agendaText,
            sources: sources))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(BriefResponse.self, from: data) else {
            throw Failure.malformed
        }
        return decoded
    }

    /// Read a brief the server already generated, without asking for a new one.
    /// Used on launch: a brief may exist from an earlier session or, once the
    /// scheduler lands, from a sweep that ran while the app was closed.
    static func stored(eventID: String, base: String, token: String,
                       session: URLSession = BackendPinning.shared) async throws -> BriefResponse? {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var components = URLComponents(string: "\(root)/api/brief")
        components?.queryItems = [.init(name: "eventId", value: eventID)]
        guard let url = components?.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            // Nothing generated yet is the normal case, not an error.
            if http.statusCode == 404 { return nil }
            guard (200...299).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        }
        return try? JSONDecoder().decode(BriefResponse.self, from: data)
    }
}
