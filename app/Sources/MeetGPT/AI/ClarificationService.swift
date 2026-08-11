import Foundation

/// Tier 2 of the clarification pipeline: the model pass, reached only when
/// `ClarificationPlanner` found nothing countable to ask about.
///
/// What makes this worth a call is not the model — it is what the call is given.
/// The routed SKILL.md supplies the decision axes of the domain (a hiring skill
/// knows to ask which competency; a pricing skill knows to ask which segment),
/// and the grounding snippets supply the real entities to offer as options. Ask
/// the same model with neither and it invents "Formal / Casual", which is a poll,
/// not a question.
///
/// Runs on the fast tier with a tiny output budget. It sits in front of every
/// free-form answer, so it must cost close to nothing or it is not worth having.
enum ClarificationService {

    /// Clip sizes. This pass decides whether to ask, not how to answer, so it
    /// gets a fraction of what the real run receives.
    private static let maxGroundingChars = 2_500
    private static let maxSkillChars = 1_200
    private static let maxTranscriptChars = 1_500

    private static func systemPrompt() -> String {
        """
        You decide whether a request to a meeting co-pilot is ambiguous enough that \
        answering it now would waste the answer.

        Ask ONLY when two readings of the request would produce materially different \
        work, and picking wrong means the whole answer is useless. Everything else — \
        tone, length, formatting, a detail you could state an assumption about, \
        anything you could simply do both of — is NOT worth asking. When you are \
        unsure whether to ask, do not ask. Silence is the correct default and the \
        common case.

        A weak question is not free: it delays the answer and teaches the user to \
        dismiss the card unread, which costs them the one question that mattered.

        When you do ask, ground the options in the material you were given. Offer the \
        REAL documents, tickets, deals, people or projects that appear in the \
        background below — never invented placeholders, never "Option A / Option B". \
        If you cannot fill the options with concrete things from the material, that \
        is itself a sign the question is too vague to be worth asking.

        Return STRICT minified JSON, no prose, no code fences.
        Nothing to ask:  {"needed":false}
        Otherwise:       {"needed":true,"questions":[{"header":"<=14 chars","question":"...?","multiSelect":false,"options":[{"label":"short","detail":"what choosing this changes"}]}]}

        At most \(ClarifyingQuestion.maxQuestions) questions, \
        \(ClarifyingQuestion.minOptions)-\(ClarifyingQuestion.maxOptions) options each. \
        Do not add an "other" option — the interface always provides one.
        """
    }

    /// Returns the questions worth asking, or [] for "just answer it". Every
    /// failure — unparseable output, a network error, a malformed shape — also
    /// returns [], so this can only ever delay an answer, never prevent one.
    static func assess(prompt: String,
                       goal: String,
                       transcript: String,
                       grounding: String,
                       skillGuidance: String?,
                       model: LLMModel,
                       gateway: LLMGateway) async -> [ClarifyingQuestion] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sections: [String] = ["Request:\n\(trimmed)"]
        if !goal.isEmpty {
            sections.append("The user's stated goal for this call:\n\(goal)")
        }
        if let skillGuidance, !skillGuidance.isEmpty {
            sections.append("Domain methodology for this kind of request — use it to know which "
                + "decisions this work actually turns on:\n\(String(skillGuidance.prefix(maxSkillChars)))")
        }
        if !grounding.isEmpty {
            sections.append("Live background from connected apps — the concrete things you may "
                + "offer as options:\n\(String(grounding.prefix(maxGroundingChars)))")
        }
        if !transcript.isEmpty {
            sections.append("Recent conversation:\n\(String(transcript.suffix(maxTranscriptChars)))")
        }

        let reply = try? await gateway.streamChat(
            system: systemPrompt(),
            user: sections.joined(separator: "\n\n"),
            images: [],
            model: model
        ) { _ in }

        guard let reply else { return [] }
        return ClarifyingQuestion.decode(from: reply)
    }

    // MARK: - Folding answers back into the prompt

    /// Rewrites the original prompt with the user's choices appended, so the run
    /// that follows is a normal run — no special casing downstream, and the
    /// archived exchange shows what was actually asked of the model.
    static func fold(prompt: String,
                     questions: [ClarifyingQuestion],
                     answers: [ClarificationAnswer]) -> String {
        let resolved = questions.compactMap { question -> String? in
            guard let answer = answers.first(where: { $0.questionID == question.id }), !answer.isEmpty else {
                return nil
            }
            let picked = question.options
                .filter { answer.selected.contains($0.id) }
                .map(\.label)
            let other = answer.other.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = picked + (other.isEmpty ? [] : [other])
            guard !all.isEmpty else { return nil }
            return "- \(question.question) \(all.joined(separator: "; "))"
        }

        guard !resolved.isEmpty else { return prompt }
        return prompt + "\n\nClarifications the user provided — treat these as settled, "
            + "do not ask again:\n" + resolved.joined(separator: "\n")
    }
}
