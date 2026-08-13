import Foundation
import Testing
@testable import MeetGPT

/// F10: every figure an artifact states must exist in the transcript, or be
/// flagged. Deterministic — a model checking its own numbers is the fox
/// auditing the henhouse.
@Suite("Numbers guard")
struct NumbersGuardTests {

    @Test("display variants of one spoken quantity are the same number")
    func canonicalisation() {
        #expect(NumbersGuard.canonical("$2,500") == NumbersGuard.canonical("2500"))
        #expect(NumbersGuard.canonical("2.5k") == NumbersGuard.canonical("2500"))
        #expect(NumbersGuard.canonical("$1.2m") == NumbersGuard.canonical("1200000"))
        #expect(NumbersGuard.canonical("40 %") == NumbersGuard.canonical("40%"))
        // A percentage and a bare count are NOT the same statement.
        #expect(NumbersGuard.canonical("40%") != NumbersGuard.canonical("40"))
    }

    @Test("a figure the room never said is flagged, in the artifact's own form")
    func inventedFigureFlagged() {
        let transcript = "We agreed the enterprise plan moves to $499 next quarter, roughly a 12% raise."
        let artifact = "Decisions: enterprise plan to $499; projected churn impact 3%; headcount to 45."
        let flagged = NumbersGuard.unverifiedFigures(artifact: artifact, transcript: transcript)
        #expect(flagged.contains("3%"))
        #expect(flagged.contains("45"))
        #expect(!flagged.contains("$499"), "a spoken figure must never be flagged")
    }

    @Test("display differences do not create false alarms")
    func displayVariantsPass() {
        let transcript = "Budget is twenty five hundred dollars — 2500 — and we cap at 1.2m requests."
        let artifact = "Budget: $2,500. Cap: 1,200,000 requests."
        #expect(NumbersGuard.unverifiedFigures(artifact: artifact, transcript: transcript).isEmpty)
    }

    @Test("an artifact without numbers audits clean")
    func noNumbersNoFlags() {
        #expect(NumbersGuard.unverifiedFigures(
            artifact: "Decisions: ship the redesign behind a flag.",
            transcript: "We ship the redesign behind a flag.").isEmpty)
    }

    @Test("figures spoken as words are not reported as invented")
    func spokenNumberWordsAreNotFalseFlags() {
        // People say numbers; transcripts write what people say. If the room
        // says "twenty five hundred" and the minutes say "$2,500", a guard that
        // calls that unverified is crying wolf — and a warning that is usually
        // wrong is a warning users switch off, taking the real catches with it.
        let transcript = "We agreed the budget is twenty five hundred dollars for the pilot, "
            + "with about forty percent going to onboarding, and we want it live in "
            + "ninety days with a team of six."
        let artifact = "Budget $2,500. Onboarding 40%. Live in 90 days. Team of 6."
        let flagged = NumbersGuard.unverifiedFigures(artifact: artifact, transcript: transcript)
        #expect(flagged.isEmpty, "spoken-as-words figures were flagged as invented: \(flagged)")
    }

    @Test("minutes render a verify-these-figures block only when something is unverified")
    func minutesFooter() {
        let minutes = MinutesArtifact(
            title: "Sync", date: nil, attendees: nil, summary: nil,
            decisions: ["Enterprise plan to $499", "Headcount grows to 45"],
            discussion: nil, actionItems: nil, nextSteps: nil)
        let audited = minutes.auditingNumbers(
            against: "we agreed the enterprise plan moves to $499")
        #expect(audited.markdown.contains("Проверьте эти цифры"))
        let warning = String(audited.markdown[audited.markdown.range(of: "Проверьте эти цифры")!.upperBound...])
        #expect(warning.contains("45"))
        #expect(!warning.contains("$499"), "verified figures stay out of the warning")

        let clean = minutes.auditingNumbers(
            against: "enterprise plan $499, headcount forty five, i.e. 45 people")
        #expect(!clean.markdown.contains("Проверьте эти цифры"))
    }
}
