import Foundation
import Testing
@testable import MeetGPT

/// Combinatorial coverage of the workspace's derived state.
///
/// The scripted end-to-end suites walk a handful of chosen paths. This walks
/// the whole reachable space of the small state machine those paths sample
/// from — every combination of the flags that gate the sidebar and the
/// assistant — and asserts the invariants that must hold in ALL of them.
///
/// Why here and not in the shell suites: a UI driver takes seconds per
/// permutation, so 2^5 combinations × several actions is a coffee break; the
/// pure derivations run in microseconds. The shell suites keep the cases that
/// genuinely need the real app (audio, launch, persistence).
@Suite("Combinatorial workspace state")
struct CombinatorialStateTests {

    /// One point in the state space. Every field is an independent axis that
    /// the UI reads, so the product of them is the space the user can reach.
    struct Point: CustomStringConvertible {
        let recording: Bool
        let hasTranscript: Bool
        let hasAnswer: Bool
        let hasHistory: Bool
        let hasTitle: Bool

        var description: String {
            "rec=\(recording) transcript=\(hasTranscript) answer=\(hasAnswer) history=\(hasHistory) title=\(hasTitle)"
        }
    }

    static var allPoints: [Point] {
        var points: [Point] = []
        for recording in [false, true] {
            for hasTranscript in [false, true] {
                for hasAnswer in [false, true] {
                    for hasHistory in [false, true] {
                        for hasTitle in [false, true] {
                            points.append(Point(recording: recording,
                                                hasTranscript: hasTranscript,
                                                hasAnswer: hasAnswer,
                                                hasHistory: hasHistory,
                                                hasTitle: hasTitle))
                        }
                    }
                }
            }
        }
        return points
    }

    @MainActor
    private func state(at point: Point) -> AppState {
        let app = AppState(credentialStore: InMemoryKeychain())
        if point.hasTranscript {
            app.ingestStreamedLine(text: "a line that was actually spoken", source: .system)
        }
        app.applyTestWorkspace(
            prompt: point.hasAnswer ? "What did we decide?" : nil,
            answer: point.hasAnswer ? "We decided to ship on Friday." : nil,
            history: point.hasHistory
                ? [AIExchange(prompt: "Earlier question?", answer: "Earlier answer.")]
                : nil,
            recording: point.recording)
        if point.hasTitle { app.meetingTitle = "Weekly sync" }
        return app
    }

    @MainActor
    @Test("every reachable state agrees on whether a new call is possible")
    func newCallGateIsConsistent() {
        for point in Self.allPoints {
            let app = state(at: point)
            let expected = !point.recording
                && (point.hasTranscript || point.hasAnswer || point.hasHistory || point.hasTitle)
            #expect(app.canStartNewCall == expected, "\(point)")
        }
    }

    @MainActor
    @Test("a new call is never offered while recording, in any state")
    func neverStartsNewCallWhileRecording() {
        // The destructive half: startNewCall clears the workspace. Offering it
        // mid-recording would discard a call in progress.
        for point in Self.allPoints where point.recording {
            #expect(state(at: point).canStartNewCall == false, "\(point)")
        }
    }

