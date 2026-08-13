import Foundation
import Testing
@testable import MeetGPT

@Suite("Recording context classification")
struct RecordingContextDetectorTests {
    @Test("media-host titles beat meeting words inside a tutorial title")
    func youtubeTutorialBeatsZoomWords() {
        let kind = RecordingContextDetector.infer(windowTitles: [
            "How to implement Zoom meeting webhooks — complete tutorial - YouTube",
        ])
        #expect(kind == .tutorial)
    }

    @Test("an unmarked media title no longer falls into a catch-all")
    func unmarkedMediaTitle() {
        let kind = RecordingContextDetector.infer(windowTitles: [
            "A quiet train journey across Norway - YouTube",
        ])
        // `.video` used to absorb every media title without a marker word,
        // which is most real titles, so "automatic" reported it constantly
        // while saying nothing about how to treat the content. `.lecture` at
        // least carries instructions: organise concepts and evidence, and do
        // not invent meeting decisions or owners.
        #expect(kind == .lecture)
    }

    @Test("learning platforms and technical markers classify tutorials", arguments: [
        "Swift concurrency course | Udemy",
        "Step by step Postgres replication | Coursera",
        "Kubernetes implementation workshop | Pluralsight",
    ])
    func learningPlatforms(title: String) {
        #expect(RecordingContextDetector.infer(windowTitles: [title]) == .tutorial)
    }

    @Test("non-browser media apps classify playback without relying on a title", arguments: [
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
    ])
    func localVideoPlayers(bundleID: String) {
        #expect(RecordingContextDetector.infer(
            windowTitles: [], bundleIdentifiers: [bundleID]) == .lecture)
    }

    @Test("specialized spoken formats are distinguished", arguments: [
        ("Architecture podcast episode 42", RecordingContextKind.podcast),
        ("Interview with the database team", .interview),
        ("Distributed systems lecture 7", .lecture),
        ("New product demo day", .presentation),
    ])
    func specializedTitles(title: String, expected: RecordingContextKind) {
        #expect(RecordingContextDetector.infer(windowTitles: [title]) == expected)
    }

    @Test("unknown and ordinary call sources preserve the meeting default")
    func compatibilityDefault() {
        #expect(RecordingContextDetector.infer(windowTitles: []) == .meeting)
        #expect(RecordingContextDetector.infer(
            windowTitles: ["Weekly planning — Google Meet"]) == .meeting)
    }
}

@Suite("Recording context re-probing")
struct RecordingContextProbeScheduleTests {
    @Test("the fallback answer is worth re-checking — the real source often opens after Record")
    func keepsProbingWhileTheAnswerIsTheFallback() {
        // .meeting is both a real answer and the "no signal" fallback, so it is
        // the only result that justifies looking again.
        #expect(RecordingContextDetector.shouldProbeAgain(
            after: .meeting, manualOverride: false))
    }

    @Test("a positive identification ends the probing")
    func stopsOnceSomethingWasIdentified() {
        for kind in RecordingContextKind.allCases where kind != .meeting {
            #expect(!RecordingContextDetector.shouldProbeAgain(
                after: kind, manualOverride: false))
        }
    }

    @Test("a manual choice ends the probing even when nothing was identified")
    func stopsOnManualOverride() {
        #expect(!RecordingContextDetector.shouldProbeAgain(
            after: .meeting, manualOverride: true))
    }

    @Test("the schedule stays inside the opening of a recording")
    func scheduleIsBoundedAndAscending() {
        let delays = RecordingContextDetector.visibleContextProbeDelays
        #expect(!delays.isEmpty)
        // Bounded on purpose: this covers "hit Record, then open the thing you
        // are recording", not the whole call. An unbounded watch would keep
        // calling ScreenCaptureKit for hours to answer a question the user can
        // settle with one click.
        #expect(delays.reduce(0, +) <= 90)
        #expect(delays == delays.sorted())
        #expect(delays.allSatisfy { $0 > 0 })
    }
}

@Suite("Manual recording context")
struct RecordingContextSelectionTests {
    @Test("a manual preset always overrides a changing automatic guess")
    func presetOverrideWins() {
        let selection = RecordingContextSelection(mode: .tutorial)
        #expect(selection.resolvedKind(detected: .meeting) == .tutorial)
        #expect(selection.resolvedKind(detected: .podcast) == .tutorial)
        #expect(selection.resolvedLabel(detected: .lecture) == "Tutorial")
    }

    @Test("automatic follows the newest detected context")
    func automaticFollowsDetection() {
        let selection = RecordingContextSelection.automatic
        #expect(selection.resolvedKind(detected: .meeting) == .meeting)
        #expect(selection.resolvedKind(detected: .lecture) == .lecture)
    }

    @Test("custom input collapses whitespace and is bounded")
    func customSanitization() {
        let long = "  Internal   architecture\nreview  "
            + String(repeating: "x", count: 200)
        let selection = RecordingContextSelection(mode: .custom, customLabel: long)
        let label = selection.resolvedLabel(detected: .meeting)
        #expect(!label.contains("\n"))
        #expect(!label.contains("  "))
        #expect(label.count == RecordingContextSelection.maximumCustomLabelLength)
    }

