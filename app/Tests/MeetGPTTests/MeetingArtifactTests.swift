import Foundation
import Testing
@testable import MeetGPT

/// Structured meeting artifacts: decode from the model's JSON, then render.
///
/// This file had NO coverage at all, which matters more than the number
/// suggests: it is the export path. Everything here ends up in a spreadsheet, a
/// clipboard, or a document someone else opens, so a rendering bug leaves the
/// product and lands in a colleague's inbox.
///
/// The suite is layered on one base fact — a sheet decoded from wire JSON —
/// with each later test adding a dimension to that same artifact: escaping,
/// defaults, absent fields, round-tripping, and the case where a spreadsheet
/// reads a cell as code.
@Suite("Meeting artifacts")
struct MeetingArtifactTests {

    /// The shape the model actually returns: every optional genuinely optional.
    private func decodeSheet(_ json: String) throws -> SheetArtifact {
        try JSONDecoder().decode(SheetArtifact.self, from: Data(json.utf8))
    }

    private let sheetJSON = """
    {"columns":["Task","Owner","Due","Priority","Status"],
     "rows":[
       {"task":"Draft the pricing page","owner":"Ana","due":"Friday","priority":"high","status":"open"},
       {"task":"Email the top 20 accounts","owner":"Bo","due":"next week","priority":"medium","status":"open"}
     ]}
    """

    // MARK: - Base

    @Test("a sheet decodes from the model's JSON and renders every row")
    func decodesAndRenders() throws {
        let sheet = try decodeSheet(sheetJSON)
        #expect(sheet.rows?.count == 2)

        let csv = sheet.csv
        let lines = csv.components(separatedBy: "\n")
        #expect(lines.count == 3, "header + one line per row")
        #expect(lines[0] == "Task,Owner,Due,Priority,Status")
        #expect(lines[1].contains("Draft the pricing page"))
        #expect(lines[2].contains("Bo"))
    }

    // MARK: - Layered on the base

    @Test("a comma in a task cannot shift every later column")
    func escapesCommas() throws {
        // Unquoted, this silently moves Owner into Due for that row — the file
        // still opens, so nobody notices until the data is wrong.
        let sheet = try decodeSheet("""
        {"rows":[{"task":"Ship pricing, then billing","owner":"Ana"}]}
        """)
        let row = sheet.csv.components(separatedBy: "\n")[1]
        #expect(row.hasPrefix("\"Ship pricing, then billing\""))
        #expect(row.contains(",Ana,"))
    }

    @Test("quotes are doubled, not dropped")
    func escapesQuotes() throws {
        let sheet = try decodeSheet("""
        {"rows":[{"task":"Rename the \\"quick win\\" column"}]}
        """)
        let row = sheet.csv.components(separatedBy: "\n")[1]
        #expect(row.hasPrefix("\"Rename the \"\"quick win\"\" column\""))
    }

    @Test("a newline inside a cell stays inside that cell")
    func escapesNewlines() throws {
        let sheet = try decodeSheet("""
        {"rows":[{"task":"Line one\\nLine two"}]}
        """)
        let csv = sheet.csv
        // Quoted, so the embedded newline does not create a phantom row: a
        // naive line count would see three lines, but only one is a record.
        #expect(csv.contains("\"Line one\nLine two\""))
        #expect(csv.hasPrefix("Task,Owner"))
    }

