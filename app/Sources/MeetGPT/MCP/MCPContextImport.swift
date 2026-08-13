import Foundation
import MCP

/// A transcript pulled from Fireflies, ready to fold into meeting context.
struct FirefliesTranscript {
    let title: String
    let text: String
}

// MARK: - Tool schema helpers

extension Tool {
    /// Object properties of the input schema, when present.
    var schemaProperties: [String: Value]? {
        guard case .object(let schema) = inputSchema,
              case .object(let properties)? = schema["properties"] else { return nil }
        return properties
    }

    func hasArgument(_ name: String) -> Bool { schemaProperties?[name] != nil }

    /// Argument names the schema marks required. Used to decide whether an
    /// action can run unattended: a tool demanding `projectId` or `channel`
    /// needs a picker, and a one-click chip that fails on click is worse than
    /// one that was never offered.
    var requiredArgumentKeys: [String] {
        guard case .object(let schema) = inputSchema,
              case .array(let required)? = schema["required"] else { return [] }
        return required.compactMap { value in
            if case .string(let name) = value { return name }
            return nil
        }
    }

    /// Best property to carry a free-text input: a preferred name first, else
    /// the alphabetically-first string-typed property. Sorted on purpose —
    /// Swift Dictionary order is randomized per launch, and a nondeterministic
    /// fallback would target a different argument every run.
    func stringArgumentKey(preferring preferred: [String]) -> String? {
        guard let properties = schemaProperties else { return nil }
        for name in preferred where properties[name] != nil { return name }
        for (key, spec) in properties.sorted(by: { $0.key < $1.key }) {
            if case .object(let details) = spec,
               case .string(let type)? = details["type"], type == "string" {
                return key
            }
        }
        return nil
    }
}

// MARK: - Domain imports over MCP

/// The classic Fireflies / Notion context imports, migrated onto the keyless
/// MCP path. Argument names are resolved from the server's live tool schema
/// (not hardcoded), so schema evolution degrades gracefully.
extension MCPConnectionManager {
    /// The MCP path should serve an integration when a live session exists or
    /// a stored token allows a silent reconnect.
    func prefersMCP(_ serverID: String) -> Bool {
        isConnected(serverID) || isAuthorized(serverID)
    }

    /// Latest Fireflies meeting as context: list the newest meeting (JSON), then
    /// upgrade to the full transcript when the meeting id can be extracted.
    /// Falls back to the summary-level listing text.
    func firefliesLatestTranscript() async throws -> FirefliesTranscript {
        try await firefliesTranscript(near: nil)
    }

    /// How close a Fireflies meeting has to start to the call before it counts
    /// as THE SAME meeting. Fireflies bots join around the scheduled minute, so
    /// half an hour is generous; a match further out is a different call.
    nonisolated static let firefliesMatchWindow: TimeInterval = 30 * 60

    /// Prefer the Fireflies meeting whose date is closest to `near` (session
    /// start). Falls back to the newest listing when dates are missing.
    ///
    /// - Parameter within: when set, a meeting outside this window of `near` is
    ///   NOT the call and the call throws instead of merging it. Fireflies does
    ///   not attend every meeting; without the window a call it never joined
    ///   quietly absorbed whatever meeting happened to be newest.
    func firefliesTranscript(near target: Date?,
                             within tolerance: TimeInterval? = nil) async throws -> FirefliesTranscript {
        let server = try requireServer("fireflies", displayName: "Fireflies")
        let list = try await requireTool(server: server, named: ["fireflies_get_transcripts"])

        // Schema-verified against the live server: limit caps results, and
        // format "json" gives a parseable `[{"id":"…","title":"…",…}]` payload.
        var arguments: [String: Value] = [:]
        if list.hasArgument("limit") { arguments["limit"] = .int(target == nil ? 1 : 8) }
        if list.hasArgument("format") { arguments["format"] = .string("json") }
        let listText = try await callToolText(server: server, tool: list.name,
                                              arguments: arguments.isEmpty ? nil : arguments)
        guard !listText.isEmpty else {
            throw MCPConnectionError.toolFailed(list.name, "no transcripts found")
        }

        let pick = Self.pickFirefliesMeeting(from: listText, near: target, within: tolerance)
        if tolerance != nil, pick.id == nil, pick.title == nil {
            throw MCPConnectionError.toolFailed(list.name, "no Fireflies meeting matches this call")
        }
        let title = pick.title ?? Self.firstJSONString("title", in: listText) ?? "Fireflies transcript"
        let id = pick.id ?? Self.firstJSONString("id", in: listText)

        if let id,
           let detail = try? await requireTool(server: server, named: ["fireflies_get_transcript"]),
           let key = detail.stringArgumentKey(preferring: ["transcriptId", "transcript_id", "id"]),
           let full = try? await callToolText(server: server, tool: detail.name,
                                              arguments: [key: .string(id)]),
           !full.isEmpty {
            return FirefliesTranscript(title: title, text: full)
        }
        return FirefliesTranscript(title: title, text: listText)
    }

