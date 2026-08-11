import Foundation

/// The week's decisions and commitments, assembled locally, per audience (F3).
///
/// Answers two mined pains at once: the PM who spends "45 minutes updating
/// statuses, syncing decisions from Slack into the source of truth" every day,
/// and the stakeholders who ping "what's blocked?" because nothing reaches
/// them. The three audiences differ in what they are ALLOWED to see, not in
/// tone: a stakeholder gets owned commitments, an investor gets consequential
/// decisions and no individual names, the team gets everything including the
/// promises that keep being re-made.
///
/// Produces text and nothing else. There is deliberately no send path: the
/// mined record of this category is full of auto-send disasters ("it
/// automatically emailed me the transcript, including hours of their private
/// conversations"), so the last mile stays a human pasting into a channel they
/// chose. Deterministic, offline, no spend.
enum WeeklyDigest {

    enum Audience: String, CaseIterable {
        case team, stakeholder, investor

        var heading: String {
            switch self {
            case .team: return "Team digest"
            case .stakeholder: return "Stakeholder update"
            case .investor: return "Investor update"
            }
        }
    }

    static let defaultWindow: TimeInterval = 7 * 86_400
    /// An investor update carries only decisions that are expensive to reverse.
    private static var investorFloor: Int { ConsequenceRanker.highStakesScore }
    /// Everything below this is housekeeping, and no audience needs it listed
    /// as a decision of the week.
    private static var decisionFloor: Int { ConsequenceRanker.baselineScore }
    private static let maxDecisions = 8
    /// One decision line. A digest paragraph written without blank lines is a
    /// whole meeting summary, and pasting that into Slack recreates the exact
    /// artefact this feature exists to replace — the wall of text nobody reads.
    private static let maxDecisionCharacters = 240
    /// A heavy week can hold fifty commitments. Past this many the reader is
    /// skimming, so the list says how many it left out instead of pretending
    /// it showed everything.
    private static let maxCommitments = 15
    private static let maxRepeats = 8

    /// Trim to a whole word and mark it, so a truncated line never reads as a
    /// complete sentence that happens to end oddly.
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return atWord + "…"
    }

    private static func overflowNote(_ total: Int, _ shown: Int) -> String? {
        total > shown ? "- …and \(total - shown) more" : nil
    }

    static func build(audience: Audience,
                      store: SessionStore = .shared,
                      now: Date = Date(),
                      window: TimeInterval = defaultWindow) -> String {
        let since = now.addingTimeInterval(-window)
        // One read for everything below: the window, the commitments, and the
        // repeat detection all work off this list rather than re-decoding
        // every session JSON three times over.
        let allSessions = store.list()
        let sessions = allSessions.filter { $0.startedAt >= since && $0.startedAt <= now }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var lines = ["# \(audience.heading)",
                     "_\(formatter.string(from: since)) – \(formatter.string(from: now))_"]

        guard !sessions.isEmpty else {
            lines.append("\nNo meetings recorded in this window.")
            return lines.joined(separator: "\n")
        }

        lines.append("\n\(sessions.count) meeting\(sessions.count == 1 ? "" : "s") recorded: "
                     + sessions.map(\.displayTitle).joined(separator: ", ") + ".")

        // Decisions: every digest paragraph, consequence-scored. The floor is
        // what keeps "lunch moved to Thursdays" out of a weekly summary.
        let floor = audience == .investor ? investorFloor : decisionFloor
        let decisions = sessions
            .flatMap { session in
                session.digest.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { (text: $0, score: ConsequenceRanker.score($0), title: session.displayTitle) }
            }
            .filter { $0.score >= floor }
            .sorted { $0.score > $1.score }
            .prefix(maxDecisions)

        if !decisions.isEmpty {
            lines.append("\n## Decisions")
            for decision in decisions {
                // An investor update reports the company, not the org chart —
                // so no meeting attribution and, with it, no names.
                let attribution = audience == .investor ? "" : " _(\(decision.title))_"
                lines.append("- \(clipped(decision.text, to: maxDecisionCharacters))\(attribution)")
            }
        }

        let commitments = OpenCommitments.all(in: allSessions)
            .filter { $0.promisedAt >= since && $0.promisedAt <= now }

        switch audience {
        case .team:
            if !commitments.isEmpty {
                lines.append("\n## Commitments")
                let ordered = commitments.sorted { $0.promisedAt > $1.promisedAt }
                for commitment in ordered.prefix(maxCommitments) {
                    let owner = commitment.owner ?? "no owner"
                    let due = commitment.due.map { ", due \($0)" } ?? ""
                    lines.append("- \(clipped(commitment.title, to: maxDecisionCharacters)) — \(owner)\(due)")
                }
                if let note = overflowNote(ordered.count, maxCommitments) { lines.append(note) }
            }
            // Internal hygiene only: a promise re-made across meetings is a
            // conversation for the team, never a line in an external update.
            let repeats = OpenCommitments.repeatedPromises(in: allSessions)
            if !repeats.isEmpty {
                lines.append("\n## Still open from earlier")
                for promise in repeats.prefix(maxRepeats) {
                    let owner = promise.owner ?? "no owner"
                    lines.append("- Promised \(promise.count)× — \(clipped(promise.title, to: maxDecisionCharacters)) (\(owner))")
                }
                if let note = overflowNote(repeats.count, maxRepeats) { lines.append(note) }
            }
        case .stakeholder:
            // Owned AND dated: anything less is not something a stakeholder can
            // hold anyone to, and listing it invites the status ping this is
            // meant to prevent.
            let firm = commitments.filter { $0.owner != nil && $0.due != nil }
            if !firm.isEmpty {
                lines.append("\n## Commitments")
                for commitment in firm.prefix(maxCommitments) {
                    lines.append("- \(clipped(commitment.title, to: maxDecisionCharacters)) — \(commitment.owner ?? "") (due \(commitment.due ?? ""))")
                }
                if let note = overflowNote(firm.count, maxCommitments) { lines.append(note) }
            }
        case .investor:
            break   // counts and decisions only
        }

        return lines.joined(separator: "\n")
    }
}
