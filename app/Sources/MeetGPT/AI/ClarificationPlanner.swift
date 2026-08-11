import Foundation

/// Tier 0 of the clarification pipeline: ambiguity that is a COUNT, not a
/// judgement, and therefore needs no model call at all.
///
/// "Summarize the doc" with four documents attached is not a hard question about
/// intent — it is a set with four elements and a prompt that selects none of
/// them. Detecting that costs nothing, runs instantly, and the options it offers
/// are the real filenames rather than something a model invented. Only what this
/// tier cannot decide is escalated to `ClarificationService` (tier 2), which
/// gets the routed skill and the grounding snippets to work with.
///
/// Pure and synchronous by construction so the rules are testable without an
/// AppState, an MCP connection or a network.
enum ClarificationPlanner {

    /// Everything tier 0 is allowed to count. Deliberately plain arrays rather
    /// than app types — the planner must stay testable in isolation.
    struct Candidates: Equatable {
        var documents: [String]
        var trackers: [String]

        init(documents: [String] = [], trackers: [String] = []) {
            self.documents = documents
            self.trackers = trackers
        }

        var isEmpty: Bool { documents.isEmpty && trackers.isEmpty }
    }

    /// Words that point at a document without naming one.
    private static let documentReferents = [
        "the doc", "the document", "the file", "the attachment", "the spec",
        "the paper", "the deck", "the notes", "the brief", "the prd", "the contract"
    ]

    /// Phrases that mean "write this into a tracker" without naming which.
    private static let trackerReferents = [
        "file it", "file them", "file this", "create the task", "create tasks",
        "create a ticket", "create tickets", "the tracker", "the board",
        "into the tracker", "as tickets", "as issues", "open a ticket"
    ]

    /// Below this there is nothing to disambiguate — one candidate IS the answer.
    private static let minimumAmbiguousCount = 2

    /// Returns the questions tier 0 can answer for itself. An empty result means
    /// "nothing countable was ambiguous", which is the common case and the
    /// signal for the caller to consider tier 2.
    static func plan(prompt: String, candidates: Candidates) -> [ClarifyingQuestion] {
        let haystack = prompt.lowercased()
        var questions: [ClarifyingQuestion] = []

        if let question = ambiguity(
            haystack: haystack,
            candidates: candidates.documents,
            referents: documentReferents,
            header: "Document",
            question: "Which document do you mean?"
        ) {
            questions.append(question)
        }

        if let question = ambiguity(
            haystack: haystack,
            candidates: candidates.trackers,
            referents: trackerReferents,
            header: "Tracker",
            question: "Which tracker should this go to?"
        ) {
            questions.append(question)
        }

        return Array(questions.prefix(ClarifyingQuestion.maxQuestions))
    }

    // MARK: - Detection

    /// One class of referent. Asks only when the prompt points at the class,
    /// several candidates exist, and the prompt names none of them.
    private static func ambiguity(haystack: String,
                                  candidates: [String],
                                  referents: [String],
                                  header: String,
                                  question: String) -> ClarifyingQuestion? {
        let named = candidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard named.count >= minimumAmbiguousCount else { return nil }
        guard referents.contains(where: { haystack.contains($0) }) else { return nil }
        // The user already picked one in the prompt — answering is not ambiguous,
        // and asking anyway is exactly the noise that trains people to dismiss
        // the card without reading it.
        guard !mentionsAnyCandidate(haystack: haystack, candidates: named) else { return nil }

        let options = named
            .prefix(ClarifyingQuestion.maxOptions)
            .map { ClarifyingQuestion.Option(label: $0) }
        return ClarifyingQuestion(
            question: question,
            header: header,
            options: Array(options),
            multiSelect: false
        )
    }

    /// True when the prompt already refers to one of the candidates. Matching is
    /// done on the significant words of a candidate rather than the whole string,
    /// because a filename ("Q4 pricing memo.pdf") is almost never quoted whole.
    private static func mentionsAnyCandidate(haystack: String, candidates: [String]) -> Bool {
        candidates.contains { candidate in
            let tokens = significantTokens(of: candidate)
            guard !tokens.isEmpty else { return false }
            return tokens.contains { haystack.contains($0) }
        }
    }

    /// Lowercased words of 4+ characters, minus the file extension. Short tokens
    /// ("q4", "the", "v2") match far too eagerly to be evidence of intent.
    private static func significantTokens(of candidate: String) -> [String] {
        let base = (candidate as NSString).deletingPathExtension.lowercased()
        return base
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
    }
}