    @MainActor
    @Test("the new-call affordance is offered only while a saved call is open")
    func newCallOfferedOnlyFromHistory() {
        // The button is the way OUT of History. On the live workspace it would
        // be a clearing action parked next to the work it clears, so no
        // combination of transcript/answer/title may summon it.
        for point in Self.allPoints {
            #expect(state(at: point).shouldOfferNewCall == false,
                    "offered without opening a saved call: \(point)")
        }
    }

    @MainActor
    @Test("opening a saved call offers the way back out, and leaving withdraws it")
    func newCallAppearsAndDisappearsWithHistory() {
        let app = AppState(credentialStore: InMemoryKeychain())
        app.applyTestWorkspace(prompt: "q", answer: "an answer")
        #expect(!app.shouldOfferNewCall)

        app.restoreSession(SavedSession(
            id: UUID(), title: "Weekly sync",
            startedAt: Date(), savedAt: Date(), goal: "",
            entries: [TranscriptEntry(source: .system, text: "something said earlier")],
            aiResponse: "", digest: ""))
        #expect(app.isViewingRestoredSession)
        #expect(app.shouldOfferNewCall, "opening a saved call must offer the way back")

        app.startNewCall()
        #expect(!app.isViewingRestoredSession)
        #expect(!app.shouldOfferNewCall, "leaving History must withdraw the affordance")
    }

    @MainActor
    @Test("export is offered exactly when there is a real answer to export")
    func exportGateIsConsistent() {
        for point in Self.allPoints {
            let app = state(at: point)
            #expect(app.canExportAssistantAnswer == point.hasAnswer, "\(point)")
            #expect(app.hasContent == point.hasAnswer, "\(point)")
        }
    }

    @MainActor
    @Test("an error body is never exportable, though it is still copyable")
    func errorAnswersAreNotExportable() {
        // Error text belongs on the clipboard (a user pasting it into a bug
        // report is the point) but never in a Word document titled after the
        // meeting.
        let app = AppState(credentialStore: InMemoryKeychain())
        app.applyTestWorkspace(prompt: "q", answer: "Error: Backend API error (401): Sign in.")
        #expect(app.hasContent)
        #expect(!app.canExportAssistantAnswer)
    }

    @MainActor
    @Test("the exported dialog contains every archived turn plus the live one")
    func dialogExportIsComplete() {
        for point in Self.allPoints where point.hasAnswer && point.hasHistory {
            let app = state(at: point)
            let text = app.dialogClipboardText
            #expect(text.contains("Earlier answer."), "\(point)")
            #expect(text.contains("We decided to ship on Friday."), "\(point)")
            // Order: archived turns precede the live one.
            let earlier = text.range(of: "Earlier answer.")
            let live = text.range(of: "We decided to ship on Friday.")
            #expect(earlier!.lowerBound < live!.lowerBound, "\(point)")
        }
    }

    @MainActor
    @Test("starting a new call empties every axis it claims to clear")
    func newCallClearsTheWorkspace() {
        for point in Self.allPoints where !point.recording {
            let app = state(at: point)
            guard app.canStartNewCall else { continue }
            app.startNewCall()
            #expect(app.transcript.isEmpty, "\(point)")
            #expect(app.aiResponse.isEmpty, "\(point)")
            #expect(app.meetingTitle.isEmpty, "\(point)")
            #expect(app.copilotQuotaMessage == nil, "\(point)")
            // …and lands somewhere a new call can start FROM: nothing to
            // discard means the button is correctly off again.
            #expect(app.canStartNewCall == false, "\(point) should be inert after clearing")
        }
    }

    @MainActor
    @Test("a quota latch survives every state until a new call clears it")
    func quotaLatchIsSticky() {
        // `debugLatchQuota` is dev-only (`guard Config.isDevBuild`), so in a dist
        // build the latch never sets and every point fails on a feature that is
        // meant to be absent. Skip rather than assert the impossible — the same
        // rule DevTierOverrideTests already applies.
        guard Config.isDevBuild else { return }   // dist builds: feature absent

        for point in Self.allPoints where !point.recording {
            let app = state(at: point)
            app.debugLatchQuota(message: "Out of credits.")
            // Latching must not depend on what else is on screen.
            #expect(app.copilotQuotaMessage != nil, "\(point)")
            guard app.canStartNewCall else { continue }
            app.startNewCall()
            #expect(app.copilotQuotaMessage == nil, "\(point)")
        }
    }
}

/// Order-independence: the same set of actions in any sequence must land in the
/// same place. Non-linear navigation is where the field bugs came from — a
/// prompt sent mid-stream, a dismissal after a sync, a new call after an
/// export — so the orderings are enumerated rather than sampled.
@Suite("Action-order independence")
struct ActionOrderTests {

    enum Action: String, CaseIterable {
        case speak, ask, title, latchQuota
    }

    @MainActor
    private func apply(_ action: Action, to app: AppState) {
        switch action {
        case .speak:      app.ingestStreamedLine(text: "some spoken content here", source: .system)
        case .ask:        app.applyTestWorkspace(prompt: "q", answer: "an answer")
        case .title:      app.meetingTitle = "Weekly sync"
        case .latchQuota: app.debugLatchQuota(message: "Out of credits.")
        }
    }

    /// All 24 orderings of the four actions.
    private static var permutations: [[Action]] {
        func permute(_ remaining: [Action], _ prefix: [Action]) -> [[Action]] {
            guard !remaining.isEmpty else { return [prefix] }
            return remaining.flatMap { item -> [[Action]] in
                permute(remaining.filter { $0 != item }, prefix + [item])
            }
        }
        return permute(Action.allCases, [])
    }

    @MainActor
    @Test("the same actions in any order reach the same workspace state")
    func orderDoesNotChangeTheOutcome() {
        var seen: Set<String> = []
        for ordering in Self.permutations {
            let app = AppState(credentialStore: InMemoryKeychain())
            for action in ordering { apply(action, to: app) }
            let fingerprint = [
                "transcript=\(app.transcript.count)",
                "answer=\(app.aiResponse)",
                "title=\(app.meetingTitle)",
                "quota=\(app.copilotQuotaMessage != nil)",
                "newCall=\(app.canStartNewCall)",
                "export=\(app.canExportAssistantAnswer)",
            ].joined(separator: " ")
            seen.insert(fingerprint)
        }
        #expect(seen.count == 1,
                "orderings diverged into \(seen.count) states:\n\(seen.sorted().joined(separator: "\n"))")
    }

    @MainActor
    @Test("a new call resets every ordering to the same empty workspace")
    func newCallIsAnAbsorbingState() {
        var seen: Set<String> = []
        for ordering in Self.permutations {
            let app = AppState(credentialStore: InMemoryKeychain())
            for action in ordering { apply(action, to: app) }
            app.startNewCall()
            seen.insert([
                "transcript=\(app.transcript.count)",
                "answer=\(app.aiResponse)",
                "title=\(app.meetingTitle)",
                "quota=\(app.copilotQuotaMessage != nil)",
                "newCall=\(app.canStartNewCall)",
            ].joined(separator: " "))
        }
        #expect(seen.count == 1, "new call left \(seen.count) distinct states: \(seen)")
    }
}
