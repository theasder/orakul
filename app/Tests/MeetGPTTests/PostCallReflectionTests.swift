import Foundation
import Testing
@testable import MeetGPT

/// The post-call reflection artefact.
///
/// The acceptance criteria were three: never duplicates a summary bullet, quotes
/// the transcript exactly as live blind spots do, and passes the same judge — so
/// a call with nothing worth saying produces nothing.
///
/// `nothingWorthSayingProducesNothing` is the one that matters. A reflection
/// that always emits three points will pad, and padding here is worse than
/// silence: the entire premise is that these are observations worth reading, so
/// filler retroactively devalues the real ones.
@Suite("Post-call reflection")
struct PostCallReflectionTests {

    private func suggestion(_ title: String, evidence: String? = "we never decided that")
    -> Suggestion {
        Suggestion(title: title, detail: "detail", kind: .missingInfo, evidence: evidence)
    }

    // MARK: - Silence is a valid answer

    @Test("nothing worth saying produces nothing")
    func nothingWorthSayingProducesNothing() {
        #expect(PostCallReflection.artefact(from: [], summary: "anything").isEmpty)
    }

    @Test("a suggestion with no quote is dropped rather than shown bare")
    func unevidencedIsDropped() {
        // A claim about a call with no quote cannot be checked, and an
        // unverifiable observation is worse than none.
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Nobody owns the vendor decision", evidence: nil)],
            summary: "")
        #expect(artefact.isEmpty)
    }

    @Test("a blank quote counts as no quote")
    func blankEvidenceIsDropped() {
        #expect(PostCallReflection.artefact(
            from: [suggestion("Nobody owns it", evidence: "   \n ")], summary: "").isEmpty)
    }

    @Test("a suggestion with no title is dropped")
    func untitledIsDropped() {
        #expect(PostCallReflection.artefact(from: [suggestion("  ")], summary: "").isEmpty)
    }

    @Test("every point removed leaves an empty artefact, not an empty section")
    func allRemovedIsEmpty() {
        // The artefact must vanish rather than render a heading with nothing
        // under it — an empty section reads as a broken feature.
        let summary = "- Maria will send the contract by Friday"
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Maria will send the contract by Friday")], summary: summary)
        #expect(artefact.isEmpty)
        #expect(artefact.duplicatesRemoved == 1)
    }

    // MARK: - Never duplicates the summary

    @Test("a point restating a summary bullet is removed")
    func removesRestatement() {
        let summary = """
        - Maria will send the client contract by Friday
        - The launch moves to September
        """
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Maria will send the client contract by Friday"),
                   suggestion("Nobody was named to own the September launch")],
            summary: summary)
        #expect(artefact.points.count == 1)
        #expect(artefact.points.first?.title == "Nobody was named to own the September launch")
    }

    @Test("a new claim about a summarised subject survives")
    func keepsNewClaimOnSameSubject() {
        // The hard case, and the one that decides whether the feature has a
        // point: the summary records the decision, the reflection says nobody
        // owns it. Removing this would gut it.
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Nobody was named to own the September launch")],
            summary: "- The launch moves to September")
        #expect(artefact.points.count == 1)
    }

    @Test("an empty summary removes nothing")
    func emptySummaryKeepsEverything() {
        // A call whose summary failed must not silently empty the reflection.
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Nobody owns the vendor decision")], summary: "")
        #expect(artefact.points.count == 1)
        #expect(artefact.duplicatesRemoved == 0)
    }

    @Test("the count of removed duplicates is reported")
    func removalCountIsVisible() {
        // So a short artefact being short is knowable rather than mysterious.
        let artefact = PostCallReflection.artefact(
            from: [suggestion("The launch moves to September"),
                   suggestion("Nobody owns the vendor decision")],
            summary: "- The launch moves to September")
        #expect(artefact.duplicatesRemoved == 1)
        #expect(artefact.points.count == 1)
    }

    // MARK: - Quotes

    @Test("each point carries its transcript quote")
    func pointsCarryQuotes() {
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Nobody owns it", evidence: "  so we'll figure that out later  ")],
            summary: "")
        #expect(artefact.points.first?.quote == "so we'll figure that out later")
    }

    @Test("the judge's ranking is preserved")
    func orderIsPreserved() {
        // The judge already ranked these. Re-sorting would discard the only
        // ordering in the system that means anything.
        let artefact = PostCallReflection.artefact(
            from: [suggestion("Alpha"), suggestion("Beta"), suggestion("Gamma")],
            summary: "")
        #expect(artefact.points.map(\.title) == ["Alpha", "Beta", "Gamma"])
    }

    // Which transcript it reads is not a decision this type makes: the local
    // whole-file pass replaces the remote side of the transcript IN PLACE, so
    // `AppState.transcriptText` already carries the better text when one exists.
    // A helper choosing between them would have been indirection over a
    // difference that does not occur.

    // MARK: - When it may run

    @Test("refuses while the call is still live")
    func refusesWhileRecording() {
        // Half a meeting produces observations the room was about to address
        // anyway — wrong-but-plausible output, which is what teaches people to
        // stop reading a feature.
        #expect(!PostCallReflection.canRun(isRecording: true,
                                           transcript: String(repeating: "x", count: 5_000)))
    }

    @Test("refuses on a call too short to have avoided anything")
    func refusesOnShortCall() {
        #expect(!PostCallReflection.canRun(isRecording: false, transcript: "hello there"))
        #expect(!PostCallReflection.canRun(isRecording: false, transcript: ""))
    }

    @Test("runs on a finished call of reasonable length")
    func runsOnFinishedCall() {
        #expect(PostCallReflection.canRun(isRecording: false,
                                          transcript: String(repeating: "word ", count: 200)))
    }

    // MARK: - Shared machinery

    @Test("uses the same dedup as the reflection module, not a second one")
    func reusesDedup() {
        // Two definitions of "the same claim" in one product drift apart, and
        // the drift is invisible until someone compares outputs.
        let title = "Maria will send the contract by Friday"
        let summary = ReflectionDedup.summaryLines(from: "- \(title)")
        #expect(ReflectionDedup.removingSummaryRestatements([title], summary: summary).isEmpty)
        #expect(PostCallReflection.artefact(from: [suggestion(title)],
                                            summary: "- \(title)").isEmpty)
    }
}

