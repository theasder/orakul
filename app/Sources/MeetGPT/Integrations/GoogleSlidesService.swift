import Foundation

/// Reads one presentation the user identified explicitly. This service never
/// lists Drive files; `presentations.readonly` is sufficient for the pasted ID.
enum GoogleSlidesService {
    static let maxTextCharacters = 80_000

    static func read(presentationID: String, accessToken: String,
                     session: URLSession = .shared) async throws -> FetchedDocument {
        guard let url = URL(string: "https://slides.googleapis.com/v1/presentations/\(presentationID)") else {
            throw LLMError.badResponse("Google Slides")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(
                "Google Slides", http.statusCode,
                String(data: data, encoding: .utf8) ?? "")
        }
        return try parse(data)
    }

    private static func parse(_ data: Data) throws -> FetchedDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse("Google Slides")
        }
        guard root["presentationId"] is String else {
            throw LLMError.badResponse("Google Slides")
        }
        let title = (root["title"] as? String) ?? "Google Slides"
        let slides = root["slides"] as? [[String: Any]] ?? []
        var sections: [String] = []

        for (offset, slide) in slides.enumerated() {
            let visible = text(from: slide["pageElements"] as? [[String: Any]] ?? [])
            let notesPage = (slide["slideProperties"] as? [String: Any])?["notesPage"] as? [String: Any]
            let notes = speakerNotes(
                from: notesPage?["pageElements"] as? [[String: Any]] ?? [])

            var parts = ["Слайд \(offset + 1)"]
            if !visible.isEmpty { parts.append(visible) }
            if !notes.isEmpty { parts.append("Заметки докладчика:\n\(notes)") }
            // Preserve slide boundaries even for image-only slides so the next
            // slide's words are never silently joined to the previous one.
            sections.append(parts.joined(separator: "\n"))
        }

        let combined = sections.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FetchedDocument(
            title: title,
            text: String(combined.prefix(maxTextCharacters)))
    }

    private static func text(from elements: [[String: Any]]) -> String {
        let lines = elements.flatMap(elementText)
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func elementText(_ element: [String: Any]) -> [String] {
        if let group = element["elementGroup"] as? [String: Any],
           let children = group["children"] as? [[String: Any]] {
            return children.flatMap(elementText)
        }

        if let shape = element["shape"] as? [String: Any] {
            if let text = shape["text"] as? [String: Any] {
                return textRuns(in: text)
            }
        }

        if let table = element["table"] as? [String: Any],
           let rows = table["tableRows"] as? [[String: Any]] {
            return rows.compactMap { row in
                let cells = row["tableCells"] as? [[String: Any]] ?? []
                let values = cells.map { cell -> String in
                    guard let text = cell["text"] as? [String: Any] else { return "" }
                    return textRuns(in: text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let line = values.joined(separator: "\t")
                return line.isEmpty ? nil : line
            }
        }
        if let wordArt = element["wordArt"] as? [String: Any],
           let rendered = wordArt["renderedText"] as? String {
            return [rendered]
        }
        return []
    }

    /// Google documents the first BODY placeholder on a notes page as the
    /// speaker-notes shape. Reading every notes-page shape would also import
    /// inherited dates, footers and slide-number placeholders.
    private static func speakerNotes(from elements: [[String: Any]]) -> String {
        func runs(_ element: [String: Any]) -> [String] {
            if let group = element["elementGroup"] as? [String: Any],
               let children = group["children"] as? [[String: Any]] {
                return children.flatMap(runs)
            }
            guard let shape = element["shape"] as? [String: Any],
                  let placeholder = shape["placeholder"] as? [String: Any],
                  (placeholder["type"] as? String) == "BODY",
                  let text = shape["text"] as? [String: Any] else { return [] }
            return textRuns(in: text)
        }
        return elements.flatMap(runs)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func textRuns(in text: [String: Any]) -> [String] {
        let elements = text["textElements"] as? [[String: Any]] ?? []
        return elements.compactMap { element in
            (element["textRun"] as? [String: Any])?["content"] as? String
        }
    }
}
