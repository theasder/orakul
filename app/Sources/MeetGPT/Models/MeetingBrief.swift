import Foundation

/// What the user reads in the ten minutes before a meeting.
///
/// `POST /api/brief` deliberately never fails: out of credits, past the daily
/// cap, or with the model unavailable it still returns 200 carrying the free
/// ledger half plus a `degraded` reason. So a partial brief is a NORMAL outcome
/// here, not an error — treating `degraded` as a failure would discard the one
/// half that was always going to work.
///
/// Every property that can be absent is decoded through an explicit initializer
/// rather than a default. A non-optional property with a default is skipped by
/// Swift's synthesized decoding, which has silently broken persisted decoding in
/// this app before.
struct MeetingBrief: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let text: String
        /// Which system this came from, verbatim from the server.
        let source: String
        /// What the line is evidence OF — why it is on screen at all.
        let readFor: String?
    }

    struct OpenItem: Equatable, Sendable {
        let text: String
        let overdue: Bool
        /// How the attendee reached this decision: `participant` (exact) or
        /// `company` (matched on their domain). Kept for provenance.
        let via: String
    }

    struct SuggestedGoal: Equatable, Sendable {
        let goalType: String
        let confidence: Double?
    }

    /// Three points plus two commitments is already at the edge of what someone
    /// reads before walking into a call.
    static let maxFocusLines = 5

    let headline: String?
    let points: [Point]
    let openFromLastTime: [OpenItem]
    let suggestedGoal: SuggestedGoal?

    var hasContent: Bool { !focusLines.isEmpty }

    /// One flat, ranked list for the panel. Overdue commitments lead: they are
    /// the only lines that are a PROBLEM rather than context, and the user may
    /// read exactly one.
    var focusLines: [Line] {
        let overdue = openFromLastTime.filter(\.overdue)
        let pending = openFromLastTime.filter { !$0.overdue }
        let commitments = (overdue + pending).map {
            Line(text: $0.text, source: "your last call", isOverdue: $0.overdue)
        }
        let evidence = points.map {
            Line(text: $0.text, source: $0.source, isOverdue: false, readFor: $0.readFor)
        }
        return Array((commitments + evidence).prefix(Self.maxFocusLines))
    }

    /// A rendered row. The view stays dumb: ordering, capping and attribution
    /// are decided here so they can be tested without SwiftUI.
    struct Line: Identifiable, Equatable, Sendable {
        var id: String { "\(source)-\(text)" }
        let text: String
        let source: String
        let isOverdue: Bool
        var readFor: String?
    }
}

extension MeetingBrief: Decodable {
    private enum CodingKeys: String, CodingKey {
        case headline, points, openFromLastTime, suggestedGoal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        points = try container.decodeIfPresent([Point].self, forKey: .points) ?? []
        openFromLastTime = try container
            .decodeIfPresent([OpenItem].self, forKey: .openFromLastTime) ?? []
        suggestedGoal = try container
            .decodeIfPresent(SuggestedGoal.self, forKey: .suggestedGoal)
    }
}

extension MeetingBrief.Point: Decodable {
    private enum CodingKeys: String, CodingKey { case text, source, readFor }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        readFor = try container.decodeIfPresent(String.self, forKey: .readFor)
    }
}

extension MeetingBrief.OpenItem: Decodable {
    private enum CodingKeys: String, CodingKey { case text, overdue, via }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        overdue = try container.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
        via = try container.decodeIfPresent(String.self, forKey: .via) ?? "unknown"
    }
}

extension MeetingBrief.SuggestedGoal: Decodable {
    private enum CodingKeys: String, CodingKey { case goalType, confidence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalType = try container.decode(String.self, forKey: .goalType)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

/// The `POST /api/brief` envelope.
struct BriefResponse: Decodable, Sendable {
    let brief: MeetingBrief
    let cached: Bool
    let generatedAt: String?
    /// `daily_cap`, `credits`, or `model_unavailable` when only the free half
    /// was produced. Not an error — the brief below it is still worth showing.
    let degraded: String?
    let upgrade: Bool?

    private enum CodingKeys: String, CodingKey {
        case brief, cached, generatedAt, degraded, upgrade
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brief = try container.decode(MeetingBrief.self, forKey: .brief)
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached) ?? false
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        degraded = try container.decodeIfPresent(String.self, forKey: .degraded)
        upgrade = try container.decodeIfPresent(Bool.self, forKey: .upgrade)
    }
}

/// Which meeting, if any, is worth spending a brief on right now.
///
/// Pure so the choice is testable: briefs are capped per day and cost a model
/// call, so picking the wrong meeting is not free.
enum BriefTarget {
    /// Only brief a meeting starting within this window. Facts gathered three
    /// hours out will have changed, and it would burn one of the day's briefs.
    static let leadWindowMinutes = 30.0

    static func next(in meetings: [UpcomingMeeting], now: Date,
                     briefed: Set<String>) -> UpcomingMeeting? {
        meetings
            .filter { meeting in
                // Nobody to look up — a solo focus block has no counterparties.
                guard !meeting.attendees.isEmpty else { return false }
                guard !briefed.contains(meeting.id) else { return false }
                // Already underway counts: launching the app mid-call is exactly
                // when the user has the least context.
                if meeting.isInProgress(at: now) { return true }
                let minutes = meeting.start.timeIntervalSince(now) / 60
                return minutes > 0 && minutes <= leadWindowMinutes
            }
            .min { $0.start < $1.start }
    }
}