/// The reflection pass as AppState runs it.
@MainActor
@Suite("Post-call reflection in the app")
struct PostCallReflectionAppStateTests {

    private func state(recording: Bool,
                       suggestions: [Suggestion] = [],
                       fails: Bool = false) -> AppState {
        let appState = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { _ in
                if fails { throw URLError(.timedOut) }
                return BrainstormService.SuggestionResult(suggestions: suggestions, execution: nil)
            })
        appState.applyTestWorkspace(recording: recording)
        appState.transcript = [TranscriptEntry(source: .system,
                                               text: String(repeating: "word ", count: 300))]
        return appState
    }

    private func suggestion(_ title: String) -> Suggestion {
        Suggestion(title: title, detail: "d", kind: .missingInfo,
                   evidence: "we'll figure that out later")
    }

    @Test("no artefact until the pass has run")
    func noArtefactInitially() {
        #expect(state(recording: false).reflectionArtefact == nil)
    }

    @Test("refuses while the call is live")
    func refusesWhileRecording() async {
        let appState = state(recording: true, suggestions: [suggestion("Nobody owns it")])
        #expect(!appState.canRunPostCallReflection)
        await appState.runPostCallReflection()
        #expect(appState.reflectionArtefact == nil)
    }

    @Test("a finished call produces the artefact")
    func producesArtefact() async {
        let appState = state(recording: false,
                             suggestions: [suggestion("Nobody owns the vendor decision")])
        await appState.runPostCallReflection(summary: "- The launch moves to September")
        #expect(appState.reflectionArtefact?.points.count == 1)
    }

    @Test("nothing worth saying leaves no artefact at all")
    func emptyStaysNil() async {
        // Nil rather than an empty artefact: "ran and found nothing" and "never
        // ran" look the same to the UI on purpose, because both mean there is
        // nothing to show — and an empty heading reads as a broken feature.
        let appState = state(recording: false, suggestions: [])
        await appState.runPostCallReflection()
        #expect(appState.reflectionArtefact == nil)
    }

    @Test("a point restating the summary is removed before it is shown")
    func summaryDuplicateRemoved() async {
        let appState = state(recording: false,
                             suggestions: [suggestion("The launch moves to September")])
        await appState.runPostCallReflection(summary: "- The launch moves to September")
        #expect(appState.reflectionArtefact == nil)
    }

    @Test("a provider failure does not surface an error to the user")
    func failureIsSilent() async {
        // The user did not ask for this pass by name. An error about a
        // background artefact is noise, and a failed reflection is not a failed
        // call.
        let appState = state(recording: false, fails: true)
        let errorBefore = appState.lastError
        await appState.runPostCallReflection()
        #expect(appState.reflectionArtefact == nil)
        #expect(appState.lastError == errorBefore)
    }

    @Test("the running flag clears after a failure")
    func runningFlagClears() async {
        let appState = state(recording: false, fails: true)
        await appState.runPostCallReflection()
        #expect(!appState.reflectionRunning)
        #expect(appState.canRunPostCallReflection, "a failed run must not block a retry")
    }
}
