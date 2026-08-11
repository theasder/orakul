import Foundation

/// Per-team custom vocabulary — product names, acronyms, people, jargon — that
/// biases every transcription engine toward the right spelling of specialized
/// terms. For domain-heavy meetings this is the single biggest fidelity lever.
/// Stored as free text (one term per line, or comma/semicolon separated) and
/// normalized here into the shape each engine wants.
enum Glossary {
    static let maxTerms = 200
    static let maxCharsPerTerm = 80

    /// Clean, order-preserving, case-insensitively-deduped terms.
    static func terms(from raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxCharsPerTerm else { continue }
            if seen.insert(term.lowercased()).inserted { out.append(term) }
            if out.count >= maxTerms { break }
        }
        return out
    }

    /// Comma-joined hint for prompt-style engines (Whisper API `prompt`,
    /// WhisperKit prompt tokens). Empty when there are no terms.
    static func promptHint(from raw: String) -> String {
        let t = terms(from: raw)
        return t.isEmpty ? "" : t.joined(separator: ", ")
    }
}