    /// Best meeting id/title from a Fireflies list payload for `near`.
    ///
    /// With `within` set the answer is strict: no meeting inside the window (or
    /// a listing with no usable dates) returns `(nil, nil)` rather than the
    /// newest meeting, because "closest" is meaningless for a call Fireflies
    /// never attended.
    nonisolated static func pickFirefliesMeeting(from listText: String,
                                                 near target: Date?,
                                                 within tolerance: TimeInterval? = nil) -> (id: String?, title: String?) {
        let meetings = parseFirefliesMeetings(listText)
        guard !meetings.isEmpty else {
            if tolerance != nil { return (nil, nil) }
            return (firstJSONString("id", in: listText), firstJSONString("title", in: listText))
        }
        guard let target else {
            if tolerance != nil { return (nil, nil) }
            return (meetings[0].id, meetings[0].title)
        }
        let best = meetings.min { a, b in
            let da = a.date.map { abs($0.timeIntervalSince(target)) } ?? .greatestFiniteMagnitude
            let db = b.date.map { abs($0.timeIntervalSince(target)) } ?? .greatestFiniteMagnitude
            return da < db
        }
        let distance = best?.date.map { abs($0.timeIntervalSince(target)) }
        if let tolerance {
            guard let distance, distance <= tolerance else { return (nil, nil) }
            return (best?.id, best?.title)
        }
        // Reject meetings more than 12h away from the session — likely wrong call.
        if let distance, distance > 12 * 3600 {
            return (meetings[0].id, meetings[0].title)
        }
        return (best?.id ?? meetings[0].id, best?.title ?? meetings[0].title)
    }

    private struct ListedMeeting {
        let id: String?
        let title: String?
        let date: Date?
    }

