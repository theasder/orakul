import Foundation

/// Creates a NEW Google Doc from the app via the Drive API multipart upload:
/// part 1 is the file metadata (name + the Google-Doc mime type), part 2 is
/// HTML which Google converts into a formatted Doc (headings, bold, bullets).
/// Uses `drive.file` scope — the app only ever touches files it creates.
enum GoogleDocsWriter {
    struct CreatedDoc {
        let id: String
        let webViewLink: String
    }

    private static let boundary = "cruxwing-doc-boundary-8f3a1c"

    static func create(title: String,
                       html: String,
                       accessToken: String,
                       session: URLSession = .shared) async throws -> CreatedDoc {
        guard let url = URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")
        else { throw LLMError.badResponse("Google Docs") }

        let metadata: [String: Any] = [
            "name": title,
            "mimeType": "application/vnd.google-apps.document",  // convert HTML → Doc
        ]
        let metaJSON = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metaJSON)
        append("\r\n--\(boundary)\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n")
        append(html)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Google Docs", http.statusCode,
                                String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String else {
            throw LLMError.badResponse("Google Docs")
        }
        let link = (root["webViewLink"] as? String)
            ?? "https://docs.google.com/document/d/\(id)/edit"
        return CreatedDoc(id: id, webViewLink: link)
    }
}

/// Builds the HTML body Google converts into a formatted Doc. Escapes all
/// dynamic text, renders the assistant answer's light markdown (headings,
/// bullets, bold), and appends a blind-spots list. Pure + testable.
enum AssistantDocHTML {
    static func build(title: String,
                      date: Date,
                      prompt: String,
                      answer: String,
                      blindSpots: [String],
                      earlierExchanges: [AIExchange] = []) -> String {
        let df = DateFormatter()
        df.locale = DisplayFormatting.locale
        df.dateFormat = "d MMMM yyyy"

        var html = "<h1>\(esc(title))</h1>"
        html += "<p><i>orakul · \(esc(df.string(from: date)))</i></p>"

        // The archived dialog before the live turn, oldest first — the doc is
        // titled "Assistant chat" and must contain the chat.
        for exchange in earlierExchanges {
            let earlierPrompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !earlierPrompt.isEmpty {
                html += "<h2>Prompt</h2><p>\(esc(earlierPrompt))</p>"
            }
            html += "<h2>Answer</h2>" + markdownToHTML(exchange.answer)
        }

        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPrompt.isEmpty, cleanPrompt != "Prompt unavailable for this older saved answer." {
            html += "<h2>Prompt</h2><p>\(esc(cleanPrompt))</p>"
        }

        html += "<h2>Assistant answer</h2>" + markdownToHTML(answer)

        if !blindSpots.isEmpty {
            html += "<h2>Blind spots</h2><ul>"
            for spot in blindSpots { html += "<li>\(inline(spot))</li>" }
            html += "</ul>"
        }
        return "<html><body>\(html)</body></html>"
    }

    /// Minimal, safe markdown → HTML for the answer: ## headings, - / * bullets,
    /// **bold**, blank-line paragraphs. Everything is escaped first.
    static func markdownToHTML(_ markdown: String) -> String {
        var out = ""
        var inList = false
        func closeList() { if inList { out += "</ul>"; inList = false } }

        for rawLine in markdown.replacingOccurrences(of: "\r", with: "").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }
            if line.hasPrefix("### ") {
                closeList(); out += "<h4>\(inline(String(line.dropFirst(4))))</h4>"
            } else if line.hasPrefix("## ") {
                closeList(); out += "<h3>\(inline(String(line.dropFirst(3))))</h3>"
            } else if line.hasPrefix("# ") {
                closeList(); out += "<h3>\(inline(String(line.dropFirst(2))))</h3>"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if !inList { out += "<ul>"; inList = true }
                out += "<li>\(inline(String(line.dropFirst(2))))</li>"
            } else {
                closeList(); out += "<p>\(inline(line))</p>"
            }
        }
        closeList()
        return out.isEmpty ? "<p></p>" : out
    }

    /// Escape, then render **bold** and `code` spans.
    private static func inline(_ text: String) -> String {
        var s = esc(text)
        s = replacePairs(in: s, marker: "**", open: "<b>", close: "</b>")
        s = replacePairs(in: s, marker: "`", open: "<code>", close: "</code>")
        return s
    }

    private static func replacePairs(in text: String, marker: String,
                                     open: String, close: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        var result = ""
        for (i, part) in parts.enumerated() {
            if i == 0 { result += part; continue }
            // Odd boundaries open, even close — a trailing unmatched marker is
            // re-emitted literally.
            result += (i % 2 == 1)
                ? (i == parts.count - 1 ? marker + part : open + part)
                : close + part
        }
        return result
    }

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
