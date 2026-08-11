import Foundation
import Testing
@testable import MeetGPT

/// Clarifying questions ask BEFORE the answer is spent, when a request admits
/// two readings that would produce different work.
///
/// Most of these guard the direction that actually goes wrong. Asking too often
/// is not a smaller version of the same mistake — it teaches the user to dismiss
/// the card unread, at which point the one question that mattered is dismissed
/// with it, exactly as the live blind-spot panel learned. So every rule here
/// fails safe toward "just answer it".
@Suite("Clarifying questions")
struct ClarifyingQuestionTests {

    // MARK: - Tier 0: countable ambiguity, no model call

    @Test("asks which document when several are attached and none is named")
    func documentAmbiguity() {
        let questions = ClarificationPlanner.plan(
            prompt: "Summarize the doc for the board",
            candidates: .init(documents: ["Q4 pricing memo.pdf", "Security review.docx", "Roadmap.md"]))

        #expect(questions.count == 1)
        #expect(questions[0].header == "Document")
        // The options are the REAL filenames — the whole point of doing this
        // deterministically instead of asking a model to imagine choices.
        #expect(questions[0].options.map(\.label).contains("Q4 pricing memo.pdf"))
        #expect(questions[0].options.count == 3)
    }

    @Test("stays silent when the prompt already names one of the documents")
    func namedDocumentIsNotAmbiguous() {
        let questions = ClarificationPlanner.plan(
            prompt: "Summarize the pricing memo doc",
            candidates: .init(documents: ["Q4 pricing memo.pdf", "Security review.docx"]))
        #expect(questions.isEmpty)
    }

    @Test("stays silent when only one candidate exists")
    func singleCandidateIsNotAmbiguous() {
        let questions = ClarificationPlanner.plan(
            prompt: "Summarize the doc",
            candidates: .init(documents: ["Q4 pricing memo.pdf"]))
        #expect(questions.isEmpty)
    }

    @Test("stays silent when the prompt never points at a document")
    func noReferentIsNotAmbiguous() {
        let questions = ClarificationPlanner.plan(
            prompt: "What did we decide about hiring?",
            candidates: .init(documents: ["Q4 pricing memo.pdf", "Security review.docx"]))
        #expect(questions.isEmpty)
    }

    @Test("asks which tracker when writeback is implied and several are connected")
    func trackerAmbiguity() {
        let questions = ClarificationPlanner.plan(
            prompt: "Pull out the action items and file them",
            candidates: .init(trackers: ["Linear", "Jira", "Asana"]))

        #expect(questions.count == 1)
        #expect(questions[0].header == "Tracker")
        #expect(questions[0].options.map(\.label) == ["Linear", "Jira", "Asana"])
    }

    @Test("stays silent when the prompt names the tracker")
    func namedTrackerIsNotAmbiguous() {
        let questions = ClarificationPlanner.plan(
            prompt: "Create the task in Linear",
            candidates: .init(trackers: ["Linear", "Jira"]))
        #expect(questions.isEmpty)
    }

    @Test("never exceeds the question and option caps")
    func respectsCaps() {
        let questions = ClarificationPlanner.plan(
            prompt: "Summarize the doc and file it",
            candidates: .init(
                documents: ["A memo.pdf", "B review.docx", "C roadmap.md", "D charter.md", "E plan.md"],
                trackers: ["Linear", "Jira", "Asana", "Shortcut", "Height"]))

        #expect(questions.count <= ClarifyingQuestion.maxQuestions)
        for question in questions {
            #expect(question.options.count <= ClarifyingQuestion.maxOptions)
            #expect(question.options.count >= ClarifyingQuestion.minOptions)
        }
    }

    @Test("no candidates means nothing to ask")
    func emptyCandidates() {
        #expect(ClarificationPlanner.plan(prompt: "Summarize the doc", candidates: .init()).isEmpty)
    }

    // MARK: - Tier 2 contract decoding

    @Test("an explicit no-clarification verdict produces no questions")
    func decodesNegativeVerdict() {
        #expect(ClarifyingQuestion.decode(from: #"{"needed":false}"#).isEmpty)
    }

    @Test("decodes a well-formed question with option detail")
    func decodesQuestion() {
        let json = """
        {"needed":true,"questions":[{"header":"Audience","question":"Who is this for?","multiSelect":false,\
        "options":[{"label":"The board","detail":"Outcomes only, no implementation"},\
        {"label":"The eng team","detail":"Keeps the technical trade-offs"}]}]}
        """
        let questions = ClarifyingQuestion.decode(from: json)

        #expect(questions.count == 1)
        #expect(questions[0].header == "Audience")
        #expect(questions[0].question == "Who is this for?")
        #expect(questions[0].options.count == 2)
        #expect(questions[0].options[0].detail == "Outcomes only, no implementation")
        #expect(!questions[0].multiSelect)
    }

