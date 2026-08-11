import Foundation

/// Deterministic quality gates for structured button outputs (A6). Checks what
/// a model audit can only promise: quotes must appear verbatim in the
/// transcript (whitespace/case-normalized), owners must have been mentioned or
/// flagged, contracts must hold. Violations drive one targeted repair pass;
/// whatever still fails is *downgraded* mechanically (quote dropped, owner →
/// flag) — the output degrades honestly instead of fabricating.
enum ArtifactValidator {
    struct Violation: Equatable, CustomStringConvertible {
        let field: String
        let message: String

        var description: String { "\(field): \(message)" }
    }

    // MARK: - Text normalization

    /// Lowercase, collapse whitespace/newlines, strip curly quotes — so a quote
    /// re-wrapped by the model still matches the transcript it came from.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "[“”\"'`’‘…]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    /// Whether a claimed quote actually appears in the transcript. Quotes under
    /// 8 normalized characters are too generic to verify — treated as present.
    static func quoteAppears(_ quote: String, in transcript: String) -> Bool {
        let needle = normalize(quote)
        guard needle.count >= 8 else { return true }
        return normalize(transcript).contains(needle)
    }

    /// An owner is honest when flagged, or when the name was actually said —
    /// full form or first token — anywhere in the transcript.
    static func ownerIsGrounded(_ owner: String?, transcript: String) -> Bool {
        guard let owner, !owner.isEmpty else { return true }   // nil renders as OPEN/[OWNER?]
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.uppercased() == "OPEN" { return true }
        let haystack = normalize(transcript)
        let full = normalize(trimmed)
        if !full.isEmpty, haystack.contains(full) { return true }
        if let first = full.split(separator: " ").first, first.count >= 3,
           haystack.contains(String(first)) { return true }
        return false
    }

    // MARK: - Tasks

    static func validate(tasks artifact: TasksArtifact, transcript: String) -> [Violation] {
        var violations: [Violation] = []
        if artifact.items.isEmpty {
            violations.append(Violation(field: "items", message: "no action items extracted"))
        }
        for (index, item) in artifact.items.enumerated() {
            if item.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(Violation(field: "items[\(index)].task", message: "empty task"))
            }
            if !ownerIsGrounded(item.owner, transcript: transcript) {
                violations.append(Violation(field: "items[\(index)].owner",
                                            message: "owner \"\(item.owner ?? "")\" was never mentioned — use [OWNER?]"))
            }
        }
        return violations
    }

    /// Mechanical downgrade: whatever repair couldn't fix is flagged, never kept
    /// as fabrication.
    static func downgrade(tasks artifact: TasksArtifact, transcript: String) -> TasksArtifact {
        var fixed = artifact
        fixed.items = artifact.items
            .filter { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                var item = item
                if !ownerIsGrounded(item.owner, transcript: transcript) { item.owner = "[OWNER?]" }
                return item
            }
        return fixed
    }

    // MARK: - Summary

    static func validate(summary artifact: SummaryArtifact, transcript: String) -> [Violation] {
        var violations: [Violation] = []
        if artifact.tldr.isEmpty {
            violations.append(Violation(field: "tldr", message: "TL;DR is required"))
        }
        if artifact.tldr.count > 3 {
            violations.append(Violation(field: "tldr", message: "TL;DR must be at most 3 bullets"))
        }
        func check(_ items: [SummaryArtifact.QuotedItem]?, field: String) {
            for (index, item) in (items ?? []).enumerated() {
                if let quote = item.quote, !quote.isEmpty, !quoteAppears(quote, in: transcript) {
                    violations.append(Violation(field: "\(field)[\(index)].quote",
                                                message: "quote not found verbatim in the transcript"))
                }
            }
        }
        check(artifact.decisions, field: "decisions")
        check(artifact.risks, field: "risks")
        for (index, action) in (artifact.actions ?? []).enumerated() {
            if !ownerIsGrounded(action.owner, transcript: transcript) {
                violations.append(Violation(field: "actions[\(index)].owner",
                                            message: "owner \"\(action.owner ?? "")\" was never mentioned"))
            }
        }
        let statuses: Set<String> = ["kept", "slipped", "reopened"]
        for (index, entry) in (artifact.continuity ?? []).enumerated() {
            if !statuses.contains(entry.status.lowercased()) {
                violations.append(Violation(field: "continuity[\(index)].status",
                                            message: "status must be kept|slipped|reopened"))
            }
        }
        return violations
    }

    static func downgrade(summary artifact: SummaryArtifact, transcript: String) -> SummaryArtifact {
        var fixed = artifact
        fixed.tldr = Array(artifact.tldr.prefix(3))
        func scrub(_ items: [SummaryArtifact.QuotedItem]?) -> [SummaryArtifact.QuotedItem]? {
            items?.map { item in
                var item = item
                if let quote = item.quote, !quote.isEmpty, !quoteAppears(quote, in: transcript) {
                    item.quote = nil   // keep the item, drop the unverifiable quote
                    item.speaker = nil
                }
                return item
            }
        }
        fixed.decisions = scrub(artifact.decisions)
        fixed.risks = scrub(artifact.risks)
        fixed.actions = artifact.actions?.map { action in
            var action = action
            if !ownerIsGrounded(action.owner, transcript: transcript) { action.owner = nil }  // renders OPEN
            return action
        }
        let statuses: Set<String> = ["kept", "slipped", "reopened"]
        fixed.continuity = artifact.continuity?.filter { statuses.contains($0.status.lowercased()) }
        return fixed
    }
}
