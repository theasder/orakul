import Foundation

/// A question the assistant asks BEFORE answering, when the prompt admits two
/// readings that would produce materially different work.
///
/// The failure mode this guards against is not "the model was confused" — it is
/// the model quietly picking one reading, producing three paragraphs against it,
/// and the user discovering at the end that it answered a different question.
/// One cheap question up front beats one wasted answer.
///
/// The opposite failure is worse and much easier to fall into: asking about
/// things that did not need asking. That trains the user to dismiss the card on
/// sight, at which point the one question that mattered is dismissed too — the
/// same lesson `blindSpotJudge` learned about the live panel. Everything here is
/// tuned to ask rarely.
struct ClarifyingQuestion: Identifiable, Equatable, Codable {
    /// One selectable answer. `detail` explains what picking it will change,
    /// which is the difference between a poll and a useful question.
    struct Option: Identifiable, Equatable, Codable {
        let id: UUID
        let label: String
        let detail: String?

        init(id: UUID = UUID(), label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    let id: UUID
    /// The full question, ending in a question mark.
    let question: String
    /// Very short chip label shown above the question, e.g. "Audience".
    let header: String
    let options: [Option]
    /// True when the options are not mutually exclusive.
    let multiSelect: Bool

    init(id: UUID = UUID(), question: String, header: String, options: [Option], multiSelect: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// What the user picked for one question. `other` carries free text typed into
/// the always-present "Something else" field, which is the escape hatch for the
/// case the model failed to imagine.
struct ClarificationAnswer: Equatable {
    let questionID: UUID
    var selected: Set<UUID>
    var other: String

    init(questionID: UUID, selected: Set<UUID> = [], other: String = "") {
        self.questionID = questionID
        self.selected = selected
        self.other = other
    }

    var isEmpty: Bool {
        selected.isEmpty && other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A prompt held back from the model until the user resolves its ambiguity. The
/// original prompt and any pinned images ride along so answering resumes exactly
/// the run that was paused, rather than reconstructing it.
struct PendingClarification: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let images: [Data]
    let questions: [ClarifyingQuestion]

    init(id: UUID = UUID(), prompt: String, images: [Data], questions: [ClarifyingQuestion]) {
        self.id = id
        self.prompt = prompt
        self.images = images
        self.questions = questions
    }
}

// MARK: - Decoding the model's contract

extension ClarifyingQuestion {
    /// Wire shape. Ids are assigned locally rather than trusted from the model —
    /// a duplicate or missing id from the wire would collide SwiftUI's identity
    /// and silently mis-render selections.
    private struct Wire: Decodable {
        struct Option: Decodable {
            let label: String
            let detail: String?
        }
        let question: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool?
    }

    private struct Envelope: Decodable {
        let needed: Bool?
        let questions: [Wire]?
    }

    /// Hard caps. A clarification card that fills the pane has stopped being
    /// cheaper than just answering and being corrected.
    static let maxQuestions = 2
    static let maxOptions = 4
    static let minOptions = 2
    static let maxHeaderChars = 14

    /// Parses the assessment reply. Returns [] for "no clarification needed",
    /// for unparseable output, and for anything that fails the shape rules —
    /// every failure mode degrades to "just answer the question", which is the
    /// behaviour the app had before this existed.
    static func decode(from text: String) -> [ClarifyingQuestion] {
        guard let json = JSONExtraction.firstObject(in: text), let data = json.data(using: .utf8) else { return [] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        if envelope.needed == false { return [] }
        guard let wires = envelope.questions else { return [] }

        return wires.prefix(maxQuestions).compactMap { wire -> ClarifyingQuestion? in
            let question = wire.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }

            let options = wire.options
                .map { option in
                    Option(label: option.label.trimmingCharacters(in: .whitespacesAndNewlines),
                           detail: option.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                }
                .filter { !$0.label.isEmpty }
                .prefix(maxOptions)

            // A question with fewer than two options is not a question.
            guard options.count >= minOptions else { return nil }

            let header = (wire.header?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Clarify")
            return ClarifyingQuestion(
                question: question,
                header: String(header.prefix(maxHeaderChars)),
                options: Array(options),
                multiSelect: wire.multiSelect ?? false
            )
        }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