    @Test("a cell that looks like a formula is neutralised")
    func neutralisesFormulaInjection() throws {
        // The rows are model output derived from a transcript and whatever
        // documents were in context, and this CSV is meant to drop straight
        // into Sheets/Excel. A task spoken — or pasted — as a formula would
        // otherwise execute when a colleague opens the file.
        for trigger in ["=", "+", "-", "@"] {
            let sheet = try decodeSheet("""
            {"rows":[{"task":"\(trigger)HYPERLINK(\\"http://example.test\\",\\"click\\")"}]}
            """)
            let row = sheet.csv.components(separatedBy: "\n")[1]
            #expect(row.hasPrefix("\"'\(trigger)HYPERLINK"),
                    "\(trigger) was not neutralised: \(row)")
        }
    }

    @Test("ordinary text is not mangled by the formula guard")
    func leavesNormalTextAlone() throws {
        // Over-escaping is its own bug: every cell prefixed with an apostrophe
        // would be visible in some readers and wrong in all of them.
        let sheet = try decodeSheet("""
        {"rows":[{"task":"Reduce latency by 20%","owner":"Ana","due":"2026-09-01"}]}
        """)
        let row = sheet.csv.components(separatedBy: "\n")[1]
        #expect(row == "Reduce latency by 20%,Ana,2026-09-01,,open")
        #expect(!row.contains("'"))
    }

    @Test("absent columns fall back to the standard header, absent status to open")
    func appliesDefaults() throws {
        let sheet = try decodeSheet("""
        {"rows":[{"task":"Confirm the vendor date"}]}
        """)
        let lines = sheet.csv.components(separatedBy: "\n")
        #expect(lines[0] == "Task,Owner,Due,Priority,Status")
        // A row with nothing but a task still lands in the right columns, and
        // an unstated status reads as open rather than blank.
        #expect(lines[1] == "Confirm the vendor date,,,,open")
    }

    @Test("an empty sheet renders a header and no rows, never a crash")
    func handlesEmptySheet() throws {
        let sheet = try decodeSheet("{}")
        #expect(sheet.csv == "Task,Owner,Due,Priority,Status")
        #expect(sheet.markdown.components(separatedBy: "\n").count == 2,
                "header + separator only")
    }

    @Test("markdown and csv describe the same rows")
    func markdownAgreesWithCSV() throws {
        // Two renderers, one artifact: they must not disagree about content,
        // because the user copies one and exports the other.
        let sheet = try decodeSheet(sheetJSON)
        let markdownRows = sheet.markdown.components(separatedBy: "\n").dropFirst(2)
        let csvRows = sheet.csv.components(separatedBy: "\n").dropFirst(1)
        #expect(markdownRows.count == csvRows.count)
        #expect(sheet.markdown.contains("| Draft the pricing page |"))
        #expect(sheet.markdown.contains("| --- |"), "separator row keeps it a table")
    }

    @Test("a decoded artifact survives a round trip")
    func roundTrips() throws {
        let sheet = try decodeSheet(sheetJSON)
        let encoded = try JSONEncoder().encode(sheet)
        let again = try JSONDecoder().decode(SheetArtifact.self, from: encoded)
        #expect(again == sheet)
        #expect(again.csv == sheet.csv)
    }

    // MARK: - The enum around the artifacts

    @Test("only a sheet offers CSV; the other kinds report their own kind")
    func kindAndCSVAvailability() throws {
        let sheet = MeetingArtifact.sheet(try decodeSheet(sheetJSON))
        #expect(sheet.kind == .sheet)
        #expect(sheet.csv != nil)

        let deck = MeetingArtifact.deck(try JSONDecoder().decode(
            DeckArtifact.self, from: Data("""
            {"title":"Q3 review","slides":[{"heading":"Pricing","bullets":["Ship Friday"]}]}
            """.utf8)))
        #expect(deck.kind == .deck)
        #expect(deck.csv == nil, "a deck has no rows to export")
        #expect(deck.markdown.contains("# Q3 review"))
        #expect(deck.markdown.contains("## 1. Pricing"))
        #expect(deck.markdown.contains("- Ship Friday"))
    }

    @Test("a deck omits the sections it has no content for")
    func deckOmitsEmptySections() throws {
        // An empty subtitle must not render as a stray italic line, and a
        // slide with no bullets must not leave a dangling list.
        let deck = try JSONDecoder().decode(DeckArtifact.self, from: Data("""
        {"title":"Kickoff","subtitle":"","slides":[{"heading":"Scope"}]}
        """.utf8))
        let markdown = deck.markdown
        #expect(markdown.contains("# Kickoff"))
        #expect(!markdown.contains("__"), "empty subtitle rendered as emphasis")
        #expect(!markdown.contains("- "), "no bullets means no list")
    }

    @Test("minutes render every populated section and skip the rest")
    func minutesRenderSelectively() throws {
        let minutes = try JSONDecoder().decode(MinutesArtifact.self, from: Data("""
        {"title":"Weekly sync","date":"2026-08-06","attendees":["Ana","Bo"],
         "summary":"Pricing ships Friday.",
         "decisions":["Launch moves to September"],
         "actionItems":[{"task":"Send the contract","owner":"Maria","due":"Friday"}]}
        """.utf8))
        let markdown = minutes.markdown

        #expect(markdown.contains("**Date:** 2026-08-06"))
        #expect(markdown.contains("**Attendees:** Ana, Bo"))
        #expect(markdown.contains("## Decisions"))
        #expect(markdown.contains("## Action items"))
        #expect(markdown.contains("- Send the contract — **Maria** (due Friday)"))
        // Absent sections leave no empty headings behind.
        #expect(!markdown.contains("## Discussion"))
        #expect(!markdown.contains("## Next steps"))
    }

    @Test("an action item without an owner or a due date still renders cleanly")
    func minutesHandleSparseActionItems() throws {
        // The common real case: the model heard a task but no owner. It must
        // not invent " — " or " (due )" punctuation around nothing.
        let minutes = try JSONDecoder().decode(MinutesArtifact.self, from: Data("""
        {"title":"Sync","actionItems":[{"task":"Confirm the vendor date"}]}
        """.utf8))
        #expect(minutes.markdown.contains("- Confirm the vendor date"))
        #expect(!minutes.markdown.contains("—"))
        #expect(!minutes.markdown.contains("(due"))
    }
}

