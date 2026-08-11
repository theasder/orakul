import Foundation

/// Reads a Google Doc's text via the Docs API (read-only scope).
enum GoogleDocsService {
    static func read(documentID: String, accessToken: String, session: URLSession = .shared) async throws -> FetchedDocument {
        guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentID)") else {
            throw LLMError.badResponse("Google Docs")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Google Docs", http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try parse(data)
    }

    private static func parse(_ data: Data) throws -> FetchedDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse("Google Docs")
        }
        let title = (root["title"] as? String) ?? "Google Doc"
        let content = (root["body"] as? [String: Any])?["content"] as? [[String: Any]] ?? []

        var text = ""
        for element in content {
            guard let paragraph = element["paragraph"] as? [String: Any],
                  let elements = paragraph["elements"] as? [[String: Any]] else { continue }
            for run in elements {
                if let textRun = run["textRun"] as? [String: Any],
                   let str = textRun["content"] as? String {
                    text += str
                }
            }
        }
        return FetchedDocument(title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