    nonisolated private static func parseFirefliesMeetings(_ text: String) -> [ListedMeeting] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            // Sometimes the tool wraps JSON in prose — pull the array slice.
            guard let start = text.firstIndex(of: "["),
                  let end = text.lastIndex(of: "]"),
                  start < end,
                  let data = String(text[start...end]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                return []
            }
            return meetings(fromJSON: json)
        }
        return meetings(fromJSON: json)
    }

    nonisolated private static func meetings(fromJSON json: Any) -> [ListedMeeting] {
        let rows: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let dict = json as? [String: Any],
                  let array = dict["transcripts"] as? [[String: Any]]
                    ?? dict["data"] as? [[String: Any]]
                    ?? dict["meetings"] as? [[String: Any]] {
            rows = array
        } else {
            return []
        }
        return rows.map { row in
            let id = (row["id"] as? String)
                ?? (row["transcript_id"] as? String)
                ?? (row["transcriptId"] as? String)
            let title = row["title"] as? String
            let date = parseMeetingDate(
                row["date"] ?? row["meeting_date"] ?? row["meetingDate"]
                    ?? row["createdAt"] ?? row["created_at"] ?? row["start_time"]
            )
            return ListedMeeting(id: id, title: title, date: date)
        }
    }

    nonisolated private static func parseMeetingDate(_ raw: Any?) -> Date? {
        if let n = raw as? Double {
            // Fireflies sometimes returns ms since epoch.
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = raw as? Int {
            let v = Double(n)
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Fetch a Notion page/database by pasted URL or ID via `notion-fetch`
    /// (documented to accept either).
    func notionFetchDocument(urlOrID: String) async throws -> FetchedDocument {
        let server = try requireServer("notion", displayName: "Notion")
        let fetch = try await requireTool(server: server, named: ["notion-fetch", "fetch"])
        let key = fetch.stringArgumentKey(preferring: ["url", "id", "page_id", "pageId", "query"]) ?? "id"
        let text = try await callToolText(server: server, tool: fetch.name,
                                          arguments: [key: .string(urlOrID)])
        guard !text.isEmpty else {
            throw MCPConnectionError.toolFailed(fetch.name, "the page had no readable text")
        }
        return FetchedDocument(title: Self.markdownTitle(of: text) ?? "Notion page", text: text)
    }

    // MARK: Plumbing

    private func requireServer(_ id: String, displayName: String) throws -> MCPServerDescriptor {
        guard let server = servers.first(where: { $0.id == id }) else {
            throw MCPConnectionError.notConnected(displayName, "not in the catalog")
        }
        return server
    }

    /// Connect (silent when a token is cached) and resolve a tool by exact
    /// name, else by case-insensitive contains.
    private func requireTool(server: MCPServerDescriptor, named candidates: [String]) async throws -> Tool {
        if !isConnected(server.id) { await connect(server) }
        let available = tools(for: server.id)
        guard !available.isEmpty else {
            if case .failed(let message) = state(of: server.id) {
                throw MCPConnectionError.notConnected(server.name, message)
            }
            throw MCPConnectionError.notConnected(server.name, nil)
        }
        for name in candidates {
            if let tool = available.first(where: { $0.name == name }) { return tool }
        }
        if let fuzzy = available.first(where: { tool in
            candidates.contains { tool.name.localizedCaseInsensitiveContains($0) }
        }) {
            return fuzzy
        }
        throw MCPConnectionError.toolFailed(candidates[0], "no matching tool on \(server.name)")
    }

    /// First `"field": "value"` in a JSON payload (shape verified against the
    /// live Fireflies MCP response).
    nonisolated private static func firstJSONString(_ field: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(field)\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// A leading markdown heading, if the document starts with one.
    private static func markdownTitle(of text: String) -> String? {
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first,
              firstLine.hasPrefix("#") else { return nil }
        let title = firstLine.drop(while: { $0 == "#" || $0 == " " })
        return title.isEmpty ? nil : String(title.prefix(80))
    }
}

// MARK: - Past Fireflies calls

extension MCPConnectionManager {
    /// Recent Fireflies meetings to choose from — the "which past call?" list.
    ///
    /// Distinct from `firefliesTranscript(near:)`, which answers "which meeting
    /// is the call I am in right now?" and merges it live. Here nothing is
    /// matched to a session: the user picks.
    func firefliesRecentMeetings(limit: Int = 25) async throws -> [FirefliesPastCalls.MeetingSummary] {
        let server = try requireServer("fireflies", displayName: "Fireflies")
        let list = try await requireTool(server: server, named: ["fireflies_get_transcripts"])

        var arguments: [String: Value] = [:]
        if list.hasArgument("limit") { arguments["limit"] = .int(max(1, min(limit, 100))) }
        if list.hasArgument("format") { arguments["format"] = .string("json") }
        let text = try await callToolText(server: server, tool: list.name,
                                          arguments: arguments.isEmpty ? nil : arguments)
        guard !text.isEmpty else {
            throw MCPConnectionError.toolFailed(list.name, "no transcripts found")
        }
        // `nil` — ответ не разобрали. Пустой список тут означал бы «прошлых
        // звонков нет», и человек решил бы, что импортировать нечего, тогда
        // как схема у сервиса могла просто смениться.
        guard let meetings = FirefliesPastCalls.parsedMeetingList(text) else {
            throw MCPConnectionError.toolFailed(
                list.name, "не удалось разобрать список встреч Fireflies")
        }
        return meetings
    }

    /// One past meeting as a saved session: the transcript with its speakers,
    /// ready for History to open and for blind spots and the assistant to work
    /// on exactly as they would on a call recorded here.
    func firefliesImportMeeting(_ meeting: FirefliesPastCalls.MeetingSummary,
                                goal: String = "") async throws -> SavedSession {
        let server = try requireServer("fireflies", displayName: "Fireflies")
        let detail = try await requireTool(server: server, named: ["fireflies_get_transcript"])
        guard let key = detail.stringArgumentKey(preferring: ["transcriptId", "transcript_id", "id"]) else {
            throw MCPConnectionError.toolFailed(detail.name, "no transcript id argument")
        }
        let text = try await callToolText(server: server, tool: detail.name,
                                          arguments: [key: .string(meeting.id)])
        guard !text.isEmpty else {
            throw MCPConnectionError.toolFailed(detail.name, "transcript was empty")
        }

        let utterances = FirefliesPastCalls.parseUtterances(text)
        guard !utterances.isEmpty else {
            // Better to refuse than to import an empty session that the user
            // then asks questions of and gets confident answers about nothing.
            throw MCPConnectionError.toolFailed(detail.name, "transcript had no readable speech")
        }
        return FirefliesPastCalls.session(for: meeting, utterances: utterances, goal: goal)
    }
}
