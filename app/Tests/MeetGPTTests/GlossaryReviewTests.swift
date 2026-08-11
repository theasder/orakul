import Foundation
import Testing
@testable import MeetGPT

// Connecting an app is the one moment the names about to be spoken become
// knowable, and the one moment the user is already thinking about that app. So
// the glossary review belongs there — not buried in a Settings pane nobody
// opens, and not applied silently behind their back.
//
// What this decides is WHEN to interrupt. Getting it wrong in either direction
// is the bug: a review nobody asked for during a live call, or no review at all
// so the terms land unseen.

@Suite("When the glossary review is worth showing")
struct GlossaryReviewTests {
    private func suggestion(_ term: String) -> ConnectedGlossarySuggestion {
        ConnectedGlossarySuggestion(term: term, reason: "seen in connected app",
                                    sources: ["notion"])
    }

    private func context(terms: [String] = ["orakul"],
                         isRecording: Bool = false,
                         reviewsDismissed: Bool = false) -> GlossaryReview.Context {
        GlossaryReview.Context(
            candidates: terms.map(suggestion),
            isRecording: isRecording,
            reviewsDismissed: reviewsDismissed)
    }

    @Test("terms found after a connection are worth a review")
    func showsAfterConnection() {
        #expect(GlossaryReview.shouldPresent(context()))
    }

    @Test("nothing found means nothing to interrupt for")
    func silentWhenNoCandidates() {
        // An app with no recognisable names must not produce an empty sheet.
        #expect(!GlossaryReview.shouldPresent(context(terms: [])))
    }

    @Test("never during a live call")
    func neverMidRecording() {
        // The user is in a meeting. A vocabulary sheet over the transcript is
        // the worst possible moment, and the terms keep until it ends.
        #expect(!GlossaryReview.shouldPresent(context(isRecording: true)))
    }

    @Test("a user who turned reviews off is not asked again")
    func respectsDismissal() {
        #expect(!GlossaryReview.shouldPresent(context(reviewsDismissed: true)))
    }

    @Test("terms are applied when the review is skipped, not discarded")
    func skippingAppliesAnyway() {
        // The instruction was explicit: if there is no review, use the terms as
        // they are. Skipping is not rejecting — a term the user never looked at
        // is a decision they have not made, and the recognizer benefits either
        // way.
        let outcome = GlossaryReview.resolve(
            candidates: [suggestion("orakul"), suggestion("Deepgram")],
            reviewed: false, keeping: [])
        #expect(outcome == ["orakul", "Deepgram"])
    }

    @Test("an explicit review applies only what the user kept")
    func reviewedAppliesSelection() {
        // Once they HAVE looked, their selection is the answer — including the
        // terms they unchecked.
        let outcome = GlossaryReview.resolve(
            candidates: [suggestion("orakul"), suggestion("Deepgram")],
            reviewed: true, keeping: ["orakul"])
        #expect(outcome == ["orakul"])
    }

    @Test("a review where everything was unchecked applies nothing")
    func reviewedNothingKept() {
        // And this must not fall back to "apply everything" — an empty
        // selection after a review is a real answer, not a missing one.
        let outcome = GlossaryReview.resolve(
            candidates: [suggestion("orakul")], reviewed: true, keeping: [])
        #expect(outcome.isEmpty)
    }

    @Test("a connection marks a review pending without spending anything")
    func connectionMarksPendingOnly() {
        // Connection success never spends an LLM request — the workflow
        // designer says so in as many words, and generating candidates costs a
        // background call. So connecting only raises a flag; the call happens
        // when the user looks, which is also when the review would be useful.
        #expect(GlossaryReview.marksPending(authorizedApps: 1, isRecording: false))
        #expect(!GlossaryReview.marksPending(authorizedApps: 0, isRecording: false))
    }

    @Test("disconnecting the last app clears the pending review")
    func lastDisconnectClearsPending() {
        // Nothing left to mine, so a badge promising vocabulary would be a lie.
        #expect(!GlossaryReview.marksPending(authorizedApps: 0, isRecording: false))
    }

    @Test("a connection made mid-call does not queue an interruption")
    func midCallConnectionDoesNotQueue() {
        #expect(!GlossaryReview.marksPending(authorizedApps: 2, isRecording: true))
    }

    @Test("the review never proposes more than one batch's worth")
    func reviewRespectsTheBatchCap() {
        let many = (0..<200).map { suggestion("Term\($0)") }
        let outcome = GlossaryReview.resolve(
            candidates: many, reviewed: false, keeping: [])
        #expect(outcome.count <= GlossaryAutoApply.maximumTermsPerConnection)
    }
}
