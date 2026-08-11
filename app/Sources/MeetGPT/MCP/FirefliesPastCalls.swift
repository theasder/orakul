import Foundation

/// Past Fireflies meetings, imported as ordinary saved sessions.
///
/// The existing Fireflies path answers one question — "which Fireflies meeting
/// is the call I am in right now?" — and merges it into the live transcript.
/// This answers a different one: "show me the calls I already had, so I can
/// look for blind spots in them and ask about them."
///
/// The design choice that matters is what an imported meeting BECOMES. It
/// becomes a `SavedSession`, the same type History already opens. Blind-spot
/// scanning, the assistant chat, prompt buttons and export then work on it
/// without knowing it came from Fireflies at all. The alternative — a parallel
/// read-only viewer for imported transcripts — would have meant reimplementing
/// every one of those against a second model.
///
/// A Fireflies transcript arrives as sentences with a speaker name and a
/// millisecond offset. Flattening that to one text blob would cost exactly what
/// makes the co-pilot useful: blind spots quote evidence and attribute it, and
/// "someone said X" is worth much less than "Marek said X". So the parse keeps
/// per-sentence speakers and rebuilds wall-clock timestamps from the meeting's
/// start.
enum FirefliesPastCalls {

    /// One row of the Fireflies meeting list, enough to choose from.
    struct MeetingSummary: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let date: Date?
        /// Participant names when the listing carries them — the fastest way for
        /// a human to recognise a call whose title is "Weekly sync".
        let participants: [String]
        let durationSeconds: Double?

