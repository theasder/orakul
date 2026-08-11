import Foundation

/// A read request the model makes mid-answer, expressed in text.
///
/// **Why a text protocol rather than provider-native tool calling.** The app
/// reaches twelve models across seven providers, and their tool-calling schemas
/// and streaming shapes all differ. A native implementation is seven
/// integrations, seven sets of edge cases, and no capability at all on the
/// models that do not support tools. One text protocol works everywhere and
/// degrades honestly: a model that ignores it simply answers without reading,
/// which is exactly today's behaviour.
///
/// The trade is that a text protocol is less reliable than a native one — a
/// model can emit a malformed request, or mention the syntax while discussing
/// it. Both are handled by refusing to parse rather than guessing, because a
/// misparsed request is a call nobody asked for.
///
/// The line must be alone on its own line. That single rule removes the failure
/// that would otherwise dominate: a model writing *about* the protocol inside a
/// sentence, which is common in a product whose users discuss prompts as work.
enum AgenticToolRequest: Equatable {

    /// `⟦read: server/tool query⟧`
    ///
    /// Bracket characters no ordinary transcript or answer contains, so the
    /// marker cannot collide with meeting speech, code, or markdown.
    static let opening = "⟦read:"
    static let closing = "⟧"

    struct Parsed: Equatable {
        let server: String
        let tool: String
        let query: String
    }

    /// The instruction handed to the model. Kept beside the parser so the two
    /// cannot describe different syntaxes.
    static let instruction = """
        If answering needs something from a connected app, emit exactly one line \
        containing only:
        \(opening) server/tool your query \(closing)
        Then stop and wait. Do not explain that you are doing it, do not put the \
        line inside a sentence, and do not use it for anything that would change \
        data — those are staged for the user to confirm separately.
        """

    /// Find a request in a completed answer chunk.
    ///
    /// Returns nil when there is none, which is the overwhelmingly common case
    /// and must stay cheap.
    static func parse(_ text: String) -> Parsed? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Alone on its line, or it is prose ABOUT the protocol rather than
            // a use of it.
            guard line.hasPrefix(opening), line.hasSuffix(closing) else { continue }
            let body = line
                .dropFirst(opening.count)
                .dropLast(closing.count)
                .trimmingCharacters(in: .whitespaces)
            guard let slash = body.firstIndex(of: "/") else { continue }

            let server = String(body[body.startIndex..<slash])
                .trimmingCharacters(in: .whitespaces)
            let rest = String(body[body.index(after: slash)...])
                .trimmingCharacters(in: .whitespaces)
            guard let space = rest.firstIndex(of: " ") else {
                // A tool with no query is still a valid request — "list my open
                // issues" needs no argument.
                guard !server.isEmpty, !rest.isEmpty else { continue }
                return Parsed(server: server, tool: rest, query: "")
            }
            let tool = String(rest[rest.startIndex..<space])
            let query = String(rest[rest.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
            guard !server.isEmpty, !tool.isEmpty else { continue }
            return Parsed(server: server, tool: tool, query: query)
        }
        return nil
    }

    /// Remove the request line from what the user sees.
    ///
    /// The protocol is machinery, not content. Leaving it in the answer would
    /// show the user a line of syntax where a sentence should be.
    static func stripped(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix(opening) && trimmed.hasSuffix(closing))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The result handed back for the model's next turn.
    ///
    /// Labelled as tool output rather than pasted in as if the model had known
    /// it: an answer that cannot tell its own knowledge from a lookup cannot
    /// attribute it either, and attribution is an acceptance criterion.
    static func resultBlock(server: String, tool: String, result: String) -> String {
        let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "Result of \(server)/\(tool): nothing found. Answer without it, "
                + "and say that you looked."
        }
        return "Result of \(server)/\(tool):\n\(body)"
    }
}
