import Foundation

/// A mode that answers with questions — the interviewer's posture — for
/// thinking-out-loud sessions rather than fact retrieval.
///
/// **Why this is a mode and not an answer style.** `AnswerStyle` documents its
/// own invariant: a style adjusts DELIVERY and never the contract. Concise-DACI
/// is a shorter DACI. Every style still answers the question. Socratic mode
/// withholds the answer, which is a change to the contract, not the wording — so
/// putting it in `AnswerStyle` would break the guarantee that makes styles safe
/// to apply everywhere, and would turn a Socratic fact-check into nonsense.
///
/// It also needs three things no style needs, and their existence is the tell:
/// a bound on how long it may withhold, a way out in one action, and a control
/// the user cannot miss. Nobody needs an escape hatch from "concise".
///
/// **Bounded on purpose.** An unbounded Socratic mode is indistinguishable from
/// a broken assistant: the user asks a question, gets a question, and has no way
/// to know whether the product is thinking or malfunctioning. After
/// `exchangeLimit` turns it answers plainly and says why it stopped.
///
/// **Tighter while a call is live**, because the cost of withholding is not the
/// user's alone — other people are in the room waiting for them. A copilot that
/// meets "what was their ARR?" with "what makes ARR the right measure?" while
/// someone waits on the call is actively harmful, whatever it is doing for
/// reflection.
enum SocraticMode {

    /// Exchanges it may answer with questions before answering plainly.
    ///
    /// Three is enough to open up a problem — premise, alternative, test — and
    /// short enough that a user who turned this on by accident finds out fast.
    static let maxExchangesIdle = 3

    /// One, while recording. Enough to offer a reframe; not enough to cost
    /// somebody the moment in a live conversation.
    static let maxExchangesRecording = 1

    static func exchangeLimit(isRecording: Bool) -> Int {
        isRecording ? maxExchangesRecording : maxExchangesIdle
    }

    /// Whether this turn should be a question rather than an answer.
    static func shouldWithholdAnswer(exchangesSoFar: Int, isRecording: Bool) -> Bool {
        guard exchangesSoFar >= 0 else { return false }
        return exchangesSoFar < exchangeLimit(isRecording: isRecording)
    }

    /// Free-form asks only.
    ///
    /// The structured prompts have a required shape — a fact check returns a
    /// verdict, an agenda returns sections with owners — and a mode that
    /// replaces the output with questions does not produce a shorter version of
    /// those, it produces a broken one. Item 7 made the same call for styles and
    /// for the same reason.
    static func applies(toBuiltInPromptID promptID: String?) -> Bool {
        promptID == nil
    }

    /// The fragment that changes the posture.
    static let instruction = """
        Answer with questions rather than conclusions. Ask at most three, each \
        one aimed at a different thing: the premise the question rests on, an \
        alternative that has not been considered, and what evidence would settle \
        it. Do not state the answer, and do not hint at it while pretending to \
        ask. If the question is a matter of fact with one correct answer, say so \
        in one line and answer it — the interviewer's posture is for judgement \
        calls, not for lookups.
        """

    /// Said when the bound runs out.
    ///
    /// The user is told the mode stopped withholding rather than being left to
    /// notice that it behaves differently now. A mode that silently changes what
    /// it does is the failure this whole feature was told to avoid.
    static let boundReachedNotice =
        "Socratic mode has asked as much as it will — here is the direct answer."

    /// Build the request for one turn.
    ///
    /// Returns the prompt unchanged when the mode is off, when the bound is
    /// spent, or when the user has broken out — so every caller gets the plain
    /// behaviour by default and the mode is never applied by accident.
    static func applied(to prompt: String,
                        enabled: Bool,
                        exchangesSoFar: Int,
                        isRecording: Bool,
                        brokenOut: Bool) -> String {
        guard enabled, !brokenOut,
              shouldWithholdAnswer(exchangesSoFar: exchangesSoFar, isRecording: isRecording)
        else { return prompt }
        return prompt + "\n\n" + instruction
    }
}
