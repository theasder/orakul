import Foundation

/// Terminal state of one assistant request. `inProgress` is used only by the
/// live exchange; every value written to the evidence ledger is terminal.
///
/// Keep the raw values stable: dev-run artifacts and saved sessions consume
/// them without linking against the app.
enum AIExchangeStatus: String, Codable, Equatable {
    case inProgress
    case succeeded
    case failed
    case cancelled
    case superseded

    var isSuccessful: Bool { self == .succeeded }
    var isTerminal: Bool { self != .inProgress }
}

/// One completed question-and-answer turn in the assistant dialog.
///
/// The LIVE turn stays in `AppState.aiResponse` / `aiResponsePrompt`; this type
/// archives the turns before it. Previously those two properties were the whole
/// dialog, so pressing a second prompt overwrote the first answer in place and
/// everything earlier in the meeting was gone — including answers the user was
/// still reading or about to export.
///
/// `Codable` so the archive survives save/restore with the rest of the session.
struct AIExchange: Identifiable, Equatable, Codable {
    let id: UUID
    let prompt: String
    let answer: String
    let at: Date
    /// When the prompt was injected, distinct from `at` (the archive time).
    /// Optional keeps sessions written before temporal quality scoring valid.
    let promptedAt: Date?
    /// Stable product prompt identity (`summary`, `whattoask`, `freeform`, …).
    /// Optional because sessions written before lifecycle evidence have none.
    let promptID: String?
    /// The instant this attempt reached a terminal state. It is intentionally
    /// distinct from `at`, which remains the dialog archive timestamp.
    let completedAt: Date?
    /// Explicit lifecycle state prevents a partial stream that happened to
    /// contain prose from being graded as a successful answer.
    let status: AIExchangeStatus
    /// Suggested next actions belong to the answer that produced them. Keeping
    /// them on the archived exchange prevents a later prompt from making useful
    /// buttons disappear out from under the user.
    let followUpPrompts: [QuickPrompt]
    /// The Do this / Save as blocks planned from THIS answer, so an
    /// archived turn keeps its own actions instead of borrowing the live
    /// answer's.
    let answerActions: [AnswerActionPlanner.Action]
    /// What the user thought of this answer, when they said. `var` because it
    /// arrives after the turn is archived — the answer is complete long before
    /// anyone judges it.
    var feedback: AnswerFeedback?

    init(id: UUID = UUID(),
         prompt: String,
         answer: String,
         at: Date = Date(),
         promptedAt: Date? = nil,
         promptID: String? = nil,
         completedAt: Date? = nil,
         status: AIExchangeStatus = .succeeded,
         followUpPrompts: [QuickPrompt] = [],
         answerActions: [AnswerActionPlanner.Action] = [],
         feedback: AnswerFeedback? = nil) {
        self.id = id
        self.prompt = prompt
        self.answer = answer
        self.at = at
        self.promptedAt = promptedAt
        self.promptID = promptID
        self.completedAt = completedAt
        self.status = status
        self.followUpPrompts = followUpPrompts
        self.answerActions = answerActions
        self.feedback = feedback
    }

    /// Only a completed successful answer belongs in the visible dialog. A
    /// cancelled or superseded stream may contain convincing partial prose,
    /// but it remains terminal evidence rather than an answer users can copy,
    /// persist, export, or score as complete.
    var isArchivable: Bool {
        status == .succeeded
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, prompt, answer, at, promptedAt, promptID, completedAt, status,
             followUpPrompts, answerActions, feedback
    }

    /// Synthesized decoding would make newly-added non-optional `status`
    /// reject every existing saved session. Infer the old behavior instead:
    /// non-error prose was a completed turn, error prose failed, and an empty
    /// legacy exchange was cancelled.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        prompt = try values.decode(String.self, forKey: .prompt)
        answer = try values.decode(String.self, forKey: .answer)
        at = try values.decode(Date.self, forKey: .at)
        promptedAt = try values.decodeIfPresent(Date.self, forKey: .promptedAt)
        promptID = try values.decodeIfPresent(String.self, forKey: .promptID)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        followUpPrompts = try values.decodeIfPresent(
            [QuickPrompt].self, forKey: .followUpPrompts) ?? []
        // Optional: sessions saved before actions were archived must still decode.
        answerActions = try values.decodeIfPresent(
            [AnswerActionPlanner.Action].self, forKey: .answerActions) ?? []
        // Optional for the same reason: every session saved before feedback
        // existed has no such key, and requiring it would reject all of them.
        feedback = try values.decodeIfPresent(AnswerFeedback.self, forKey: .feedback)
        if let explicit = try values.decodeIfPresent(AIExchangeStatus.self, forKey: .status) {
            status = explicit
        } else {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            status = trimmed.isEmpty ? .cancelled
                : trimmed.hasPrefix("Error:") ? .failed : .succeeded
        }
    }
}
