import Foundation

/// The duplicate critic, moved in front of the user.
///
/// `ReflectionCritics.judgeBlindSpots` exists partly to measure what production's
/// dedupe lets through: the live gate compares exact lowercased titles, so
/// "Budget owner is unnamed" and "No owner named for the budget" both ship, and
/// the critic counts that afterwards as `blindSpot.nearDuplicate`.
///
/// Counting it is the wrong end. The check is pure string work — no model, no
/// latency worth measuring — so running it IN the gate turns a reported rate
/// into a card the user never sees twice. The threshold is shared with the
/// critic on purpose: if the two drift apart, the eval reports a leak the gate
/// believes it has already closed.
enum SuggestionSuppression {
    static var overlapThreshold: Double { ReflectionCritics.duplicateTitleOverlap }

    /// Whether this card repeats something already on screen.
    static func isRedundant(_ candidate: Suggestion,
                            against existing: [Suggestion]) -> Bool {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A malformed card must not become the twin of everything that follows:
        // similarity over two empty word sets is undefined, not perfect.
        guard !title.isEmpty else { return false }
        return existing.contains { other in
            !other.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ReflectionCritics.similarity(other.title, candidate.title) >= overlapThreshold
        }
    }

    /// Keeps the first of each set of twins, in arrival order.
    ///
    /// First rather than best, on purpose: the earlier card arrived while the
    /// topic was still open, and re-ranking a live list would move a card the
    /// user may already be reading.
    static func filter(_ candidates: [Suggestion],
                       against existing: [Suggestion]) -> [Suggestion] {
        var kept: [Suggestion] = []
        for candidate in candidates {
            guard !isRedundant(candidate, against: existing + kept) else { continue }
            kept.append(candidate)
        }
        return kept
    }
}
