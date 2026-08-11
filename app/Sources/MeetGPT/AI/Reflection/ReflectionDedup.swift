import Foundation

/// Keeps the post-call reflection from restating the summary.
///
/// Reflection is meant to say something the transcript does not contain — what
/// the room avoided, where a decision rested on thin evidence, which commitment
/// has no owner. Every other post-call artefact restates what happened, so a
/// reflection that repeats a summary bullet is not merely redundant: it is
/// indistinguishable from the thing it was built to be different from, and the
/// user learns the feature has nothing to add.
///
/// The analysis itself reuses the blind-spot pipeline, which is already
/// evidence-bound and judged. This is the part that is genuinely new.
///
/// Built on `ReflectionCritics.similarity` rather than a second measure. That
/// one is a blunt word-overlap score, which matters here in a specific way: it
/// MISSES paraphrases that share no vocabulary, so it under-removes. Erring
/// that way is right — dropping a real insight because it rhymes with a summary
/// bullet costs more than letting one near-duplicate through.
enum ReflectionDedup {

    /// How much overlap counts as restating a summary point.
    ///
    /// Lower than the blind-spot near-duplicate bar (0.6), because the cost is
    /// asymmetric in the other direction here: two blind spots that overlap are
    /// both still findings, while a reflection overlapping a summary is exactly
    /// the failure the feature must avoid.
    static let summaryOverlapThreshold = 0.45

    /// Reflection points that say something the summary does not.
    ///
    /// Order is preserved: the reflection's own ranking is more meaningful than
    /// anything re-sorting here could add.
    static func removingSummaryRestatements(_ points: [String],
                                            summary: [String]) -> [String] {
        guard !summary.isEmpty else { return points }
        return points.filter { point in
            !summary.contains { restates(point, of: $0) }
        }
    }

    /// Whether `point` restates `summaryLine`.
    static func restates(_ point: String, of summaryLine: String) -> Bool {
        let trimmedPoint = point.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLine = summaryLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPoint.isEmpty, !trimmedLine.isEmpty else { return false }
        return ReflectionCritics.similarity(trimmedPoint, trimmedLine) >= summaryOverlapThreshold
    }

    /// Summary text split into comparable lines.
    ///
    /// A summary arrives as prose with bullets, headings and blank lines. Each
    /// bullet is one claim, so comparison is per line; comparing against the
    /// whole blob would let a long summary swallow every reflection point by
    /// sheer vocabulary.
    static func summaryLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip list markers so "- Maria owns it" and "Maria owns it"
                // are the same claim.
                for marker in ["- ", "* ", "• ", "– "] where trimmed.hasPrefix(marker) {
                    trimmed = String(trimmed.dropFirst(marker.count))
                    break
                }
                // Numbered bullets: "1. ", "2) ".
                if let first = trimmed.first, first.isNumber {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if parts.count == 2, parts[0].allSatisfy({ $0.isNumber || $0 == "." || $0 == ")" }) {
                        trimmed = String(parts[1])
                    }
                }
                return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Headings and separators carry no claim, and a short line has too
            // little vocabulary for the overlap score to mean anything.
            .filter { $0.count >= 12 && !$0.hasPrefix("#") }
    }
}