    @Test("blank custom input has a safe non-meeting fallback")
    func blankCustomInput() {
        let selection = RecordingContextSelection(mode: .custom, customLabel: " \n ")
        #expect(selection.resolvedLabel(detected: .meeting) == "Other recording")
        #expect(selection.promptGuidance(detected: .meeting).contains("do not assume it is a meeting"))
    }

    @Test("tutorial guidance is compact and project-oriented")
    func tutorialPromptGuidance() {
        let guidance = RecordingContextSelection(mode: .tutorial)
            .promptGuidance(detected: .meeting)
        #expect(guidance.contains("implementation steps"))
        #expect(guidance.contains("project context"))
        #expect(guidance.contains("Do not invent meeting participants"))
        #expect(guidance.count < 420)
    }

    @Test("all presets provide a bounded label, symbol, and orientation")
    func presetMatrix() {
        for kind in RecordingContextKind.allCases {
            let mode = RecordingContextSelection.Mode(rawValue: kind.rawValue)
            #expect(mode != nil)
            let selection = RecordingContextSelection(mode: mode!)
            #expect(!selection.resolvedLabel(detected: .meeting).isEmpty)
            #expect(!selection.resolvedSymbol(detected: .meeting).isEmpty)
            #expect(selection.promptGuidance(detected: .meeting).count < 520)
        }
    }

    @Test("recording guidance is placed before transcript and request")
    func userMessageOrientation() {
        let guidance = RecordingContextSelection(mode: .tutorial)
            .promptGuidance(detected: .meeting)
        let message = SystemInstructions.buildUserMessage(
            transcript: [], additionalContext: "Project uses Swift concurrency",
            prompt: "How should I implement this?", recordingContext: guidance)
        #expect(message.hasPrefix("Recording type: Tutorial."))
        #expect(message.firstRange(of: "Recording type:")!.lowerBound
                < message.firstRange(of: "Transcript:")!.lowerBound)
        #expect(message.contains("How should I implement this?"))
    }
}

@Suite("Recording-aware quick prompts")
struct RecordingPromptAdapterTests {
    private func prompt(_ id: String) -> QuickPrompt {
        QuickPrompts.all.first { $0.id == id }!
    }

    @Test("meeting shortcuts remain byte-for-byte compatible")
    func meetingCompatibility() {
        for original in QuickPrompts.all {
            #expect(RecordingPromptAdapter.adapt(original, kind: .meeting) == original)
        }
    }

    @Test("media shortcuts do not demand fictional meeting artifacts", arguments: [
        "summary", "agenda", "whattoask", "answer", "advice", "tasks",
        "logdecision", "commitments",
    ])
    func mediaPromptSafety(id: String) {
        let adapted = RecordingPromptAdapter.adapt(prompt(id), kind: .tutorial)
        #expect(adapted.prompt != prompt(id).prompt)
        #expect(!adapted.title.isEmpty)
        #expect(!adapted.prompt.lowercased().contains("proposed agenda & date"))
        #expect(!adapted.prompt.lowercased().contains("file it into the decision ledger"))
        #expect(adapted.prompt.count < 1_000)
    }

    @Test("summary and advice explicitly connect tutorials to project context")
    func projectApplicationPrompts() {
        let summary = RecordingPromptAdapter.adapt(prompt("summary"), kind: .tutorial)
        let advice = RecordingPromptAdapter.adapt(prompt("advice"), kind: .tutorial)
        #expect(summary.prompt.contains("attached project context"))
        #expect(advice.title == "Apply to Project")
        #expect(advice.prompt.contains("validation"))
        #expect(advice.prompt.contains("rollback"))
    }

    @Test("the composer template menu uses the same recording-aware prompts")
    func composerTemplateMenuUsesAdaptedPrompts() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/MeetGPT/Views/AIStudioView.swift"),
            encoding: .utf8)
        #expect(source.contains(
            "QuickPrompts.all.map { state.promptForCurrentRecording($0) }"))
    }
}

@MainActor
@Suite("Recording context lifecycle", .serialized)
struct RecordingContextLifecycleTests {
    @Test("manual type changes during recording without changing capture state")
    func midRecordingOverride() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let sessionID = state.currentSessionID
        state.status = .recording

        state.selectRecordingContext(.tutorial)
        state.applyDetectedRecordingContext(.lecture, for: sessionID)

