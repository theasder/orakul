import Foundation

/// Performs a `GoogleFileExport.Proposal` — after a human has confirmed it.
///
/// Runs entirely on **`drive.file`**: access to files this app created or the
/// user explicitly picked. Not sensitive, not restricted, so it adds nothing to
/// the OAuth review. Creating a spreadsheet does not require reach into the
/// user's existing ones, and this type is the proof — every call below either
/// creates a file or addresses one by an id we were given.
///
/// Nothing here decides anything. It is the far side of the confirmation
/// boundary: if it is running, the user already said yes.
enum GoogleDriveWriter {

    /// The only Google scope this needs.
    static let scope = "https://www.googleapis.com/auth/drive.file"

    struct CreatedFile: Equatable {
        let id: String
        let url: String
    }

    enum WriteError: LocalizedError, Equatable {
        case http(Int, String)
        case malformedResponse
        /// A deletion aimed at something we did not create. `drive.file` would
        /// refuse it anyway; failing here makes the reason legible.
        case notOurFile

        var errorDescription: String? {
            switch self {
            case let .http(code, message):
                return "Google returned \(code): \(message)"
            case .malformedResponse:
                return "Google's response could not be read."
            case .notOurFile:
                return "orakul может менять только те файлы, которые сам создал."
            }
        }
    }

    // MARK: - Create

    /// Create a spreadsheet and fill it in one call.
    ///
    /// The Sheets API accepts the whole grid at creation, so this is one
    /// request rather than create-then-append. That matters for a failure the
    /// two-step version has and this one cannot: a created-but-empty file left
    /// behind when the second call fails.
    static func createSpreadsheet(title: String,
                                  table: GoogleFileExport.Table,
                                  accessToken: String,
                                  session: URLSession = .shared) async throws -> CreatedFile {
        let rows = table.values.map { row in
            ["values": row.map { ["userEnteredValue": ["stringValue": $0]] }]
        }
        let body: [String: Any] = [
            "properties": ["title": title],
            "sheets": [["data": [["startRow": 0, "startColumn": 0, "rowData": rows]]]],
        ]
        let json = try await post(
            url: "https://sheets.googleapis.com/v4/spreadsheets",
            body: body, accessToken: accessToken, session: session)

        guard let id = json["spreadsheetId"] as? String else { throw WriteError.malformedResponse }
        let url = json["spreadsheetUrl"] as? String
            ?? "https://docs.google.com/spreadsheets/d/\(id)"
        return CreatedFile(id: id, url: url)
    }

    // MARK: - Delete

    /// Move a file we created to the owner's trash.
    ///
    /// Trash, not `files.delete`. A permanent delete cannot be walked back, and
    /// the user confirmed "remove this", not "destroy this irrecoverably" —
    /// trashing keeps the thirty-day undo Drive already gives them.
    ///
    /// `createdByUs` is passed rather than inferred: this type does not keep a
    /// registry, and guessing would make the guard depend on state that could be
    /// lost.
    static func trashFile(fileID: String,
                          createdByUs: Bool,
                          accessToken: String,
                          session: URLSession = .shared) async throws {
        guard createdByUs, !fileID.isEmpty else { throw WriteError.notOurFile }
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files/\(fileID)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])

        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
    }

    // MARK: - Internals

    private static func post(url: String,
                             body: [String: Any],
                             accessToken: String,
                             session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriteError.malformedResponse
        }
        return json
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            // Google's error body carries the actionable part — a scope problem
            // reads as "insufficient authentication scopes", which is the
            // difference between a bug and a re-consent.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                ?? "request failed"
            throw WriteError.http(http.statusCode, message)
        }
    }
}
