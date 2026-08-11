import Foundation

/// Feeds the pre-call brief with this Mac's own meeting history (roadmap F8).
///
/// The mined pain: walking into a call blind to what was promised last time —
/// "by Tuesday someone pinged me asking if we had actually decided that or
/// just floated it as an option." The brief endpoint already accepts quoted
/// `sources` gathered in-app (that is how MCP snippets travel), so the prior-
/// meeting record rides the SAME contract: recall hits for the upcoming
/// meeting's title become sources, each one a verbatim excerpt naming the
/// session it came from. No backend change, no extra spend — the ledger half
/// of the brief simply gains the local record it could never see.
enum BriefRecallSources {

    static let serverLabel = "prior-meetings"
    static let commitmentsLabel = "open-commitments"
    private static let maxSources = 3
    private static let maxCommitments = 5

    static func build(for meeting: UpcomingMeeting,
                      store: SessionStore = .shared,
                      embedder: any SkillTextEmbedder = RecallEmbedder.production) -> [BriefService.Source] {
        let query = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return DecisionRecallService.recall(query: query, store: store,
                                            embedder: embedder, limit: maxSources)
            .map { hit in
                BriefService.Source(
                    server: serverLabel,
                    text: "[\(hit.sessionTitle) · \(formatter.string(from: hit.startedAt))] \(hit.excerpt)",
                    readFor: meeting.title)
            }
    }

    /// What was promised the last time this meeting's topic came up (F2).
    ///
    /// Sourced from the sessions recall already identifies as relevant, so a
    /// weekly sync carries ITS commitments and not the whole backlog. An
    /// ownerless promise says "no owner" out loud: naming the gap is the entire
    /// value, and a silent omission would read as "nothing outstanding".
    static func commitments(for meeting: UpcomingMeeting,
                            store: SessionStore = .shared,
                            embedder: any SkillTextEmbedder = RecallEmbedder.production) -> [BriefService.Source] {
        let query = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        // Two ways a past meeting counts as "this meeting's history": its
        // CONTENT answers the topic (recall), or its TITLE names the same
        // recurring thread. Title matching carries the weekly-sync case, where
        // the useful commitments live and where the digest may say nothing
        // that resembles the calendar title.
        let sessions = store.list()
        var relevantSessions = Set(DecisionRecallService
            .recall(query: query, store: store, embedder: embedder, limit: maxSources)
            .map(\.sessionID))
        for session in sessions where OpenCommitments.titlesMatch(session.displayTitle, query) {
            relevantSessions.insert(session.id)
        }
        guard !relevantSessions.isEmpty else { return [] }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return OpenCommitments.all(in: sessions)
            .filter { relevantSessions.contains($0.sessionID) }
            .sorted { $0.promisedAt > $1.promisedAt }
            .prefix(maxCommitments)
            .map { commitment in
                let owner = commitment.owner ?? "no owner"
                let due = commitment.due.map { ", due \($0)" } ?? ""
                return BriefService.Source(
                    server: commitmentsLabel,
                    text: "[\(commitment.sessionTitle) · \(formatter.string(from: commitment.promisedAt))] "
                        + "\(commitment.title) — \(owner)\(due)",
                    readFor: meeting.title)
            }
    }

    /// Promises this meeting's thread has now made more than once (F2).
    ///
    /// The highest-signal line available before a call, and the one the weekly
    /// digest surfaces too late: a commitment re-made across meetings is
    /// evidence nothing happened, and the moment it matters is just before the
    /// room is about to make it a third time.
    static func repeatedPromises(for meeting: UpcomingMeeting,
                                 store: SessionStore = .shared) -> [BriefService.Source] {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }

        let sessions = store.list()
        let threadSessions = Set(sessions
            .filter { OpenCommitments.titlesMatch($0.displayTitle, title) }
            .map(\.id))
        guard !threadSessions.isEmpty else { return [] }

        // Which promise keys this thread actually contains, built once. The
        // filter below used to call store.list() per candidate promise, which
        // re-decoded every session JSON on disk each time round.
        let threadKeys = Set(sessions
            .filter { threadSessions.contains($0.id) }
            .flatMap { ($0.followUp?.actionItems ?? []).map { OpenCommitments.key($0.title) } })

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return OpenCommitments.repeatedPromises(in: sessions)
            // Only this thread's promises. A repeated commitment from an
            // unrelated meeting is somebody else's problem and would make the
            // brief read as a nag list.
            .filter { threadKeys.contains(OpenCommitments.key($0.title)) }
            .prefix(maxCommitments)
            .map { promise in
                BriefService.Source(
                    server: commitmentsLabel,
                    text: "STILL OPEN — promised \(promise.count)× since "
                        + "\(formatter.string(from: promise.firstPromisedAt)): "
                        + "\(promise.title) (\(promise.owner ?? "no owner"))",
                    readFor: meeting.title)
            }
    }
}
