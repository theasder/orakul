import Foundation

/// How an answer should READ. Not what it should contain.
///
/// A prompt-assembly parameter rather than a rewrite pass, decided because a
/// second pass doubles cost and latency on every answer and — worse — cannot be
/// trusted to preserve structure: asked to make a DACI "concise", a rewriter
/// drops the D.
///
/// The invariant that makes this safe: a style adjusts DELIVERY and never the
/// contract. Concise-DACI is a shorter DACI, not prose. Every instruction here
/// is therefore phrased as a constraint on wording, and each one says so
/// explicitly, because a model handed "be brief" alongside a required structure
/// will drop the structure unless told not to.
enum AnswerStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The voice the product has today. Selecting it must change nothing, so
    /// anyone who never opens the control is unaffected.
    case standard
    case concise
    case explanatory
    case formal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .concise: return "Concise"
        case .explanatory: return "Explanatory"
        case .formal: return "Formal"
        }
    }

    var help: String {
        switch self {
        case .standard: return "The default voice"
        case .concise: return "Shortest form that still answers"
        case .explanatory: return "Shows the reasoning behind the answer"
        case .formal: return "Neutral register, no contractions or asides"
        }
    }

    /// The fragment appended to the request.
    ///
    /// Empty for `.standard`: appending "write normally" is a token cost that
    /// buys nothing and risks the model treating it as a change.
    var instruction: String {
        switch self {
        case .standard:
            return ""
        case .concise:
            return "Write as briefly as the question allows. Keep every required "
                + "section and every required field — shorten the wording inside "
                + "them, never the structure."
        case .explanatory:
            return "Show the reasoning that leads to each conclusion, not only the "
                + "conclusion. Keep the required structure exactly; add the "
                + "explanation inside it rather than around it."
        case .formal:
            return "Use a neutral professional register: no contractions, no "
                + "asides, no rhetorical questions. Do not change the required "
                + "structure or drop any required field."
        }
    }

    /// `body` with the style applied. Returns the body unchanged when the style
    /// adds nothing, so callers need no special case for `.standard`.
    func applied(to body: String) -> String {
        let fragment = instruction
        guard !fragment.isEmpty else { return body }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        // Appended, not prepended: the task must be read first, and a trailing
        // constraint is the position models honour most reliably.
        return trimmed + "\n\n" + fragment
    }

    /// Persisted per session rather than globally, because the right register
    /// for a board update is the wrong one for a debugging call.
    static let defaultStyle: AnswerStyle = .standard
}
