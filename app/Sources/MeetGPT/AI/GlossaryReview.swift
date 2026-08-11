import Foundation

/// Whether to show the vocabulary review after an app connects, and what to
/// apply once it closes.
///
/// Connecting an app is the moment the names about to be spoken become knowable
/// and the moment the user is already thinking about that app, so the review
/// belongs there rather than in a Settings pane nobody opens. The judgement
/// this type makes is about INTERRUPTION, which is wrong in both directions: a
/// sheet during a live call, or no sheet at all and terms that land unseen.
enum GlossaryReview {
    struct Context {
        let candidates: [ConnectedGlossarySuggestion]
        let isRecording: Bool
        /// The user has said they do not want to be asked.
        let reviewsDismissed: Bool

        init(candidates: [ConnectedGlossarySuggestion],
             isRecording: Bool,
             reviewsDismissed: Bool) {
            self.candidates = candidates
            self.isRecording = isRecording
            self.reviewsDismissed = reviewsDismissed
        }
    }

    /// Whether a connection change should leave a review waiting.
    ///
    /// Connecting only raises a flag. Generating candidates costs a background
    /// model call, and the workflow designer holds a deliberate rule that
    /// connection success never spends an LLM request — so the call is deferred
    /// until the user actually looks, which is also the moment a vocabulary
    /// review is worth reading.
    static func marksPending(authorizedApps: Int, isRecording: Bool) -> Bool {
        guard authorizedApps > 0 else { return false }
        // Queuing during a call would surface the moment it ends, which is when
        // the user is reading the summary, not shopping for vocabulary.
        return !isRecording
    }

    static func shouldPresent(_ context: Context) -> Bool {
        guard !context.candidates.isEmpty else { return false }
        // Mid-call is the worst moment for a vocabulary sheet, and the terms
        // keep perfectly well until the meeting ends.
        guard !context.isRecording else { return false }
        return !context.reviewsDismissed
    }

    /// The terms to add once the review is over — or was never shown.
    ///
    /// Skipping is not rejecting. A term the user never looked at is a decision
    /// they have not made, and the recognizer benefits from it either way; but
    /// once they HAVE looked, their selection is the answer, including an empty
    /// one. Falling back to "apply everything" after a deliberate clear-out
    /// would overturn the only explicit instruction in the flow.
    static func resolve(candidates: [ConnectedGlossarySuggestion],
                        reviewed: Bool,
                        keeping kept: Set<String>) -> [String] {
        let eligible = GlossaryAutoApply.termsToAdd(
            suggestions: candidates, existing: "", rejectedKeys: [])
        guard reviewed else { return eligible }
        return eligible.filter { kept.contains($0) }
    }
}
