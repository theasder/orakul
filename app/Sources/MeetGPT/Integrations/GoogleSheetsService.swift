import Foundation

/// Reads a Google Sheet's values via the Sheets API (read-only scope).
/// Reads a broad range of the first sheet — enough to fold into context.
enum GoogleSheetsService {
    private static let range = "A1:Z1000"

    static func read(spreadsheetID: String, accessToken: String, session: URLSession = .shared) async throws -> FetchedDocument {
        async let titleTask = fetchTitle(spreadsheetID: spreadsheetID, accessToken: accessToken, session: session)
        async let valuesTask = fetchValues(spreadsheetID: spreadsheetID, accessToken: accessToken, session: session)
        let (title, rows) = try await (titleTask, valuesTask)

        let text = rows
            .map { row in row.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
        return FetchedDocument(title: title, text: text)
    }

    private static func fetchTitle(spreadsheetID: String, accessToken: String, session: URLSession) async throws -> String {
        var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetID)")!
        components.queryItems = [.init(name: "fields", value: "properties.title")]
        guard let url = components.url else { return "Google Sheet" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Google Sheets", http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((root?["properties"] as? [String: Any])?["title"] as? String) ?? "Google Sheet"
    }

    private static func fetchValues(spreadsheetID: String, accessToken: String, session: URLSession) async throws -> [[String]] {
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        guard let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetID)/values/\(encodedRange)") else {
            throw LLMError.badResponse("Google Sheets")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Google Sheets", http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let values = root?["values"] as? [[Any]] ?? []
        return values.map { row in row.map { "\($0)" } }
    }
}
