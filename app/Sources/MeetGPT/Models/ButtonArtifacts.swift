import Foundation

/// Typed output contracts for the structured prompt buttons (A6). Where the
/// other buttons stream markdown, Tasks and Summary produce these records so
/// their quality bars become *checkable*: `ArtifactValidator` verifies quotes
/// verbatim against the transcript and owners against what was actually said,
/// deterministically — no more hoping the model audited itself. The markdown
/// renderers feed the response panel; CSV feeds export.

// MARK: - Tasks

struct TasksArtifact: Codable, Equatable {
    struct Daci: Codable, Equatable {
        let decision: String
        let driver: String?
        let approver: String?
        let contributors: [String]?
        let informed: [String]?
    }

    struct Item: Codable, Equatable {
        var task: String
        /// Stated owner, "[OWNER?]" when unstated. Never an invented name.
        var owner: String?
        /// Stated due, "[DUE?]", or "[DUE?] (suggest: …)" for a marked inference.
        var due: String?
        /// Given/When/Then done-check.
        var doneCheck: String?
        var dependency: String?
        /// The decision/timestamp this task traces to.
        var sourceRef: String?
        /// Already present in a connected tracker (dedupe, don't duplicate).
        var tracked: Bool?
    }

    var dacis: [Daci]?
    var items: [Item]
    var slackSummary: String?

    var markdown: String {
        var lines: [String] = []
        if let dacis, !dacis.isEmpty {
            lines.append("## Decisions (DACI)")
            for daci in dacis {
                lines.append("- **\(daci.decision)**")
                if let v = daci.driver { lines.append("  - Driver: \(v)") }
                if let v = daci.approver { lines.append("  - Approver: \(v)") }
                if let v = daci.contributors, !v.isEmpty { lines.append("  - Contributors: \(v.joined(separator: ", "))") }
                if let v = daci.informed, !v.isEmpty { lines.append("  - Informed: \(v.joined(separator: ", "))") }
            }
            lines.append("")
        }
        lines.append("## Action items")
        for item in items {
            var parts = ["**\(item.task)**"]
            parts.append("— \(item.owner ?? "[OWNER?]")")
            parts.append("· \(item.due ?? "[DUE?]")")
            if item.tracked == true { parts.append("· TRACKED") }
            lines.append("- " + parts.joined(separator: " "))
            if let check = item.doneCheck, !check.isEmpty { lines.append("  - Done when: \(check)") }
            if let dep = item.dependency, !dep.isEmpty { lines.append("  - Depends on: \(dep)") }
            if let src = item.sourceRef, !src.isEmpty { lines.append("  - From: \(src)") }
        }
        if let slack = slackSummary, !slack.isEmpty {
            lines.append("")
            lines.append("## Slack-ready summary")
            lines.append("> " + slack.replacingOccurrences(of: "\n", with: "\n> "))
        }
        return lines.joined(separator: "\n")
    }

    var csv: String {
        // Shares SheetArtifact's escaper rather than repeating it. The two were
        // duplicate implementations of the same rules, so the formula-injection
        // guard added to one would silently have missed this exporter — and
        // this is the one behind the Tasks button, the CSV users actually hand
        // to a colleague.
        var lines = ["Task,Owner,Due,Done check,Dependency,Source,Tracked"]
        for item in items {
            lines.append([item.task, item.owner ?? "[OWNER?]", item.due ?? "[DUE?]",
                          item.doneCheck ?? "", item.dependency ?? "", item.sourceRef ?? "",
                          item.tracked == true ? "yes" : "no"]
                .map(SheetArtifact.escapeCSVField).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Summary

struct SummaryArtifact: Codable, Equatable {
    /// A decision or risk with its anchoring transcript quote.
    struct QuotedItem: Codable, Equatable {
        var text: String
        /// Short verbatim transcript quote backing the item.
        var quote: String?
        var speaker: String?
        var timestamp: String?
    }

    struct Action: Codable, Equatable {
        var task: String
        /// Stated owner or nil → rendered OPEN. Never invented.
        var owner: String?
        var due: String?
        /// Already known to a connected tracker (else NEW).
        var tracked: Bool?
    }

    struct Continuity: Codable, Equatable {
        var commitment: String
        /// kept | slipped | reopened
        var status: String
    }

    var tldr: [String]
    var decisions: [QuotedItem]?
    var actions: [Action]?
    var openQuestions: [String]?
    var risks: [QuotedItem]?
    var continuity: [Continuity]?
    var parkingLot: [String]?
    var nextMeeting: String?

    var markdown: String {
        var lines = ["## TL;DR"]
        lines += tldr.prefix(3).map { "- \($0)" }

        func quoted(_ items: [QuotedItem]?, header: String) {
            guard let items, !items.isEmpty else { return }
            lines.append("\n## \(header)")
            for item in items {
                lines.append("- \(item.text)")
                if let quote = item.quote, !quote.isEmpty {
                    let attribution = [item.speaker, item.timestamp].compactMap { $0 }.joined(separator: ", ")
                    lines.append("  - “\(quote)”" + (attribution.isEmpty ? "" : " — \(attribution)"))
                }
            }
        }
        quoted(decisions, header: "Decisions")

        if let actions, !actions.isEmpty {
            lines.append("\n## Action items")
            for action in actions {
                let owner = action.owner ?? "НЕ УКАЗАНО"
                let due = action.due ?? "НЕ УКАЗАНО"
                let mark = action.tracked == true ? "TRACKED" : "NEW"
                lines.append("- \(action.task) — **\(owner)** · \(due) · \(mark)")
            }
        }
        if let questions = openQuestions, !questions.isEmpty {
            lines.append("\n## Open questions")
            lines += questions.map { "- \($0)" }
        }
        quoted(risks, header: "Risks")
        if let continuity, !continuity.isEmpty {
            lines.append("\n## Continuity")
            lines += continuity.map { "- [\($0.status)] \($0.commitment)" }
        }
        if let parking = parkingLot, !parking.isEmpty {
            lines.append("\n## Parking lot")
            lines += parking.map { "- \($0)" }
        }
        if let next = nextMeeting, !next.isEmpty {
            lines.append("\n## Next meeting")
            lines.append(next)
        }
        return lines.joined(separator: "\n")
    }
}

/// The last structured artifact a button produced — the seam for export
/// (CSV → Sheets, actions → the ledger) and for inspecting validation results.
enum StructuredArtifact: Equatable {
    case tasks(TasksArtifact)
    case summary(SummaryArtifact)

    var markdown: String {
        switch self {
        case .tasks(let artifact): return artifact.markdown
        case .summary(let artifact): return artifact.markdown
        }
    }

    var csv: String? {
        if case .tasks(let artifact) = self { return artifact.csv }
        return nil
    }
}