/// The OTHER CSV exporter — behind the Tasks button, and the one users actually
/// hand to a colleague. It was a second, independent copy of the same escaping
/// rules, so a fix applied to `SheetArtifact` would have missed it entirely.
/// Both now route through one escaper; these tests are what keeps them joined.
@Suite("Tasks CSV export")
struct TasksArtifactCSVTests {

    private func tasks(_ json: String) throws -> TasksArtifact {
        try JSONDecoder().decode(TasksArtifact.self, from: Data(json.utf8))
    }

    @Test("a task list exports a header and one line per item")
    func exportsRows() throws {
        let artifact = try tasks("""
        {"items":[{"task":"Draft the pricing page","owner":"Ana","due":"Friday"}]}
        """)
        let lines = artifact.csv.components(separatedBy: "\n")
        #expect(lines[0] == "Task,Owner,Due,Done check,Dependency,Source,Tracked")
        #expect(lines[1].hasPrefix("Draft the pricing page,Ana,Friday"))
        #expect(lines[1].hasSuffix("no"), "an untracked item says so")
    }

    @Test("this exporter neutralises formulas too")
    func neutralisesFormulaInjection() throws {
        for trigger in ["=", "+", "-", "@"] {
            let artifact = try tasks("""
            {"items":[{"task":"\(trigger)cmd|' /c calc'!A1"}]}
            """)
            let row = artifact.csv.components(separatedBy: "\n")[1]
            #expect(row.hasPrefix("'\(trigger)cmd") || row.hasPrefix("\"'\(trigger)cmd"),
                    "\(trigger) survived unescaped: \(row)")
        }
    }

    @Test("commas and quotes cannot shift columns here either")
    func escapesSeparators() throws {
        let artifact = try tasks("""
        {"items":[{"task":"Ship pricing, then billing","owner":"the \\"growth\\" team"}]}
        """)
        let row = artifact.csv.components(separatedBy: "\n")[1]
        #expect(row.hasPrefix("\"Ship pricing, then billing\","))
        #expect(row.contains("\"the \"\"growth\"\" team\""))
    }

    @Test("missing owner and due keep their explicit placeholders")
    func placeholdersSurvive() throws {
        // "[OWNER?]" is deliberate — a blank cell reads as "nobody needs to do
        // this", the placeholder reads as "this still needs an owner". The
        // formula guard must not mangle the bracket, and must not fire on it.
        let artifact = try tasks("""
        {"items":[{"task":"Confirm the vendor date"}]}
        """)
        let row = artifact.csv.components(separatedBy: "\n")[1]
        #expect(row.contains("[OWNER?]"))
        #expect(row.contains("[DUE?]"))
        #expect(!row.contains("'[OWNER?]"))
    }
}
