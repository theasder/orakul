import Foundation

/// Reads one explicitly pasted Google Form and a bounded page of its responses.
/// It does not discover forms or download uploaded files. File-upload answers
/// contribute file names only, which keeps this connector inside its two Forms
/// read-only scopes rather than expanding into Drive.
enum GoogleFormsService {
    static let defaultResponseLimit = 100
    static let maximumResponseLimit = 500
    static let maxTextCharacters = 80_000

    private struct Question {
        let id: String
        let title: String
    }

    static func read(formID: String, accessToken: String,
                     maxResponses: Int = defaultResponseLimit,
                     session: URLSession = .shared) async throws -> FetchedDocument {
        let form = try await get(
            "https://forms.googleapis.com/v1/forms/\(formID)",
            accessToken: accessToken, session: session)
        guard form["formId"] is String,
              let info = form["info"] as? [String: Any] else {
            throw LLMError.badResponse("Google Forms")
        }
        let title = (info["title"] as? String)
            ?? (info["documentTitle"] as? String)
            ?? "Google Form"
        let description = info["description"] as? String
        let questions = extractQuestions(from: form)
        let limit = boundedResponseLimit(maxResponses)
        let responses: [[String: Any]]
        if limit == 0 {
            responses = []
        } else {
            responses = try await listResponses(
                formID: formID, accessToken: accessToken, limit: limit, session: session)
        }

        var sections: [String] = []
        if let description, !description.isEmpty { sections.append(description) }
        if !questions.isEmpty {
            sections.append("Вопросы:\n" + questions.enumerated().map {
                "\($0.offset + 1). \($0.element.title)"
            }.joined(separator: "\n"))
        }
        sections.append(renderResponses(responses, questions: questions))
        let text = sections.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FetchedDocument(title: title, text: String(text.prefix(maxTextCharacters)))
    }

    static func boundedResponseLimit(_ requested: Int) -> Int {
        max(0, min(requested, maximumResponseLimit))
    }

    private static func listResponses(
        formID: String, accessToken: String, limit: Int, session: URLSession
    ) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        var pageToken: String?
        var seenTokens: Set<String> = []

        while collected.count < limit {
            var components = URLComponents(
                string: "https://forms.googleapis.com/v1/forms/\(formID)/responses")!
            var query = [URLQueryItem(
                name: "pageSize", value: String(min(100, limit - collected.count)))]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            guard let url = components.url else { throw LLMError.badResponse("Google Forms") }
            let page = try await get(
                url.absoluteString, accessToken: accessToken, session: session)
            // Protobuf JSON may omit an empty repeated field, but a present field
            // with the wrong shape is a malformed success envelope, not an empty
            // form. Treating it as [] would silently hide provider/schema errors.
            let responses: [[String: Any]]
            if let rawResponses = page["responses"] {
                guard let typed = rawResponses as? [[String: Any]] else {
                    throw LLMError.badResponse("Google Forms")
                }
                responses = typed
            } else {
                responses = []
            }
            collected.append(contentsOf: responses.prefix(limit - collected.count))

            let next: String?
            if let rawNext = page["nextPageToken"] {
                guard let typed = rawNext as? String else {
                    throw LLMError.badResponse("Google Forms")
                }
                next = typed
            } else {
                next = nil
            }
            // The API contract says a nextPageToken means more responses. An
            // intermediate page is allowed to be shorter than requested, so do
            // not turn an empty page into an early EOF; token reuse still bounds
            // a broken provider and prevents a loop.
            guard let next, !next.isEmpty, !seenTokens.contains(next) else { break }
            seenTokens.insert(next)
            pageToken = next
        }
        return collected
    }

    private static func get(_ address: String, accessToken: String,
                            session: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw LLMError.badResponse("Google Forms") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(
                "Google Forms", http.statusCode,
                String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse("Google Forms")
        }
        return root
    }

    private static func extractQuestions(from form: [String: Any]) -> [Question] {
        let items = form["items"] as? [[String: Any]] ?? []
        var questions: [Question] = []
        for item in items {
            let itemTitle = (item["title"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let questionItem = item["questionItem"] as? [String: Any],
               let question = questionItem["question"] as? [String: Any],
               let id = question["questionId"] as? String {
                questions.append(Question(
                    id: id, title: itemTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Вопрос"))
            }
            if let group = item["questionGroupItem"] as? [String: Any],
               let rows = group["questions"] as? [[String: Any]] {
                for (offset, row) in rows.enumerated() {
                    guard let id = row["questionId"] as? String else { continue }
                    let rowTitle = ((row["rowQuestion"] as? [String: Any])?["title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = itemTitle.map { "\($0) — строка \(offset + 1)" }
                        ?? "Вопрос \(offset + 1)"
                    questions.append(Question(
                        id: id, title: rowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallback))
                }
            }
        }
        return questions
    }

    private static func renderResponses(
        _ responses: [[String: Any]], questions: [Question]
    ) -> String {
        guard !responses.isEmpty else { return "Ответы: нет доступных ответов." }
        let knownIDs = Set(questions.map(\.id))
        var blocks: [String] = ["Ответы (загружено: \(responses.count)):" ]

        for (offset, response) in responses.enumerated() {
            var header = "Ответ \(offset + 1)"
            if let submitted = (response["lastSubmittedTime"] as? String)
                ?? (response["createTime"] as? String) {
                header += " · \(submitted)"
            }
            // respondentEmail is provider metadata, not an answer the user
            // chose to attach. Omit it by default before this text enters model
            // context; an email explicitly supplied as a form answer is still
            // rendered under that question's visible label.
            let answers = response["answers"] as? [String: Any] ?? [:]
            var lines: [String] = [header]
            for question in questions {
                guard let answer = answers[question.id] as? [String: Any],
                      let value = answerText(answer), !value.isEmpty else { continue }
                lines.append("\(question.title): \(value)")
            }
            for id in answers.keys.sorted() where !knownIDs.contains(id) {
                guard let answer = answers[id] as? [String: Any],
                      let value = answerText(answer), !value.isEmpty else { continue }
                lines.append("Вопрос: \(value)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func answerText(_ answer: [String: Any]) -> String? {
        if let textAnswers = answer["textAnswers"] as? [String: Any],
           let values = textAnswers["answers"] as? [[String: Any]] {
            let text = values.compactMap { $0["value"] as? String }
                .map { $0.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " | ")
            if !text.isEmpty { return text }
        }
        if let files = (answer["fileUploadAnswers"] as? [String: Any])?["answers"]
            as? [[String: Any]] {
            let names = files.compactMap { $0["fileName"] as? String }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return nil
    }
}