    @Test("tolerates the model wrapping JSON in prose or fences")
    func decodesWrappedJSON() {
        let text = """
        Here you go:
        ```json
        {"needed":true,"questions":[{"header":"Scope","question":"Which part?","options":[\
        {"label":"Just today"},{"label":"The whole quarter"}]}]}
        ```
        """
        #expect(ClarifyingQuestion.decode(from: text).count == 1)
    }

    @Test("drops a question that offers fewer than two options")
    func dropsUnaskableQuestion() {
        let json = #"{"needed":true,"questions":[{"header":"X","question":"Which?","options":[{"label":"Only one"}]}]}"#
        #expect(ClarifyingQuestion.decode(from: json).isEmpty)
    }

    @Test("unparseable output degrades to answering, not to an error")
    func unparseableDegrades() {
        #expect(ClarifyingQuestion.decode(from: "I'm not sure what you mean, could you clarify?").isEmpty)
        #expect(ClarifyingQuestion.decode(from: "").isEmpty)
    }

    @Test("truncates an over-long header rather than dropping the question")
    func truncatesHeader() {
        let json = """
        {"needed":true,"questions":[{"header":"An extremely long header nobody asked for",\
        "question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}
        """
        let questions = ClarifyingQuestion.decode(from: json)
        #expect(questions.count == 1)
        #expect(questions[0].header.count <= ClarifyingQuestion.maxHeaderChars)
    }

    @Test("assigns distinct ids even when the model repeats option labels")
    func assignsDistinctIDs() {
        let json = """
        {"needed":true,"questions":[{"header":"X","question":"Which?",\
        "options":[{"label":"Same"},{"label":"Same"}]}]}
        """
        let questions = ClarifyingQuestion.decode(from: json)
        #expect(questions.count == 1)
        #expect(Set(questions[0].options.map(\.id)).count == 2)
    }

    // MARK: - Folding answers back into the prompt

    @Test("folds selected options into the prompt as settled facts")
    func foldsAnswers() {
        let question = ClarifyingQuestion(
            question: "Who is this for?", header: "Audience",
            options: [.init(label: "The board"), .init(label: "The eng team")])
        let answer = ClarificationAnswer(questionID: question.id, selected: [question.options[0].id])

        let folded = ClarificationService.fold(
            prompt: "Summarize the call", questions: [question], answers: [answer])

        #expect(folded.hasPrefix("Summarize the call"))
        #expect(folded.contains("Who is this for?"))
        #expect(folded.contains("The board"))
        #expect(folded.contains("do not ask again"))
    }

    @Test("folds free text from the escape hatch")
    func foldsOtherText() {
        let question = ClarifyingQuestion(
            question: "Who is this for?", header: "Audience",
            options: [.init(label: "The board"), .init(label: "The eng team")])
        let answer = ClarificationAnswer(questionID: question.id, other: "Our design partners")

        let folded = ClarificationService.fold(
            prompt: "Summarize the call", questions: [question], answers: [answer])
        #expect(folded.contains("Our design partners"))
    }

    @Test("combines several selections for a multi-select question")
    func foldsMultiSelect() {
        let question = ClarifyingQuestion(
            question: "Which sections?", header: "Sections",
            options: [.init(label: "Risks"), .init(label: "Actions"), .init(label: "Decisions")],
            multiSelect: true)
        let answer = ClarificationAnswer(
            questionID: question.id,
            selected: [question.options[0].id, question.options[2].id])

        let folded = ClarificationService.fold(
            prompt: "Summarize", questions: [question], answers: [answer])
        #expect(folded.contains("Risks"))
        #expect(folded.contains("Decisions"))
    }

    @Test("an unanswered card leaves the prompt exactly as written")
    func unansweredLeavesPromptAlone() {
        let question = ClarifyingQuestion(
            question: "Who is this for?", header: "Audience",
            options: [.init(label: "The board"), .init(label: "The eng team")])

        #expect(ClarificationService.fold(prompt: "Summarize the call", questions: [question], answers: [])
            == "Summarize the call")
        #expect(ClarificationService.fold(
            prompt: "Summarize the call", questions: [question],
            answers: [ClarificationAnswer(questionID: question.id)]) == "Summarize the call")
    }
}
