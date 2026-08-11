import Foundation
import Testing
@testable import MeetGPT

/// Backlog item 19 — say why a prompt is offered. The acceptance is a quality
/// bar: SPECIFIC or SILENT. These pin that the reason names a concrete thing
/// from the call and never a category, and that vague or irrelevant input
/// yields nil rather than a forced sentence.
@Suite("Prompt reason")
struct PromptReasonTests {

    private func reason(_ id: String, _ transcript: String, goal: String = "") -> String? {
        PromptReason.reason(promptID: id, recentTranscript: transcript, goal: goal)
    }

    // MARK: - Fires on a concrete hook, for a substance prompt

    @Test("a named deadline gives a decision prompt its reason")
    func deadlineReason() {
        let r = reason("logdecision", "Sam: our budget locks Friday, we need sign-off.")
        #expect(r == "You mentioned Friday")
    }

    @Test("a money figure gives a fact-check its reason")
    func moneyReason() {
        let r = reason("factcheck", "Dan: ARR is $40k this quarter, up from last year.")
        #expect(r == "You mentioned $40k")
    }

    @Test("a percentage is a concrete hook")
    func percentReason() {
        let r = reason("risks", "Priya: churn is running at 3% monthly now.")
        #expect(r?.contains("3%") == true)
    }

    @Test("the word deadline alone, no date, still counts")
    func bareDeadline() {
        #expect(reason("tasks", "Leo: the deadline is tight but doable.") == "You mentioned a deadline")
    }

    @Test("the MOST RECENT hook wins, so the reason tracks the live call")
    func recencyWins() {
        let r = reason("summary", "We said Monday. Actually, let's move it to Thursday.")
        #expect(r == "You mentioned Thursday")
    }

    // MARK: - Silent when it should be

    @Test("a prompt with no concrete hook gets no reason, not a generic one")
    func noHookNoReason() {
        // The acceptance: offered WITHOUT a reason rather than given a category.
        #expect(reason("logdecision", "So, how is everyone doing today?") == nil)
    }

    @Test("a non-substance prompt never gets a reason even with a hook")
    func nonSubstanceSilent() {
        // A rhetoric or brainstorm chip is not made more relevant by a date.
        #expect(reason("rhetoric", "The deadline is Friday and ARR is $40k.") == nil)
        #expect(reason("brainstorm", "We must ship by Monday.") == nil)
    }

    @Test("an empty transcript is silent")
    func emptySilent() {
        #expect(reason("summary", "") == nil)
    }

    @Test("never emits a category sentence", arguments: [
        "logdecision", "risks", "factcheck", "summary", "tasks",
    ])
    func neverCategory(id: String) {
        // Whatever it returns, it is nil or starts with the concrete-hook phrase
        // — never "for planning meetings" or any category framing.
        let r = reason(id, "The renewal deadline is Friday.")
        if let r { #expect(r.hasPrefix("You mentioned ")) }
    }

    @Test("a weekday inside a longer word is not matched")
    func wordBoundary() {
        // "understand" contains no weekday; "Sunday" as a substring of a made-up
        // token must not fire. Word boundaries guard this.
        #expect(reason("summary", "We need to understand the sundae menu.") == nil)
    }
}
