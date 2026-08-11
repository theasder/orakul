import Foundation

/// The structured output of a `MeetingSkill`. Each case is a decoded, typed
/// artifact plus a renderer: `markdown` for on-screen preview and clipboard, and
/// `csv` for the sheet so it drops straight into Sheets/Excel. The structured
/// payloads are also the seam for richer export later — `deck` → Google Slides,
/// `minutes` → Google Docs (GoogleDocsService), `sheet` → GoogleSheetsService or
/// the Decision Ledger's `/action-items` endpoint.
enum MeetingArtifact: Equatable {
    case deck(DeckArtifact)
    case minutes(MinutesArtifact)
    case sheet(SheetArtifact)

    var kind: MeetingSkill.Kind {
        switch self {
        case .deck: return .deck
        case .minutes: return .minutes
        case .sheet: return .sheet
        }
    }

    /// A display/clipboard-ready Markdown rendering of the artifact.
    var markdown: String {
        switch self {
        case .deck(let deck): return deck.markdown
        case .minutes(let minutes): return minutes.markdown
        case .sheet(let sheet): return sheet.markdown
        }
    }

    /// CSV for the action-item sheet (nil for the other kinds).
    var csv: String? {
        if case .sheet(let sheet) = self { return sheet.csv }
        return nil
    }
}

// MARK: - Deck

struct DeckArtifact: Codable, Equatable {
    struct Slide: Codable, Equatable {
        let heading: String
        let bullets: [String]?
        let notes: String?
    }
    let title: String
    let subtitle: String?
    let slides: [Slide]?

