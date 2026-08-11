import Foundation

/// Refine an answer that is already on screen — backlog item 20.
///
/// Fireflies puts Condense / Elaborate above a delivered summary. We rejected a
/// rewrite pass for answer STYLES (item 7) because a second automatic pass
/// doubles cost on every answer and cannot be trusted to preserve a required
/// structure. A USER-invoked refine is a different trade: they asked, they pay,
/// and both versions stay reachable, so a refine that makes it worse is undoable.
///
/// Two rules are enforced here, in pure code so they are testable without a
/// model:
/// - **Structured answers refuse.** A fact check, a DACI, an agenda has a
///   contract a free rewrite would break, and the acceptance says refusing is
///   fine. `canRefine(promptID:)` is the gate; the caller shows no refine
///   controls when it returns false.
/// - **Refine is a transform of the ANSWER, not a re-run of the prompt.** The
///   system prompt tells the model to reshape the given text and change nothing
///   it asserts, so "condense" cannot quietly drop a fact or invent one.
enum AnswerRefine {

    enum Kind: String, CaseIterable, Identifiable {
        case condense
        case elaborate
        var id: String { rawValue }

        var label: String {
            switch self {
            case .condense: return "Condense"
            case .elaborate: return "Elaborate"
            }
        }

        var systemImage: String {
            switch self {
            case .condense: return "arrow.down.right.and.arrow.up.left"
            case .elaborate: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }

    /// Prompt ids whose answer carries a structure a free rewrite would break.
    /// A refine over one of these is refused, not attempted — the same discipline
    /// item 7 (answer styles) established for the automatic pass.
    static let structuredPromptIDs: Set<String> = [
        "logdecision", "factcheck", "agenda", "tasks", "commitments", "dispute",
    ]

    /// Whether the answer from this prompt may be refined. Prose may; a
    /// contract-bearing answer may not.
    static func canRefine(promptID: String?) -> Bool {
        guard let promptID, !promptID.isEmpty else { return true }  // ad-hoc prose
        return !structuredPromptIDs.contains(promptID.lowercased())
    }

    /// The refine instruction. Reshapes the delivered answer; never adds or drops
    /// a claim, because a refine the user cannot trust is worse than no refine.
    static func systemPrompt(for kind: Kind) -> String {
        let base = """
        You refine an answer a meeting co-pilot already produced. You are reshaping \
        the SAME content, not answering again: keep every fact, number, name and \
        recommendation exactly as given — add nothing not present, drop nothing that \
        changes the meaning. Match the language of the answer.
        """
        switch kind {
        case .condense:
            return base + """
             Make it SHORTER and tighter: cut hedging, merge overlapping points, \
            keep the structure legible. No new information.
            """
        case .elaborate:
            return base + """
             Make it fuller: expand each point with the reasoning and the concrete \
            implication already implied by the answer, without introducing facts the \
            answer does not contain. If a point cannot be expanded from what is there, \
            leave it.
            """
        }
    }

    /// The user message: the answer to reshape.
    static func userPrompt(answer: String) -> String {
        "Answer to refine:\n\(answer)"
    }
}
