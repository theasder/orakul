import Foundation
import Testing
@testable import MeetGPT

// Connecting an app should leave Whisper knowing the names it is about to hear.
// The suggestion pass already reads them out of connected-app context; what was
// missing is applying them without making the user hunt for a Settings pane and
// press Add fifteen times.
//
// Glossary terms BIAS recognition — a wrong term does not sit inert, it pulls
// real words toward itself — so the rules about what may be applied unattended
// are the substance of this file.

@Suite("Glossary applied without review")
struct GlossaryAutoApplyTests {
    private func suggestion(_ term: String) -> ConnectedGlossarySuggestion {
        ConnectedGlossarySuggestion(term: term, reason: "seen in connected app",
                                    sources: ["notion"])
    }

    @Test("suggested terms are applied as they are")
    func appliesSuggestions() {
        let add = GlossaryAutoApply.termsToAdd(
            suggestions: [suggestion("Cruxwing"), suggestion("Deepgram")],
            existing: "", rejectedKeys: [])
        #expect(add == ["Cruxwing", "Deepgram"])
    }

    @Test("a term the user already rejected is never re-applied")
    func rejectedStaysRejected() {
        // The user said no to this spelling once. Auto-apply is about sparing
        // them a decision they have not made, not overturning one they have.
        let rejected = Set([ConnectedGlossarySuggestionService.canonicalKey("Deepgram")])
        let add = GlossaryAutoApply.termsToAdd(
            suggestions: [suggestion("Cruxwing"), suggestion("Deepgram")],
            existing: "", rejectedKeys: rejected)
        #expect(add == ["Cruxwing"])
    }

    @Test("terms already in the glossary are not duplicated")
    func existingTermsAreSkipped() {
        let add = GlossaryAutoApply.termsToAdd(
            suggestions: [suggestion("Cruxwing"), suggestion("Deepgram")],
            existing: "cruxwing, Whisper", rejectedKeys: [])
        #expect(add == ["Deepgram"])
    }

    @Test("blank and absurd terms never reach the recognizer")
    func junkIsFiltered() {
        // A one-character "term" biases everything toward itself; an essay is a
        // parse failure wearing a term's clothes.
        let add = GlossaryAutoApply.termsToAdd(
            suggestions: [
                suggestion("   "),
                suggestion("x"),
                suggestion(String(repeating: "long ", count: 40)),
                suggestion("Priya Raghunathan"),
            ],
            existing: "", rejectedKeys: [])
        #expect(add == ["Priya Raghunathan"])
    }

    @Test("the batch is capped so one connection cannot flood the vocabulary")
    func batchIsCapped() {
        let many = (0..<200).map { suggestion("Term\($0)") }
        let add = GlossaryAutoApply.termsToAdd(
            suggestions: many, existing: "", rejectedKeys: [])
        #expect(add.count == GlossaryAutoApply.maximumTermsPerConnection)
        // A recognizer prompt is finite; past some size the glossary stops
        // helping and starts crowding out what was actually said.
        #expect(add.count <= 50)
    }

    @Test("merging produces a glossary the existing parser can read back")
    func mergeRoundTrips() {
        let merged = GlossaryAutoApply.merge(existing: "Whisper",
                                             adding: ["Cruxwing", "Deepgram"])
        let terms = Glossary.terms(from: merged)
        #expect(terms.contains("Whisper"))
        #expect(terms.contains("Cruxwing"))
        #expect(terms.contains("Deepgram"))
    }

    @Test("merging nothing changes nothing")
    func mergeNothingIsInert() {
        #expect(GlossaryAutoApply.merge(existing: "Whisper", adding: []) == "Whisper")
    }
}