    var markdown: String {
        var lines = ["# \(title)"]
        if let subtitle, !subtitle.isEmpty { lines.append("_\(subtitle)_") }
        for (index, slide) in (slides ?? []).enumerated() {
            lines.append("")
            lines.append("## \(index + 1). \(slide.heading)")
            for bullet in slide.bullets ?? [] { lines.append("- \(bullet)") }
            if let notes = slide.notes, !notes.isEmpty { lines.append("> \(notes)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Minutes

struct MinutesArtifact: Codable, Equatable {
    struct Topic: Codable, Equatable { let topic: String; let points: [String]? }
    struct ActionItem: Codable, Equatable { let task: String; let owner: String?; let due: String? }

    let title: String
    let date: String?
    let attendees: [String]?
    let summary: String?
    let decisions: [String]?
    let discussion: [Topic]?
    let actionItems: [ActionItem]?
    let nextSteps: [String]?
    /// Top consequences, filled by `ranked()` (ConsequenceRanker) — never by
    /// the model. Optional and absent from the LLM JSON on purpose: a
    /// model-authored highlights list would be exactly the second
    /// hallucination surface the deterministic ranker exists to avoid.
    let highlights: [String]?
    /// How many unverified figures the footer names before it starts counting.
    static let maxFlaggedFigures = 8
    /// One highlight line. The block exists so the reader sees what mattered in
    /// a glance; a paragraph-long bullet defeats it exactly as a wall of text
    /// defeats the minutes.
    static let maxHighlightCharacters = 160

    /// Figures stated here that the transcript never contains, filled by
    /// `auditingNumbers(against:)` (NumbersGuard) — deterministic, never the
    /// model grading its own numbers.
    let unverifiedFigures: [String]?

    init(title: String, date: String?, attendees: [String]?, summary: String?,
         decisions: [String]?, discussion: [Topic]?, actionItems: [ActionItem]?,
         nextSteps: [String]?, highlights: [String]? = nil,
         unverifiedFigures: [String]? = nil) {
        self.title = title
        self.date = date
        self.attendees = attendees
        self.summary = summary
        self.decisions = decisions
        self.discussion = discussion
        self.actionItems = actionItems
        self.nextSteps = nextSteps
        self.highlights = highlights
        self.unverifiedFigures = unverifiedFigures
    }

    /// A copy carrying the NumbersGuard verdict for this transcript. Run it
    /// AFTER `ranked()` — the audit reads the rendered lines, and the footer
    /// must reflect what the user actually sees.
    func auditingNumbers(against transcript: String) -> MinutesArtifact {
        let flagged = NumbersGuard.unverifiedFigures(artifact: markdown, transcript: transcript)
        guard !flagged.isEmpty else { return self }
        return MinutesArtifact(title: title, date: date, attendees: attendees,
                               summary: summary, decisions: decisions,
                               discussion: discussion, actionItems: actionItems,
                               nextSteps: nextSteps, highlights: highlights,
                               unverifiedFigures: flagged)
    }

    var markdown: String {
        var lines = ["# \(title)"]
        if let date, !date.isEmpty { lines.append("**Date:** \(date)") }
        if let attendees, !attendees.isEmpty { lines.append("**Attendees:** \(attendees.joined(separator: ", "))") }
        if let summary, !summary.isEmpty { lines.append("\n\(summary)") }

        if let highlights, !highlights.isEmpty {
            lines.append("\n## What matters")
            highlights.forEach { lines.append("- \($0)") }
        }
        if let decisions, !decisions.isEmpty {
            lines.append("\n## Decisions")
            decisions.forEach { lines.append("- \($0)") }
        }
        if let discussion, !discussion.isEmpty {
            lines.append("\n## Discussion")
            for topic in discussion {
                lines.append("\n### \(topic.topic)")
                (topic.points ?? []).forEach { lines.append("- \($0)") }
            }
        }
        if let actionItems, !actionItems.isEmpty {
            lines.append("\n## Action items")
            for item in actionItems {
                let owner = item.owner.map { " — **\($0)**" } ?? ""
                let due = item.due.map { " (due \($0))" } ?? ""
                lines.append("- \(item.task)\(owner)\(due)")
            }
            // F2: "an action item without an owner is a wish" (verbatim mined
            // evidence). Naming the wishes is the cheapest possible nudge —
            // no tracker, no notification, just the list refusing to pretend.
            let ownerless = actionItems.filter { ($0.owner ?? "").isEmpty }
            if !ownerless.isEmpty {
                lines.append("\n### Needs an owner")
                ownerless.forEach { lines.append("- \($0.task)") }
            }
        }
        if let nextSteps, !nextSteps.isEmpty {
            lines.append("\n## Next steps")
            nextSteps.forEach { lines.append("- \($0)") }
        }
        if let unverifiedFigures, !unverifiedFigures.isEmpty {
            // Capped: a financial review can restate dozens of numbers, and a
            // warning listing forty of them is one nobody checks. Naming the
            // first few and counting the rest keeps it actionable.
            let shown = unverifiedFigures.prefix(Self.maxFlaggedFigures)
            let rest = unverifiedFigures.count - shown.count
            let tail = rest > 0 ? ", and \(rest) more" : ""
            lines.append("\n### ⚠️ Verify these figures")
            lines.append("Not found in the transcript: \(shown.joined(separator: ", "))\(tail).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Sheet

struct SheetArtifact: Codable, Equatable {
    struct Row: Codable, Equatable {
        let task: String
        let owner: String?
        let due: String?
        let priority: String?
        let status: String?
    }
    let columns: [String]?
    let rows: [Row]?

    private var headers: [String] { columns ?? ["Task", "Owner", "Due", "Priority", "Status"] }

    private func cells(_ row: Row) -> [String] {
        [row.task, row.owner ?? "", row.due ?? "", row.priority ?? "", row.status ?? "open"]
    }

    var markdown: String {
        var lines = ["| " + headers.joined(separator: " | ") + " |",
                     "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"]
        for row in rows ?? [] {
            lines.append("| " + cells(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// Characters that make Excel, Sheets and Numbers treat a cell as a
    /// FORMULA rather than text. A cell beginning with one of these is executed
    /// on open — the classic CSV injection.
    ///
    /// This matters here because the rows are model output derived from a
    /// meeting transcript and whatever connected documents were in context, and
    /// the resulting file is documented as dropping straight into a spreadsheet.
    /// A task literally spoken as "=HYPERLINK(...)" — or copied out of a doc —
    /// would otherwise run in the reader's spreadsheet, not sit in a cell.
    static let formulaTriggers: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    static func escapeCSVField(_ value: String) -> String {
        // Neutralise a leading formula trigger by prefixing an apostrophe: the
        // spreadsheet reads the cell as text and does not display the prefix.
        // Applied before quoting, so quoting still sees the final content.
        var field = value
        if let first = field.first, formulaTriggers.contains(first) {
            field = "'" + field
        }
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    var csv: String {
        var lines = [headers.map(Self.escapeCSVField).joined(separator: ",")]
        for row in rows ?? [] {
            lines.append(cells(row).map(Self.escapeCSVField).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
