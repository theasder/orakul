import Foundation

/// Turning an answer into a Google file — a spreadsheet from a table, a doc
/// from a write-up — and proposing changes to files we made earlier.
///
/// **Scope discipline is the design.** Everything here runs on `drive.file`,
/// which grants access ONLY to files this app created or the user explicitly
/// picked. It is neither sensitive nor restricted, so it costs no security
/// assessment and no verification delay.
///
/// The broad alternative, `.../auth/spreadsheets`, reads "see, edit, create and
/// DELETE ALL your Google Sheets" — every sheet the user has ever owned,
/// including ones we did not make. Creating a new spreadsheet needs none of
/// that, so asking for it would buy nothing and cost the review.
///
/// **Nothing here writes.** Every function returns a PROPOSAL. Execution goes
/// through the existing confirmation boundary (`AnswerActionDispatch`), which is
/// the same rule the connected-app writes already follow.
///
/// Deletion is the sharpest case and gets two guards rather than one: it is
/// never generated automatically from an answer, and it can only ever target a
/// file this app created. A model deciding a spreadsheet is stale is a
/// suggestion, not a warrant — the data is the user's and the action is
/// irreversible.
enum GoogleFileExport {

    /// A table lifted out of a markdown answer.
    struct Table: Equatable {
        let header: [String]
        let rows: [[String]]

        /// Sheets wants a rectangular values array.
        var values: [[String]] { [header] + rows }
        var columnCount: Int { header.count }
    }

    /// What the user is offered. Never performed by this type.
    enum Proposal: Equatable {
        /// A new spreadsheet from a table in the answer.
        case createSpreadsheet(title: String, table: Table)
        /// A new document from the answer's prose.
        case createDocument(title: String, body: String)
        /// Replace the contents of a spreadsheet WE created.
        case updateSpreadsheet(fileID: String, title: String, table: Table)
        /// Remove a file WE created. Only ever raised by an explicit user
        /// request or an explicit staleness review — never inferred from an
        /// answer, and never executed without confirmation.
        case deleteFile(fileID: String, title: String, reason: String)

        /// Always true. Present as a property rather than a convention so a
        /// caller cannot forget, and so a test can assert it for every case.
        var requiresConfirmation: Bool { true }

        /// What the confirmation sheet says. Deletion states what is lost and
        /// why it was suggested, because "delete this?" with no reason is a
        /// question nobody can answer well.
        var summary: String {
            switch self {
            case let .createSpreadsheet(title, table):
                return "Create a spreadsheet “\(title)” with \(table.rows.count) rows"
            case let .createDocument(title, _):
                return "Create a document “\(title)”"
            case let .updateSpreadsheet(_, title, table):
                return "Replace the contents of “\(title)” with \(table.rows.count) rows"
            case let .deleteFile(_, title, reason):
                return "Delete “\(title)” — \(reason). This cannot be undone."
            }
        }
    }

    /// Smallest table worth exporting. A two-column, one-row "table" is usually
    /// a formatting artefact, and offering to export it trains people to ignore
    /// the offer.
    static let minimumRows = 2

    // MARK: - Reading tables out of an answer

    /// Extract markdown tables from an answer.
    ///
    /// Deliberately strict: a header row, a separator row of dashes, then body
    /// rows of the same width. Anything looser matches prose containing pipes —
    /// and a spurious export offer on every answer is worse than missing one.
    static func tables(in answer: String) -> [Table] {
        var found: [Table] = []
        let lines = answer.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            guard let header = cells(in: lines[index]),
                  index + 1 < lines.count,
                  isSeparator(lines[index + 1], columns: header.count) else {
                index += 1
                continue
            }
            var rows: [[String]] = []
            var cursor = index + 2
            while cursor < lines.count, let row = cells(in: lines[cursor]),
                  row.count == header.count {
                rows.append(row)
                cursor += 1
            }
            if rows.count >= minimumRows {
                found.append(Table(header: header, rows: rows))
            }
            index = cursor
        }
        return found
    }

    private static func cells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 2 else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        let parts = inner.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return parts
    }

    private static func isSeparator(_ line: String, columns: Int) -> Bool {
        guard let parts = cells(in: line), parts.count == columns else { return false }
        // Each cell is dashes, optionally with alignment colons.
        return parts.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
                && cell.contains("-")
        }
    }

    // MARK: - Proposals

    /// What this answer could become. Never includes a deletion: an answer is
    /// not evidence that an existing file should be destroyed.
    static func proposals(forAnswer answer: String, title: String) -> [Proposal] {
        tables(in: answer).enumerated().map { index, table in
            let name = index == 0 ? title : "\(title) (\(index + 1))"
            return .createSpreadsheet(title: sanitisedTitle(name), table: table)
        }
    }

    /// A deletion proposal, which a caller must ask for explicitly.
    ///
    /// Returns nil for a file this app did not create — `drive.file` could not
    /// delete it anyway, and offering an action that will fail is worse than
    /// not offering it.
    static func deletionProposal(fileID: String,
                                 title: String,
                                 reason: String,
                                 createdByUs: Bool) -> Proposal? {
        guard createdByUs, !fileID.isEmpty else { return nil }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return .deleteFile(fileID: fileID, title: title,
                           reason: why.isEmpty ? "no longer current" : why)
    }

    /// Drive rejects these in a file name, and a 400 on save reads to the user
    /// as the export being broken rather than the title being wrong.
    static func sanitisedTitle(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(of: "  ", with: " ")
        if collapsed.isEmpty { return "Выгрузка orakul" }
        return String(collapsed.prefix(120))
    }
}
