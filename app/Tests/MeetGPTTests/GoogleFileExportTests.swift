import Foundation
import Testing
@testable import MeetGPT

/// Turning an answer into a Google file.
///
/// Two properties matter more than the parsing. **Nothing here writes** — every
/// function returns a proposal that goes through the existing confirmation
/// boundary. And **deletion is never inferred**: an answer is not evidence that
/// a file should be destroyed, so no amount of parsing produces a delete.
///
/// The parsing tests are mostly refusals. This runs over every answer the
/// product generates, and a spurious "export this table?" on ordinary prose
/// trains people to ignore the offer — at which point the real ones are missed
/// too.
@Suite("Google file export")
struct GoogleFileExportTests {

    private let answer = """
    Here is the split by owner.

    | Owner | Task | Due |
    | --- | --- | --- |
    | Maria | Contract | Friday |
    | Ana | Backfill | Sept 14 |
    | Tom | DPA | TBD |

    That is everything outstanding.
    """

    // MARK: - Nothing writes

    @Test("every proposal requires confirmation")
    func everyProposalRequiresConfirmation() {
        // Asserted as a property rather than trusted as a convention, so a case
        // added later cannot quietly skip the boundary.
        let table = GoogleFileExport.Table(header: ["A"], rows: [["1"]])
        let all: [GoogleFileExport.Proposal] = [
            .createSpreadsheet(title: "t", table: table),
            .createDocument(title: "t", body: "b"),
            .updateSpreadsheet(fileID: "f", title: "t", table: table),
            .deleteFile(fileID: "f", title: "t", reason: "stale"),
        ]
        for proposal in all { #expect(proposal.requiresConfirmation) }
    }

    // MARK: - Deletion is never inferred

    @Test("an answer never produces a deletion")
    func answersNeverProposeDeletion() {
        // The rule that matters. A model deciding a spreadsheet looks stale is a
        // suggestion, not a warrant — the data is the user's and the action
        // cannot be undone.
        let stale = """
        The numbers in the Q2 sheet are out of date and should be removed.

        | Metric | Old | New |
        | --- | --- | --- |
        | ARR | 1 | 2 |
        | Churn | 3 | 4 |
        """
        for proposal in GoogleFileExport.proposals(forAnswer: stale, title: "Q2") {
            if case .deleteFile = proposal { Issue.record("an answer produced a deletion") }
        }
    }

    @Test("deletion must be asked for explicitly, and names why")
    func deletionIsExplicit() {
        let proposal = GoogleFileExport.deletionProposal(
            fileID: "abc", title: "Q2 numbers", reason: "superseded by Q3",
            createdByUs: true)
        #expect(proposal?.summary.contains("superseded by Q3") == true)
        // "Delete this?" with no reason is a question nobody can answer well.
        #expect(proposal?.summary.contains("cannot be undone") == true)
    }

    @Test("a file we did not create cannot be proposed for deletion")
    func refusesForeignFiles() {
        // drive.file could not delete it anyway. Offering an action that will
        // fail is worse than not offering it.
        #expect(GoogleFileExport.deletionProposal(
            fileID: "abc", title: "Someone else's sheet", reason: "stale",
            createdByUs: false) == nil)
    }

    @Test("an empty file id is refused")
    func refusesEmptyID() {
        #expect(GoogleFileExport.deletionProposal(
            fileID: "", title: "t", reason: "r", createdByUs: true) == nil)
    }

    @Test("a deletion with no reason still gets one")
    func deletionAlwaysCarriesAReason() {
        let proposal = GoogleFileExport.deletionProposal(
            fileID: "abc", title: "t", reason: "   ", createdByUs: true)
        #expect(proposal?.summary.contains("no longer current") == true)
    }

    // MARK: - Finding tables

    @Test("extracts a table from an answer")
    func extractsTable() {
        let tables = GoogleFileExport.tables(in: answer)
        #expect(tables.count == 1)
        #expect(tables.first?.header == ["Owner", "Task", "Due"])
        #expect(tables.first?.rows.count == 3)
        #expect(tables.first?.values.count == 4, "header plus rows")
    }

    @Test("finds several tables in one answer")
    func extractsMultipleTables() {
        let two = answer + "\n\n" + answer
        #expect(GoogleFileExport.tables(in: two).count == 2)
    }

    // MARK: - The refusals

    @Test("ordinary prose containing pipes is not a table", arguments: [
        "The pipeline | the funnel | whatever you call it, it is empty.",
        "Use `a | b` to pipe output.",
        "| this line alone |",
    ])
    func proseIsNotATable(text: String) {
        #expect(GoogleFileExport.tables(in: text).isEmpty)
    }

    @Test("a table with no separator row is not a table")
    func requiresSeparator() {
        let text = """
        | Owner | Task |
        | Maria | Contract |
        | Ana | Backfill |
        """
        #expect(GoogleFileExport.tables(in: text).isEmpty)
    }

    @Test("a one-row table is not worth exporting")
    func ignoresTinyTables() {
        // Usually a formatting artefact. Offering to export it teaches people
        // to dismiss the offer.
        let text = """
        | Key | Value |
        | --- | --- |
        | ARR | 1.2M |
        """
        #expect(GoogleFileExport.tables(in: text).isEmpty)
    }

    @Test("rows of the wrong width stop the table rather than corrupting it")
    func raggedRowsTruncate() {
        let text = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        | 5 | 6 | 7 |
        """
        let table = GoogleFileExport.tables(in: text).first
        #expect(table?.rows.count == 2, "the ragged row is not folded in")
    }

    @Test("an ordinary answer proposes nothing")
    func ordinaryAnswerProposesNothing() {
        // The overwhelmingly common case, and it must stay silent.
        let plain = "Maria will send the contract by Friday, and legal signs it."
        #expect(GoogleFileExport.proposals(forAnswer: plain, title: "Call").isEmpty)
    }

    // MARK: - Proposals

    @Test("a table becomes a create-spreadsheet proposal")
    func tableBecomesProposal() {
        let proposals = GoogleFileExport.proposals(forAnswer: answer, title: "Owners")
        #expect(proposals.count == 1)
        guard case let .createSpreadsheet(title, table) = proposals[0] else {
            Issue.record("expected a spreadsheet proposal"); return
        }
        #expect(title == "Owners")
        #expect(table.rows.count == 3)
    }

    @Test("several tables get distinct names")
    func multipleProposalsAreNamed() {
        let two = answer + "\n\n" + answer
        let titles = GoogleFileExport.proposals(forAnswer: two, title: "Owners").map(\.summary)
        #expect(titles.count == 2)
        #expect(Set(titles).count == 2, "a second file must not collide with the first")
    }

    @Test("the summary says how much data is involved")
    func summaryNamesTheSize() {
        // The user is deciding whether to create a file; three rows and three
        // hundred are different decisions.
        let proposal = GoogleFileExport.proposals(forAnswer: answer, title: "Owners").first
        #expect(proposal?.summary.contains("3 rows") == true)
    }

    // MARK: - Titles

    @Test("characters Drive rejects are stripped", arguments: [
        "Q3/Q4 plan", "budget: final", "notes?", "a\\b", "<draft>",
    ])
    func sanitisesTitles(raw: String) {
        let clean = GoogleFileExport.sanitisedTitle(raw)
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            #expect(!clean.contains(bad), "\(bad) survived in \(clean)")
        }
    }

    @Test("an empty title still names the file")
    func emptyTitleGetsAName() {
        // A 400 from Drive on save reads as the export being broken rather than
        // the title being wrong.
        #expect(GoogleFileExport.sanitisedTitle("   ") == "Выгрузка orakul")
        #expect(GoogleFileExport.sanitisedTitle("///") == "Выгрузка orakul")
    }

    @Test("a very long title is bounded")
    func longTitleIsBounded() {
        #expect(GoogleFileExport.sanitisedTitle(String(repeating: "a", count: 500)).count <= 120)
    }
}
