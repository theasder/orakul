import Foundation
import Testing
@testable import MeetGPT

/// Backlog item 20 — refine an answer on screen. The pure rules, tested without
/// a model: which answers may be refined (prose yes, structured contracts no),
/// and that the refine instruction reshapes rather than re-answers.
@Suite("Answer refine")
struct AnswerRefineTests {

    // MARK: - The contract guard

    @Test("prose answers may be refined")
    func proseRefinable() {
        #expect(AnswerRefine.canRefine(promptID: nil))          // ad-hoc question
        #expect(AnswerRefine.canRefine(promptID: "whattoask"))
        #expect(AnswerRefine.canRefine(promptID: "brainstorm"))
    }

    @Test("structured answers refuse refine — a free rewrite breaks the contract", arguments: [
        "logdecision", "factcheck", "agenda", "tasks", "commitments", "dispute",
    ])
    func structuredRefused(id: String) {
        // Refusing is acceptable per the item; the caller shows no controls.
        #expect(!AnswerRefine.canRefine(promptID: id))
    }

    @Test("case does not matter for the guard")
    func caseInsensitive() {
        #expect(!AnswerRefine.canRefine(promptID: "FactCheck"))
        #expect(!AnswerRefine.canRefine(promptID: "LOGDECISION"))
    }

    // MARK: - The instruction reshapes, never re-answers

    @Test("every refine prompt forbids adding or dropping facts", arguments: AnswerRefine.Kind.allCases)
    func preservesContent(kind: AnswerRefine.Kind) {
        let p = AnswerRefine.systemPrompt(for: kind).lowercased()
        // The trust property: a refine that invents or drops a fact is worse
        // than none, so the instruction must say so in every mode.
        #expect(p.contains("keep every fact"))
        #expect(p.contains("add nothing") || p.contains("no new information")
                || p.contains("without introducing"))
        // It reshapes the SAME content, not answers again.
        #expect(p.contains("same content") || p.contains("already produced")
                || p.contains("reshaping"))
    }

    @Test("condense asks for shorter, elaborate for fuller")
    func kindsDiffer() {
        #expect(AnswerRefine.systemPrompt(for: .condense).lowercased().contains("shorter"))
        #expect(AnswerRefine.systemPrompt(for: .elaborate).lowercased().contains("fuller"))
    }

    @Test("the user message carries the answer to reshape")
    func userPromptCarriesAnswer() {
        let up = AnswerRefine.userPrompt(answer: "Maria owns the DPA by Friday.")
        #expect(up.contains("Maria owns the DPA by Friday."))
    }
}

/// The AppState side: revert availability tracks the visible answer, so a new
/// prompt invalidates a stale revert without any run site clearing it.
@MainActor
@Suite("Answer refine — revert lifecycle")
struct AnswerRefineRevertTests {

    @Test("no revert before any refine")
    func noRevertInitially() {
        let state = AppState(credentialStore: InMemoryKeychain())
        #expect(!state.canRevertRefine)
        state.revertRefine()   // a no-op, must not crash
        #expect(state.aiResponse.isEmpty)
    }

    @Test("a structured answer cannot be refined")
    func structuredNotRefinable() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.aiResponse = "Decision: ship Friday."
        state.setAIResponsePromptIDForTesting("factcheck")
        #expect(!state.canRefineCurrentAnswer)
    }

    @Test("prose with content is refinable")
    func proseRefinable() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.aiResponse = "A plain prose answer with some substance."
        state.setAIResponsePromptIDForTesting(nil)
        #expect(state.canRefineCurrentAnswer)
    }
}
