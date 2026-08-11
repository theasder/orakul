import Foundation

/// Read-only search across Google Docs and Sheets selected in the user's Google
/// grant. Drive supplies only matching file metadata; the existing Docs/Sheets
/// APIs fetch the content. This is the automatic grounding path used by prompt
/// workflows, while pasted URLs continue to use the explicit import path.
///
/// **Currently inert — `isAvailable` is false.** Finding a file by name means
/// Drive `files.list`, which needs `drive.metadata.readonly`, and Google classes
/// that as RESTRICTED: keeping it meant a paid annual CASA Tier 2 assessment
/// before the consent screen could go to production. It was dropped, so this
/// returns nothing rather than 403-ing per call.
///
/// The code stays because the search itself is right and the scope decision is
/// reversible. Two ways back, in cost order: a Google Picker flow, where the
/// user picks documents once and `drive.file` retains access to exactly those —
/// no restricted scope at all — or restoring `drive.metadata.readonly` with CASA
/// attached. Reading a Doc or Sheet the user pastes or imports is unaffected;
/// `documents.readonly` and `spreadsheets.readonly` read BY ID and never search.
enum GoogleWorkspaceSearchService {

    /// Whether searching can work at all with the scopes this app requests.
    ///
    /// Derived from the scope catalog rather than hardcoded, so restoring the
    /// scope re-enables the feature in one edit and cannot leave a stale flag
    /// claiming a capability the token does not have.
    static var isAvailable: Bool {
        GoogleService.requestable
            .flatMap(\.scopeURLs)
            .contains("https://www.googleapis.com/auth/drive.metadata.readonly")
    }

    private struct FileHit: Decodable {
        let id: String
        let name: String
        let mimeType: String
    }

    private struct SearchPayload: Decodable {
        let files: [FileHit]
    }

    static func search(query: String,
                       services: Set<GoogleService>,
                       accessToken: String,
                       maxResults: Int = 3,
                       session: URLSession = .shared) async throws -> [FetchedDocument] {
        // Empty, not an error. A caller asking for grounding it cannot have
        // should get no snippets, the same as a search that matched nothing —
        // an error here would surface mid-call as a failure the user can do
        // nothing about.
        guard isAvailable else { return [] }

        // `requestable` filters out any withdrawn service, so a grant persisted
        // before Drive was withdrawn cannot widen the query past what the
        // current token can actually read.
        let allowed = services
            .intersection([.docs, .sheets, .drive])
            .intersection(Set(GoogleService.requestable))
        guard !allowed.isEmpty else { return [] }

        let terms = searchTerms(query)
        guard !terms.isEmpty else { return [] }

        // Drive is the general case: with `drive.readonly` granted, search is
        // not restricted to the two Google-native mime types, so a PDF spec or
        // a .docx in the same folder becomes reachable. Docs/Sheets stay as the
        // narrow, unrestricted-scope path for anyone who grants only those.
        var mimeClauses: [String] = []
        if !allowed.contains(.drive) {
            if allowed.contains(.docs) {
                mimeClauses.append("mimeType = 'application/vnd.google-apps.document'")
            }
            if allowed.contains(.sheets) {
                mimeClauses.append("mimeType = 'application/vnd.google-apps.spreadsheet'")
            }
        } else {
            // Everything this service can actually extract text from. Folders
            // and media are excluded rather than fetched and discarded.
            mimeClauses = readableMimeTypes.map { "mimeType = '\($0)'" }
        }
        let textClauses = terms.map { "fullText contains '\(escape($0))'" }
        let driveQuery = "trashed = false and (\(mimeClauses.joined(separator: " or "))) and (\(textClauses.joined(separator: " or ")))"

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: driveQuery),
            .init(name: "pageSize", value: String(max(1, min(maxResults, 5)))),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "fields", value: "files(id,name,mimeType)"),
        ]
        guard let url = components.url else { throw LLMError.badResponse("Google Drive") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(
                "Google Drive", http.statusCode,
                String(data: data, encoding: .utf8) ?? "")
        }
        let hits = try JSONDecoder().decode(SearchPayload.self, from: data).files

        var documents: [FetchedDocument] = []
        for hit in hits {
            if hit.mimeType == "application/vnd.google-apps.document",
               let document = try? await GoogleDocsService.read(
                documentID: hit.id, accessToken: accessToken, session: session) {
                documents.append(document)
            } else if hit.mimeType == "application/vnd.google-apps.spreadsheet",
                      let sheet = try? await GoogleSheetsService.read(
                        spreadsheetID: hit.id, accessToken: accessToken, session: session) {
                documents.append(sheet)
            } else if allowed.contains(.drive),
                      let file = try? await downloadPlainText(
                        fileID: hit.id, name: hit.name, mimeType: hit.mimeType,
                        accessToken: accessToken, session: session) {
                documents.append(file)
            }
        }
        return documents
    }

    /// Mime types Drive search will return — everything `downloadPlainText`
    /// below can turn into text, plus the two Google-native ones handled by
    /// their own APIs. Anything else (images, video, archives) is excluded at
    /// query time rather than fetched and thrown away.
    private static let readableMimeTypes = [
        "application/vnd.google-apps.document",
        "application/vnd.google-apps.spreadsheet",
        "application/pdf",
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/rtf",
        "text/html"
    ]

    /// Per-file ceiling. A Drive hit is background material, not the prompt —
    /// one large PDF must not crowd out the transcript it is meant to support.
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let maxExtractedChars = 20_000

    /// Fetch a non-Google-native file and extract text via ContextImporter,
    /// which already knows PDF, DOCX, RTF and plain text. Written to a temp file
    /// because those extractors are URL-based.
    private static func downloadPlainText(fileID: String,
                                          name: String,
                                          mimeType: String,
                                          accessToken: String,
                                          session: URLSession) async throws -> FetchedDocument? {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        guard data.count <= maxFileBytes else { return nil }

        // Keep the extension: ContextImporter dispatches on it.
        let suffix = (name as NSString).pathExtension
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + (suffix.isEmpty ? "" : ".\(suffix)"))
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let imported = try? await ContextImporter.importFile(at: temporary) else { return nil }
        let text = String(imported.text.prefix(maxExtractedChars))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return FetchedDocument(title: name, text: text)
    }

    /// A bounded set of useful tokens keeps Drive search deterministic and
    /// avoids sending the whole transcript/goal as a query expression.
    private static func searchTerms(_ query: String) -> [String] {
        let stop: Set<String> = [
            "about", "after", "before", "from", "have", "into", "meeting",
            "that", "their", "there", "these", "this", "what", "when", "where",
            "which", "with", "would", "your",
        ]
        var seen: Set<String> = []
        return query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
