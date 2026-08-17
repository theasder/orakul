import Foundation

/// A document fetched from an external source, ready to fold into context.
struct FetchedDocument {
    let title: String
    let text: String
}

/// Extracts document IDs from pasted URLs (or accepts a bare ID). Keeps the
/// connector services free of URL-parsing concerns.
enum SourceURL {
    /// Google Docs: …/document/d/<ID>/edit
    static func googleDocID(from input: String) -> String? {
        firstMatch(in: input, pattern: #"/document/d/([a-zA-Z0-9_-]+)"#) ?? bareID(input)
    }

    /// Google Sheets: …/spreadsheets/d/<ID>/edit
    static func googleSheetID(from input: String) -> String? {
        firstMatch(in: input, pattern: #"/spreadsheets/d/([a-zA-Z0-9_-]+)"#) ?? bareID(input)
    }

    /// Google Slides: …/presentation/d/<ID>/edit
    static func googleSlidesID(from input: String) -> String? {
        firstMatch(in: input, pattern: #"/presentation/(?:u/\d+/)?d/([a-zA-Z0-9_-]+)"#)
            ?? bareID(input)
    }

    /// Google Forms editor/share links: …/forms/d/<FORM_ID>/edit. Published
    /// responder links use `/d/e/<published-id>`; that id is deliberately not
    /// accepted because the Forms API requires the private form id.
    static func googleFormID(from input: String) -> String? {
        firstMatch(
            in: input,
            pattern: #"/forms/(?:u/\d+/)?d/(?!e/)([a-zA-Z0-9_-]+)(?:/|$)"#)
            ?? bareID(input)
    }

    // Notion links go straight to the notion-fetch MCP tool (it accepts the
    // raw URL), so no Notion ID parsing lives here anymore.

    // MARK: Helpers

    private static func bareID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("/"), !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return trimmed
    }

    private static func firstMatch(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }
}
