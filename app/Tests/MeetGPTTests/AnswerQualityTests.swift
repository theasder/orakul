import Foundation
import Testing
@testable import MeetGPT

// Two measurements the deterministic critics could not make, and the two ways
// they feed back into what ships.
//
//   1. CONTRACT. Every quick prompt declares its own output shape in its text
//      ("Issue • status • owner • next step"). Nothing checked the answer
//      honoured it, so the commonest real failure — prose where a register was
//      asked for — was invisible.
//   2. AGREEMENT. Critic hit rates say nothing about whether the critics measure
//      what a user cares about. Cross-tabulating them against the user's own
//      verdict turns the rates into a testable instrument.

@Suite("Prompt output contracts")
struct PromptContractTests {
    private let unresolved = """
    Identify topics that remain open. Return a ranked list (highest-risk loop \
    first): Issue • status {decision-pending | blocked-external} • owner (or \
    'TBD') • next step • target date • related timestamp(s).
    """

    @Test("the declared fields are read off the prompt itself")
    func fieldsAreParsed() {
        let fields = PromptContract.declaredFields(in: unresolved)
        #expect(fields.contains("issue"))
        #expect(fields.contains("status"))
        #expect(fields.contains("owner"))
        #expect(fields.contains("next step"))
        #expect(fields.contains("target date"))
        // Parentheticals and brace enumerations are qualifiers, not field names.
        #expect(!fields.contains(where: { $0.contains("decision-pending") }))
        #expect(!fields.contains(where: { $0.contains("tbd") }))
    }

    @Test("a prompt with no declared shape declares nothing")
    func freeformHasNoContract() {
        // Most prompts are prose. Inventing fields for them would manufacture
        // violations out of nothing.
        #expect(PromptContract.declaredFields(in:
            "Summarize the call so far in a short paragraph.").isEmpty)
        #expect(PromptContract.declaredFields(in: "").isEmpty)
    }

    @Test("an answer in the declared register passes")
    func compliantAnswerPasses() {
        let answer = """
        - Issue: offline sync unresolved. Status: decision-pending. Owner: Priya. \
        Next step: confirm queue behaviour. Target date: the 22nd. Timestamps: 00:40.
        """
        #expect(PromptContract.missingFields(in: answer, declared:
            PromptContract.declaredFields(in: unresolved)).isEmpty)
    }

    @Test("prose where a register was asked for is flagged")
    func proseAnswerIsFlagged() {
        let answer = String(repeating:
            "The team discussed the release at length and generally agreed it was fine. ",
            count: 4)
        let findings = ReflectionCritics.judgeAnswerContract(
            answer: answer, promptText: unresolved)
        #expect(findings.contains { $0.rule == "answer.contractIncomplete" })
    }

    @Test("a short honest refusal is not a contract violation")
    func shortRefusalIsNotJudged() {
        // "No concrete decision has been made yet" is the correct answer to a
        // decision prompt in a call that has not decided anything. Grading it
        // against a six-field register would punish the app for being honest.
        let findings = ReflectionCritics.judgeAnswerContract(
            answer: "No concrete decision has been made yet.", promptText: unresolved)
        #expect(findings.isEmpty)
    }

    @Test("a partially compliant answer is tolerated")
    func paraphraseIsTolerated() {
        // Header matching is blunt: it cannot see a field the model renamed. The
        // rule therefore fires only when MOST of the register is absent, so it
        // under-reports rather than inventing violations.
        let answer = """
        - Issue: offline sync. Owner: Priya. Next step: confirm the queue. \
        Target date: 22nd. When it came up: 00:40.
        """
        #expect(ReflectionCritics.judgeAnswerContract(
            answer: answer, promptText: unresolved).isEmpty)
    }
}

@Suite("Critics measured against the user's own verdict")
struct CriticAgreementTests {
    private func exchange(answer: String, feedback: AnswerFeedback?) -> AIExchange {
        AIExchange(prompt: "Summarize", answer: answer, at: Date(),
                   promptID: "summary", status: .succeeded, feedback: feedback)
    }

    private func session(_ exchanges: [AIExchange], transcript: String) -> SavedSession {
        SavedSession(
            id: UUID(), title: "Call", startedAt: Date(), savedAt: Date(),
            goal: "", entries: [TranscriptEntry(source: .system, text: transcript)],
            aiResponse: "", aiHistory: exchanges, digest: "")
    }

    @Test("a clean answer the user liked is an agreement")
    func agreedGood() {
        let s = session([exchange(answer: "We decided to ship on the 22nd.",
                                  feedback: AnswerFeedback(rating: .helpful))],
                        transcript: "We decided to ship on the 22nd.")
        let agreement = ReflectionEval.agreement(for: [s])
        #expect(agreement.agreedGood == 1)
        #expect(agreement.criticsMissed == 0)
    }

    @Test("an answer the critics passed and the user rejected is the interesting cell")
    func criticsMissedIt() {
        // This is where the next critic comes from: nothing mechanical was
        // wrong, and the user still found it useless.
        let s = session([exchange(answer: "Some things were discussed.",
                                  feedback: AnswerFeedback(rating: .unhelpful))],
                        transcript: "We decided to ship on the 22nd.")
        let agreement = ReflectionEval.agreement(for: [s])
        #expect(agreement.criticsMissed == 1)
        #expect(agreement.agreedBad == 0)
    }

    @Test("unlabelled answers are not counted at all")
    func unlabelledIsNotAVerdict() {
        // Most answers get no feedback. Treating silence as approval would
        // inflate every rate here.
        let s = session([exchange(answer: "Anything.", feedback: nil)],
                        transcript: "Anything.")
        #expect(ReflectionEval.agreement(for: [s]).labelled == 0)
    }

    @Test("agreement is zero, not perfect, when nothing was labelled")
    func emptyIsNotPerfect() {
        let agreement = ReflectionEval.agreement(for: [])
        #expect(agreement.labelled == 0)
        #expect(agreement.kappa == 0)
        #expect(agreement.observedAgreement == 0)
    }

    @Test("kappa discounts the agreement you would get by chance")
    func kappaIsChanceCorrected() {
        // A critic that passes everything agrees with a mostly-happy user most
        // of the time while carrying no information. Raw agreement calls that
        // excellent; kappa is what refuses to.
        let alwaysHappy = (0..<10).map {
            exchange(answer: "Fine answer number \($0).",
                     feedback: AnswerFeedback(rating: .helpful))
        }
        let s = session(alwaysHappy, transcript: "Fine answer number 0.")
        let agreement = ReflectionEval.agreement(for: [s])
        #expect(agreement.observedAgreement > 0.9)
        // Every observation in one row: no chance-corrected signal at all.
        #expect(agreement.kappa == 0)
    }
}