        #expect(state.status == .recording)
        #expect(state.currentSessionID == sessionID)
        #expect(state.recordingContextSelection.mode == .tutorial)
        #expect(state.detectedRecordingContext == .lecture)
        // Подпись на экране — русская; в промпт уходит английский `label`,
        // и его проверяют отдельные тесты ниже.
        #expect(state.effectiveRecordingContextLabel == "Разбор")
        let summary = state.promptForCurrentRecording(
            QuickPrompts.all.first { $0.id == "summary" }!)
        #expect(summary.title == "Summarize Tutorial")
    }

    @Test("a fresh workspace reports that nothing has been detected yet")
    func detectionIsNotClaimedBeforeItRuns() {
        // The chip reads "Auto · Meeting" from the same default the detector
        // falls back to, so before the first probe it would present a guess as
        // a finding. This flag is what lets the chip say "Определять автоматически" instead.
        let state = AppState(credentialStore: InMemoryKeychain())
        #expect(!state.hasDetectedRecordingContext)

        // Re-detecting the default still counts as having looked.
        state.applyDetectedRecordingContext(.meeting, for: state.currentSessionID)
        #expect(state.hasDetectedRecordingContext)
        #expect(state.detectedRecordingContext == .meeting)
    }

    @Test("a new call forgets that the previous one was identified")
    func detectionFlagResetsWithTheCall() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyDetectedRecordingContext(.podcast, for: state.currentSessionID)
        #expect(state.hasDetectedRecordingContext)

        state.startNewCall()
        #expect(!state.hasDetectedRecordingContext)
        #expect(state.detectedRecordingContext == .meeting)
    }

    @Test("stale detector result from a previous call is ignored")
    func staleDetectionIgnored() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let staleID = UUID()
        state.applyDetectedRecordingContext(.podcast, for: staleID)
        #expect(state.detectedRecordingContext == .meeting)
    }

    @Test("saved sessions restore an explicit recording type")
    func persistenceRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let entry = TranscriptEntry(
            source: .system, text: "First configure the retry policy.",
            timestamp: Date(), transcriptionEngine: .deepgram)
        let saved = SavedSession(
            id: UUID(), title: "Gateway tutorial - YouTube",
            startedAt: Date(), savedAt: Date(), goal: "Implement retries",
            recordingContext: RecordingContextSelection(mode: .tutorial),
            entries: [entry], aiResponse: "", digest: "")
        try store.save(saved)

        let state = AppState(
            credentialStore: InMemoryKeychain(), sessionStore: store)
        state.restoreSession(try #require(store.load(id: saved.id)))

        #expect(state.recordingContextSelection.mode == .tutorial)
        // Подпись на экране — русская; в промпт уходит английский `label`,
        // и его проверяют отдельные тесты ниже.
        #expect(state.effectiveRecordingContextLabel == "Разбор")
    }
    // MARK: - The retired catch-all

    @Test("no automatic detection can return the retired kind")
    func retiredKindIsUnreachable() {
        // `.video` is gone from RecordingContextKind entirely, so this is a
        // compile-time guarantee for the kind. What is worth asserting is that
        // nothing in the detector produces a type the picker cannot show.
        let titles = ["A quiet train journey across Norway - YouTube",
                      "Vimeo — untitled upload", "Something on Udemy",
                      "random window", ""]
        for title in titles {
            let kind = RecordingContextDetector.infer(windowTitles: [title])
            #expect(RecordingContextKind.allCases.contains(kind), "\(title)")
        }
    }

    @Test("a session saved with the retired mode still decodes and maps forward")
    func retiredModeStillDecodes() throws {
        // Removing the case outright would fail the whole session decode, not
        // just this field, and take the transcript with it.
        let json = Data(#"{"mode":"video"}"#.utf8)
        let selection = try JSONDecoder().decode(RecordingContextSelection.self, from: json)

        #expect(selection.mode == .video)
        #expect(selection.mode.preset == .lecture)
        #expect(selection.resolvedKind(detected: .meeting) == .lecture)
    }

    @Test("the picker offers every kind, and every kind it offers works")
    func pickerRowsAllResolve() {
        // The menu is built from RecordingContextKind.allCases and maps each
        // row back through Mode(rawValue:). A kind with no matching Mode would
        // render a row that silently does nothing when clicked.
        for kind in RecordingContextKind.allCases {
            let mode = RecordingContextSelection.Mode(rawValue: kind.rawValue)
            #expect(mode != nil, "\(kind) has no selectable mode")
            #expect(mode?.preset == kind, "\(kind) does not round-trip")
        }
        #expect(!RecordingContextKind.allCases.map(\.rawValue).contains("video"))
    }

    @Test("a manual choice still beats detection")
    func manualBeatsDetection() {
        // The reason detection being wrong was survivable: the user can always
        // override. That has to keep working now that the fallback changed.
        let chosen = RecordingContextSelection(mode: .meeting)
        #expect(chosen.resolvedKind(detected: .lecture) == .meeting)
    }

    @Test("meeting apps are never reclassified as content", arguments: [
        "us.zoom.xos", "com.microsoft.teams2", "com.google.Chrome",
    ])
    func meetingAppsStayMeetings(bundleID: String) {
        // The failure that matters in the other direction: filing a real call
        // as content would drop participants, decisions and owners from every
        // answer about it.
        #expect(RecordingContextDetector.infer(
            windowTitles: ["Weekly sync"], bundleIdentifiers: [bundleID]) == .meeting)
    }

}
