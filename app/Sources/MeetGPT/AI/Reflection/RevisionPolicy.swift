import Foundation

/// When a second model call is worth making, and what to say in it.
///
/// Self-critique earns its keep only when the critic has a verifier the
/// generator did not use. Asked to "review your work" with nothing to check
/// against, a model revises toward confidence and length rather than truth — it
/// talks itself into a longer, surer, worse answer. So revision here is never
/// speculative: it fires only when a DETERMINISTIC critic has already found
/// something and can name it, and the finding itself is what gets handed over.
///
/// The economics decide where that is allowed. One Pro hour already burns 204 of
/// a 250-credit monthly allowance through the background watches, so a revision
/// inside a 90-second loop would halve the plan's usable minutes. Revision is
/// therefore reserved for output a user asked for and is waiting on.
enum RevisionPolicy {
    enum Surface {
        /// A prompt the user pressed and is watching stream.
        case answer
        /// The 90–300s background loops. Never revised — see above.
        case backgroundWatch
    }

    /// One pass, never a loop. A second costs as much as the first, and the
    /// evidence that iterated self-revision keeps improving anything is thin;
    /// what it reliably does is grow the answer.
    static let maximumPasses = 1

    static func shouldRevise(findings: [ReflectionFinding], surface: Surface) -> Bool {
        guard surface == .answer else { return false }
        return !findings.isEmpty
    }

    /// The revision instruction: the defects, named, plus the one rule that
    /// stops a repair becoming a fabrication.
    static func instruction(for findings: [ReflectionFinding]) -> String {
        guard !findings.isEmpty else { return "" }
        let defects = findings.map { finding -> String in
            let excerpt = finding.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            return excerpt.isEmpty
                ? "- \(finding.detail)"
                : "- \(finding.detail) — “\(ReflectionFinding.clip(excerpt, limit: 160))”"
        }.joined(separator: "\n")

        return """
        Your previous answer has specific, mechanically detected problems:

        \(defects)

        Rewrite it to fix exactly those. Two rules:
        1. Do not invent support for a claim you cannot ground. Remove the claim \
        instead, or say plainly that the transcript does not settle it.
        2. Change nothing else. Do not lengthen, re-order, or restate the parts \
        that were not flagged.
        """
    }
}
