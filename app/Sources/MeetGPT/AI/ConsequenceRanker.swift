import Foundation

/// Deterministic consequence scoring for meeting-artifact lines (roadmap F4).
///
/// The mined pain this answers: AI minutes give every bullet equal weight —
/// "'We're changing the entire architecture' sits next to 'Bob will be OOO
/// Friday'" — so nobody reads them. The fix is NOT another model call: ranking
/// runs on every artifact, offline, for free, and a model ranking the model's
/// own summary would add a second hallucination surface to the one artifact
/// that has to stay trustworthy. Keyword tiers are crude and that is fine —
/// the job is separating "sunset the API" from "lunch moved", not literary
/// analysis, and a wrong rank only reorders lines that all remain on screen.
enum ConsequenceRanker {

    /// Score of a line with no signals either way.
    static let baselineScore = 10
    /// Threshold a line reaches with one high-stakes term.
    static let highStakesScore = 30

    /// Hard-to-reverse, expensive-if-missed vocabulary. One hit lifts a line
    /// to the high-stakes tier. Curated, not exhaustive: every term maps to a
    /// mined pain category (cancellations, hiring, security, migrations,
    /// launches, contracts). "pricing" is deliberately absent — bare talk
    /// about pricing is cheap; a line with an actual figure gets the money
    /// bonus instead.
    private static let highStakes = [
        "cancel", "sunset", "deprecat", "shut down",
        "hire", "layoff", "headcount",
        "breach", "credential", "leak", "security", "incident", "rotate",
        "migrat", "architecture", "rewrite", "pivot",
        "launch", "ship date", "slip",
        "contract", "renewal", "churn", "refund",
    ]

    /// Scheduling and housekeeping chatter — real content, low consequence.
    /// "circle back" is here on the strength of the mined quote: it "scores
    /// badly on purpose — nobody can say when it's done."
    private static let housekeeping = [
        "ooo", "pto", "vacation", "out of office",
        "reschedul", "moves to", "shortens to", "rename",
        "circle back", "lunch", "coffee", "birthday",
    ]

    private static let moneyPattern = try! NSRegularExpression(
        pattern: #"[$€£]\s?\d|\b\d+(\.\d+)?\s?(k|m|mm|%|percent)\b"#,
        options: [.caseInsensitive])
    private static let datePattern = try! NSRegularExpression(
        pattern: #"\b(january|february|march|april|may|june|july|august|september|october|november|december|q[1-4]|eow|eom|today|tomorrow)\b"#,
        options: [.caseInsensitive])
    private static let commitmentPattern = try! NSRegularExpression(
        pattern: #"\b(decided|agreed|will|we're going|moving to|committing)\b"#,
        options: [.caseInsensitive])

    static func score(_ text: String) -> Int {
        let lower = text.lowercased()
        var score = baselineScore
        for term in highStakes where lower.contains(term) { score += 20 }
        // One penalty regardless of hit count: "lunch moves to Thursdays" is
        // exactly as much housekeeping as "team lunch" — stacking would make
        // wordier chatter sort below terser chatter for no reason.
        if housekeeping.contains(where: { lower.contains($0) }) { score -= 8 }
        let range = NSRange(lower.startIndex..., in: lower)
        if moneyPattern.firstMatch(in: lower, range: range) != nil { score += 8 }
        if datePattern.firstMatch(in: lower, range: range) != nil { score += 5 }
        if commitmentPattern.firstMatch(in: lower, range: range) != nil { score += 3 }
        return max(score, 0)
    }

    /// An owned, dated commitment is executable; an ownerless one is "a wish"
    /// (verbatim from the mined evidence) — the bonus makes executable items
    /// lead the list without ever hiding the wishes.
    static func score(_ item: MinutesArtifact.ActionItem) -> Int {
        var score = score(item.task)
        if let owner = item.owner, !owner.isEmpty { score += 4 }
        if let due = item.due, !due.isEmpty { score += 2 }
        return score
    }
}

extension MinutesArtifact {

    /// Fewer than this many total lines and the meeting fits on one screen
    /// already — a highlights block would just repeat it.
    private static let highlightsMinimumItems = 5
    private static let highlightsCap = 3

    /// A consequence-ordered copy: decisions and action items sorted by
    /// descending score (stable — ties keep spoken order), plus a `highlights`
    /// digest of the top consequences. Pure reordering: no line is dropped,
    /// reworded, or invented, which is what keeps this safe to run on every
    /// artifact unconditionally.
    func ranked() -> MinutesArtifact {
        let scoredDecisions = (decisions ?? []).enumerated()
            .map { (index: $0.offset, text: $0.element, score: ConsequenceRanker.score($0.element)) }
        let orderedDecisions = scoredDecisions
            .sorted { ($0.score, $1.index) > ($1.score, $0.index) }
        let scoredActions = (actionItems ?? []).enumerated()
            .map { (index: $0.offset, item: $0.element, score: ConsequenceRanker.score($0.element)) }
        let orderedActions = scoredActions
            .sorted { ($0.score, $1.index) > ($1.score, $0.index) }

        let totalItems = scoredDecisions.count + scoredActions.count + (nextSteps?.count ?? 0)
        var highlights: [String] = []
        if totalItems >= Self.highlightsMinimumItems {
            let pool = scoredDecisions.map { ($0.text, $0.score) }
                + scoredActions.map { ($0.item.task, $0.score) }
            highlights = pool
                .filter { $0.1 > ConsequenceRanker.baselineScore }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.highlightsCap)
                .map { entry -> String in
                    guard entry.0.count > Self.maxHighlightCharacters else { return entry.0 }
                    let cut = entry.0.prefix(Self.maxHighlightCharacters)
                    let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
                    return atWord + "…"
                }
            if highlights.count < 2 { highlights = [] }
        }

        return MinutesArtifact(
            title: title, date: date, attendees: attendees, summary: summary,
            decisions: orderedDecisions.isEmpty ? decisions : orderedDecisions.map(\.text),
            discussion: discussion,
            actionItems: orderedActions.isEmpty ? actionItems : orderedActions.map(\.item),
            nextSteps: nextSteps,
            highlights: highlights.isEmpty ? nil : highlights)
    }
}