        var displayTitle: String { title.isEmpty ? "Untitled meeting" : title }
    }

    /// A parsed Fireflies sentence: who said it and when, relative to the start.
    struct Utterance: Equatable, Sendable {
        let speaker: String?
        let text: String
        let offsetSeconds: Double
    }

    // MARK: - Parsing the meeting list

    /// Meetings from a `fireflies_get_transcripts` payload, newest first.
    ///
    /// Tolerates the three shapes the tool has been observed to return: a bare
    /// array, an object wrapping one under `transcripts`/`data`/`meetings`, and
    /// either of those with prose around it.
    static func parseMeetingList(_ text: String) -> [MeetingSummary] {
        guard let json = looseJSON(text) else { return [] }
        let rows: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let dict = json as? [String: Any] {
            rows = (dict["transcripts"] as? [[String: Any]])
                ?? (dict["data"] as? [[String: Any]])
                ?? (dict["meetings"] as? [[String: Any]])
                ?? []
        } else {
            rows = []
        }

        let summaries: [MeetingSummary] = rows.compactMap { row in
            guard let id = (row["id"] as? String)
                    ?? (row["transcript_id"] as? String)
                    ?? (row["transcriptId"] as? String),
                  !id.isEmpty else {
                // Without an id the meeting cannot be fetched, so offering it
                // would be a row that fails when tapped.
                return nil
            }
            return MeetingSummary(
                id: id,
                title: (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                date: parseDate(row["date"] ?? row["meeting_date"] ?? row["meetingDate"]
                                ?? row["createdAt"] ?? row["created_at"] ?? row["start_time"]),
                participants: parseParticipants(row),
                durationSeconds: parseDuration(row["duration"] ?? row["duration_seconds"])
            )
        }

        // Newest first. Meetings with no date sort last rather than being
        // dropped: an undated meeting is still one the user may want to open.
        return summaries.sorted { left, right in
            switch (left.date, right.date) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.displayTitle < right.displayTitle
            }
        }
    }

    // MARK: - Parsing one transcript

    /// Sentences from a `fireflies_get_transcript` payload, in spoken order.
    ///
    /// Falls back to plain-text line splitting when the payload carries no
    /// structured sentences, so a meeting still imports — with no speakers,
    /// which the caller can see and the user can be told.
    static func parseUtterances(_ text: String) -> [Utterance] {
        if let json = looseJSON(text) {
            let sentences = sentenceRows(from: json)
            if !sentences.isEmpty {
                var running: Double = 0
                return sentences.compactMap { row in
                    let spoken = ((row["text"] as? String)
                                  ?? (row["sentence"] as? String)
                                  ?? (row["raw_text"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !spoken.isEmpty else { return nil }

                    let speaker = speakerName(from: row)
                    let offset = parseOffsetSeconds(row["start_time"] ?? row["startTime"]
                                                    ?? row["start"] ?? row["time"])
                    // Fireflies usually supplies offsets. When a sentence is
                    // missing one, keeping the previous value preserves order
                    // instead of collapsing everything onto the meeting start.
                    if let offset { running = offset }
                    return Utterance(speaker: speaker, text: spoken, offsetSeconds: running)
                }
            }
        }
        return plainTextUtterances(text)
    }

    /// Sentences as transcript entries anchored to a real clock.
    ///
    /// Everything is attributed to `.system`: an imported call is somebody
    /// else's recording, and claiming any line came from this machine's
    /// microphone would put words in the user's mouth in every later quote.
    static func transcriptEntries(from utterances: [Utterance],
                                  startedAt: Date) -> [TranscriptEntry] {
        utterances.map { utterance in
            TranscriptEntry(
                source: .system,
                text: utterance.text,
                timestamp: startedAt.addingTimeInterval(utterance.offsetSeconds),
                speaker: utterance.speaker,
                transcriptionEngine: nil
            )
        }
    }

    // MARK: - Building the session

    /// The imported meeting as a `SavedSession`.
    ///
    /// `startedAt` is the meeting's own date when Fireflies supplied one, so
    /// History sorts an imported call among the others by when it HAPPENED
    /// rather than when it was imported. Without that, importing six months of
    /// meetings would stack them all at today.
    static func session(for meeting: MeetingSummary,
                        utterances: [Utterance],
                        goal: String = "",
                        importedAt: Date = Date()) -> SavedSession {
        let startedAt = meeting.date ?? importedAt
        let entries = transcriptEntries(from: utterances, startedAt: startedAt)
        let speakers = Set(utterances.compactMap { $0.speaker }).sorted()

        return SavedSession(
            id: UUID(),
            title: meeting.displayTitle,
            startedAt: startedAt,
            savedAt: importedAt,
            goal: goal,
            entries: entries,
            // No answer yet: importing a call is not asking anything about it.
            // The user opens it and asks, exactly as with a recorded session.
            aiResponse: "",
            digest: digest(for: meeting, utterances: utterances, speakers: speakers)
        )
    }

    /// One line describing the import, shown where History shows a digest.
    static func digest(for meeting: MeetingSummary,
                       utterances: [Utterance],
                       speakers: [String]) -> String {
        var parts = ["Imported from Fireflies"]
        if !speakers.isEmpty {
            parts.append(speakers.count == 1
                         ? "1 speaker: \(speakers[0])"
                         : "\(speakers.count) speakers: \(speakers.prefix(4).joined(separator: ", "))")
        } else {
            // Worth saying plainly: without speakers every later quote reads
            // "someone said", and the user should know why.
            parts.append("no speaker labels in the source")
        }
        parts.append("\(utterances.count) lines")
        if let duration = meeting.durationSeconds, duration > 0 {
            parts.append("\(Int((duration / 60).rounded())) min")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private static func sentenceRows(from json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]],
           array.contains(where: { $0["text"] != nil || $0["sentence"] != nil }) {
            return array
        }
        guard let dict = json as? [String: Any] else { return [] }
        if let sentences = (dict["sentences"] as? [[String: Any]])
            ?? (dict["transcript"] as? [[String: Any]])
            ?? (dict["utterances"] as? [[String: Any]]) {
            return sentences
        }
        // One more level: { transcript: { sentences: [...] } }
        if let nested = dict["transcript"] as? [String: Any] {
            return (nested["sentences"] as? [[String: Any]]) ?? []
        }
        if let data = dict["data"] as? [String: Any] {
            return (data["sentences"] as? [[String: Any]]) ?? []
        }
        return []
    }

    private static func speakerName(from row: [String: Any]) -> String? {
        let raw = (row["speaker_name"] as? String)
            ?? (row["speakerName"] as? String)
            ?? (row["speaker"] as? String)
            ?? (row["speaker_id"] as? String)
            ?? (row["speaker_id"] as? Int).map { "Speaker \($0)" }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Fireflies reports offsets in seconds, but has also been seen sending
    /// milliseconds. A meeting is not 40 000 seconds long, so a value that large
    /// is milliseconds — guessing wrong here spreads an hour of talk across a
    /// fake eleven hours and makes every timestamp useless.
    private static func parseOffsetSeconds(_ raw: Any?) -> Double? {
        let value: Double?
        switch raw {
        case let number as Double: value = number
        case let number as Int: value = Double(number)
        case let string as String: value = Double(string)
        default: value = nil
        }
        guard let value, value >= 0 else { return nil }
        return value > 36_000 ? value / 1000 : value
    }

    private static func parseParticipants(_ row: [String: Any]) -> [String] {
        let raw = row["participants"] ?? row["attendees"] ?? row["meeting_attendees"]
        if let names = raw as? [String] {
            return names.compactMap { trimmedOrNil($0) }
        }
        if let objects = raw as? [[String: Any]] {
            return objects.compactMap {
                trimmedOrNil(($0["displayName"] as? String)
                             ?? ($0["name"] as? String)
                             ?? ($0["email"] as? String) ?? "")
            }
        }
        return []
    }

    private static func parseDuration(_ raw: Any?) -> Double? {
        switch raw {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lines of a prose transcript, honouring a leading "Name:" when present.
    private static func plainTextUtterances(_ text: String) -> [Utterance] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Utterance? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                // "Marek: we should wait for legal" -> speaker + text. Guarded by
                // a length cap so a sentence containing a colon is not mistaken
                // for an attribution.
                if let colon = trimmed.firstIndex(of: ":") {
                    let name = String(trimmed[trimmed.startIndex..<colon])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty, looksLikeSpeakerName(name) {
                        return Utterance(speaker: name, text: body, offsetSeconds: 0)
                    }
                }
                return Utterance(speaker: nil, text: trimmed, offsetSeconds: 0)
            }
    }

    /// Whether the text before a colon is plausibly a person rather than the
    /// first clause of a sentence.
    ///
    /// A length cap alone is not enough: "The plan is simple: ship US-only" put
    /// "The plan is simple" forward as a speaker, which would attach a
    /// fabricated name to a real quote in every later answer that cites it.
    /// Requiring every word to be capitalised separates "Ada", "Ada Lovelace"
    /// and "Speaker 1" from ordinary prose, which carries lower-case words.
    static func looksLikeSpeakerName(_ name: String) -> Bool {
        let words = name.split(separator: " ")
        guard (1...3).contains(words.count), name.count <= 40 else { return false }
        return words.allSatisfy { word in
            guard let first = word.first else { return false }
            return first.isUppercase || first.isNumber
        }
    }

    private static func looseJSON(_ text: String) -> Any? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        // Tools sometimes wrap the payload in prose; take the widest bracket
        // slice and try again.
        for (open, close) in [("[", "]"), ("{", "}")] {
            if let start = text.firstIndex(of: Character(open)),
               let end = text.lastIndex(of: Character(close)),
               start < end,
               let data = String(text[start...end]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
        }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        switch raw {
        case let number as Double:
            // Fireflies sends epoch milliseconds; seconds would place every
            // meeting in 1970.
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        case let number as Int:
            return parseDate(Double(number))
        case let string as String:
            if let iso = ISO8601DateFormatter().date(from: string) { return iso }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let iso = withFraction.date(from: string) { return iso }
            if let epoch = Double(string) { return parseDate(epoch) }
            return nil
        default:
            return nil
        }
    }
}
