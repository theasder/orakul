import Foundation

/// The commitments this Mac already holds, read back across meetings (F2).
///
/// Every saved session carries the Efficiency Engine's scored action items.
/// Nobody reads them twice — "the summary existed. The doing didn't." This
/// reads them back, and derives the one signal the individual records cannot
/// show on their own: the SAME promise made in several meetings. A commitment
/// re-promised three weeks running is not a to-do, it is evidence that nothing
/// happened, and it is the cheapest honest thing to put in front of someone
/// before the next occurrence of that meeting.
///
/// Deterministic and local: no model, no network, no spend.
enum OpenCommitments {

    struct Commitment: Equatable {
        let title: String
        let owner: String?
        let due: String?
        let sessionID: UUID
        let sessionTitle: String
        let promisedAt: Date
        /// Server-side quality score (owner + date + one clear ask).
        let score: Double
    }

    struct RepeatedPromise: Equatable {
        /// Display form, taken from the most recent time it was promised.
        let title: String
        let owner: String?
        let count: Int
        let firstPromisedAt: Date
        let lastPromisedAt: Date
        let sessionTitles: [String]
    }

    /// Normalised key for "the same promise": case-folded, punctuation-free,
    /// whitespace-collapsed. Deliberately not fuzzy — a near-match between two
    /// different commitments would merge them and under-report both, which is
    /// worse than missing a rephrasing.
    static func key(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Words that carry no meeting identity — every calendar is full of them,
    /// and letting "weekly" match "weekly" would make every recurring meeting
    /// inherit every other one's commitments.
    private static let titleStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "with", "to", "on", "in",
        "meeting", "call", "sync", "weekly", "daily", "monthly", "standup",
        "review", "catch", "up", "chat", "1on1", "11", "session", "followup",
        "follow", "check",
    ]

    private static func titleTokens(_ title: String) -> Set<String> {
        Set(key(title).split(separator: " ").map(String.init))
            .subtracting(titleStopwords)
    }

    /// Whether two meeting titles name the same recurring thread. Jaccard over
    /// identity-carrying tokens: "Pricing sync" and "Pricing sync follow-up"
    /// are the same thread; "Pricing sync" and "Design review" are not.
    static func titlesMatch(_ a: String, _ b: String, threshold: Double = 0.34) -> Bool {
        let left = titleTokens(a), right = titleTokens(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let overlap = Double(left.intersection(right).count)
        return overlap / Double(left.union(right).count) >= threshold
    }

    static func all(store: SessionStore = .shared) -> [Commitment] {
        all(in: store.list())
    }

    /// Same, over sessions the caller has already loaded.
    ///
    /// `SessionStore.list()` decodes every session JSON on disk. Callers that
    /// need commitments AND the sessions themselves must read once and pass
    /// them here — re-reading per call turned the pre-call brief into hundreds
    /// of redundant JSON decodes.
    static func all(in sessions: [SavedSession]) -> [Commitment] {
        sessions.flatMap { session in
            (session.followUp?.actionItems ?? []).map { item in
                Commitment(title: item.title,
                           owner: (item.owner?.isEmpty ?? true) ? nil : item.owner,
                           due: (item.due?.isEmpty ?? true) ? nil : item.due,
                           sessionID: session.id,
                           sessionTitle: session.displayTitle,
                           promisedAt: session.startedAt,
                           score: item.score)
            }
        }
    }

    /// Promises made in two or more DISTINCT meetings, worst first.
    ///
    /// Distinct sessions, not distinct records: one meeting listing the same
    /// item twice is a duplicate in the follow-up, not a broken promise.
    static func repeatedPromises(store: SessionStore = .shared) -> [RepeatedPromise] {
        repeatedPromises(in: store.list())
    }

    static func repeatedPromises(in sessions: [SavedSession]) -> [RepeatedPromise] {
        var grouped: [String: [Commitment]] = [:]
        for commitment in all(in: sessions) {
            grouped[key(commitment.title), default: []].append(commitment)
        }
        return grouped.values.compactMap { group -> RepeatedPromise? in
            let bySession = Dictionary(grouping: group, by: \.sessionID)
            guard bySession.count >= 2 else { return nil }
            let ordered = group.sorted { $0.promisedAt < $1.promisedAt }
            guard let latest = ordered.last, let earliest = ordered.first else { return nil }
            return RepeatedPromise(
                title: latest.title,
                owner: ordered.reversed().first(where: { $0.owner != nil })?.owner,
                count: bySession.count,
                firstPromisedAt: earliest.promisedAt,
                lastPromisedAt: latest.promisedAt,
                sessionTitles: ordered.map(\.sessionTitle))
        }
        .sorted { ($0.count, $0.lastPromisedAt.timeIntervalSince1970)
                > ($1.count, $1.lastPromisedAt.timeIntervalSince1970) }
    }
}
