import Foundation

/// Which suggested terms may enter the recognizer's vocabulary in one batch.
///
/// Connecting an app is the moment the names about to be spoken become
/// knowable — the tickets, the project, the people. The suggestion pass already
/// finds them; this decides which are safe to hand over together, whether the
/// user reviews the batch first or not.
///
/// The filters exist because a glossary term is not inert. It BIASES
/// recognition: a wrong or absurd term does not sit unused, it pulls real words
/// toward itself. So a batch is bounded, junk is dropped, and a term the user
/// has already rejected is never proposed again — sparing someone a decision
/// they have not made is the point; overturning one they have is not.
enum GlossaryAutoApply {
    /// Shortest useful term. A single character biases everything toward itself.
    static let minimumTermLength = 2
    /// Longest. Past this it is a sentence that failed to parse, not a name.
    static let maximumTermLength = 60
    /// One connection may not flood the vocabulary. A recognizer prompt is
    /// finite: past some size the glossary stops helping and starts crowding
    /// out what was actually said.
    static let maximumTermsPerConnection = 25

    /// Terms from this batch that should be added, in the order suggested.
    static func termsToAdd(suggestions: [ConnectedGlossarySuggestion],
                           existing: String,
                           rejectedKeys: Set<String>) -> [String] {
        let known = Set(Glossary.terms(from: existing)
            .map { ConnectedGlossarySuggestionService.canonicalKey($0) })
        var seen = Set<String>()
        var accepted: [String] = []

        for suggestion in suggestions {
            let term = suggestion.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleTerm(term) else { continue }
            let key = ConnectedGlossarySuggestionService.canonicalKey(term)
            guard !key.isEmpty, !known.contains(key), !rejectedKeys.contains(key),
                  seen.insert(key).inserted else { continue }
            accepted.append(term)
            if accepted.count == maximumTermsPerConnection { break }
        }
        return accepted
    }

    /// The glossary with these terms appended, in the format the existing parser
    /// reads back.
    static func merge(existing: String, adding terms: [String]) -> String {
        guard !terms.isEmpty else { return existing }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = trimmed.isEmpty ? "" : ", "
        return trimmed + separator + terms.joined(separator: ", ")
    }

    private static func isPlausibleTerm(_ term: String) -> Bool {
        guard term.count >= minimumTermLength, term.count <= maximumTermLength else {
            return false
        }
        // A term is a name or a piece of jargon, not a clause.
        return term.split(whereSeparator: \.isWhitespace).count <= 5
    }
}
