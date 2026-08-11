import Foundation

/// The post-call reflection artefact: what the transcript does NOT contain.
///
/// Every other post-call output restates the call — decisions, action items, the
/// goal-shaped follow-up. This one exists to say what the room avoided, where a
/// decision rested on thin evidence, which commitment has no owner. If it
/// repeats a summary bullet it is indistinguishable from the thing it was built
/// to differ from, and the user concludes the feature has nothing to add.
///
/// **It produces nothing when there is nothing to say.** That is the hardest
/// property to keep and the most valuable one. A reflection that always emits
/// three points will pad, and padding here is worse than silence: the whole
/// premise is that these are observations worth reading, so filler retroactively
/// devalues the real ones.
///
/// The machinery is the live blind-spot pass — same provider, same judge, same
/// evidence requirement — run once over the finished transcript. Nothing here
/// re-implements judging; this type decides what SURVIVES it.
enum PostCallReflection {

    struct Point: Equatable, Identifiable {
        let id: UUID
        let title: String
        /// The transcript phrase this is about. Quoted exactly, as live blind
        /// spots do — a claim about a call with no quote cannot be checked, and
        /// an unverifiable observation is worse than none.
        let quote: String

        init(id: UUID = UUID(), title: String, quote: String) {
            self.id = id
            self.title = title
            self.quote = quote
        }
    }

    struct Artefact: Equatable {
        let points: [Point]
        /// Points dropped for restating the summary. Surfaced so the reason a
        /// short artefact is short is knowable rather than mysterious.
        let duplicatesRemoved: Int

        var isEmpty: Bool { points.isEmpty }

        static let none = Artefact(points: [], duplicatesRemoved: 0)
    }

    /// Build the artefact from judged suggestions.
    ///
    /// `summary` is whatever the user has already been shown; anything that
    /// restates one of its lines is removed. Un-evidenced suggestions are
    /// dropped outright rather than shown without a quote.
    static func artefact(from suggestions: [Suggestion], summary: String) -> Artefact {
        let evidenced = suggestions.filter { suggestion in
            let quote = (suggestion.evidence ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !quote.isEmpty && !suggestion.title.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
        }
        guard !evidenced.isEmpty else { return .none }

        let summaryLines = ReflectionDedup.summaryLines(from: summary)
        let titles = evidenced.map(\.title)
        let kept = Set(ReflectionDedup.removingSummaryRestatements(titles, summary: summaryLines))

        // Order is the judge's ranking, not this filter's. Rebuilding from the
        // original list preserves it; filtering a Set would not.
        let points = evidenced
            .filter { kept.contains($0.title) }
            .map { Point(title: $0.title,
                         quote: ($0.evidence ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)) }

        return Artefact(points: points,
                        duplicatesRemoved: evidenced.count - points.count)
    }

    /// Whether the pass may run at all.
    ///
    /// Refuses while recording: reflection is about a finished call, and half a
    /// meeting produces observations the room was about to address anyway —
    /// which is exactly the kind of wrong-but-plausible output that teaches
    /// people to stop reading it.
    static func canRun(isRecording: Bool, transcript: String) -> Bool {
        guard !isRecording else { return false }
        // Too short to have avoided anything.
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines).count >= 500
    }
}
