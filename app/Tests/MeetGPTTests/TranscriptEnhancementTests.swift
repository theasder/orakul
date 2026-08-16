import Foundation
import Testing
@testable import MeetGPT

private actor FirefliesFetchGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<FirefliesTranscript, Never>?

    func fetch() async -> FirefliesTranscript {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release(title: String = "Old call", text: String = "stale words") {
        fetchContinuation?.resume(returning: FirefliesTranscript(title: title, text: text))
        fetchContinuation = nil
    }
}

private actor FirefliesFetchCounter {
    private var count = 0

    func fetch() -> FirefliesTranscript {
        count += 1
        return FirefliesTranscript(title: "Fetched", text: "Speaker: words")
    }

    func value() -> Int { count }
}

@Suite("Transcript enhancement")
struct TranscriptEnhancementTests {

    @MainActor
    @Test("an old call Fireflies import cannot attach context to a new call")
    func staleImportCannotMutateNewCall() async {
        let gate = FirefliesFetchGate()
        let state = AppState(
            llm: MockLLMGateway(response: "unused"),
            credentialStore: InMemoryKeychain(),
            firefliesTranscriptProvider: { _, _ in await gate.fetch() })
        state.transcript = [TranscriptEntry(
            source: .system, text: "old private transcript", timestamp: Date())]
        let oldSession = state.currentSessionID

        let fetch = Task { await state.importAndEnhanceWithFireflies() }
        await gate.waitUntilStarted()
        state.resetForNewRecording()
        #expect(!state.firefliesImporting,
                "the cancelled old fetch must not leave the new call busy")
        state.transcript = [TranscriptEntry(
            source: .system, text: "new call transcript", timestamp: Date())]
        await gate.release()
        await fetch.value

        #expect(state.currentSessionID != oldSession)
        #expect(state.transcript.map(\.text) == ["new call transcript"])
        #expect(!state.contextFiles.contains(where: { $0.name.hasPrefix("Fireflies ·") }))
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test("Fireflies import is refused unless the workspace is exactly idle")
    func importRequiresIdle() async {
        let counter = FirefliesFetchCounter()
        let state = AppState(
            llm: MockLLMGateway(response: "unused"),
            credentialStore: InMemoryKeychain(),
            firefliesTranscriptProvider: { _, _ in await counter.fetch() })
        state.applyTestWorkspace(recording: true)
        state.pauseRecording()

        await state.importAndEnhanceWithFireflies()

        #expect(await counter.value() == 0)
        #expect(!state.firefliesImporting)
        #expect(!state.enhancingTranscript)
        #expect(state.contextFiles.allSatisfy { !$0.name.hasPrefix("Fireflies ·") })
    }

    @MainActor
    @Test("an old manual enhancement fetch cannot mutate a new call")
    func staleEnhancementCannotMutateNewCall() async {
        let gate = FirefliesFetchGate()
        let state = AppState(
            llm: MockLLMGateway(response: "unused"),
            credentialStore: InMemoryKeychain(),
            firefliesTranscriptProvider: { _, _ in await gate.fetch() })
        state.transcript = [TranscriptEntry(
            source: .system, text: "old private transcript", timestamp: Date())]

        state.enhanceTranscriptWithFirefliesNow()
        await gate.waitUntilStarted()
        state.resetForNewRecording()
        state.transcript = [TranscriptEntry(
            source: .system, text: "new call transcript", timestamp: Date())]
        await gate.release()
        // The provider ignores cancellation deliberately. Wait for the stale
        // task's identity guard and defer to finish.
        while state.enhancingTranscript { await Task.yield() }

        #expect(state.transcript.map(\.text) == ["new call transcript"])
        #expect(!state.contextFiles.contains(where: { $0.name.hasPrefix("Fireflies ·") }))
        #expect(state.transcriptEnhanceNote == nil)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test("Fireflies transcript mutation is eligible only at exact idle")
    func eligibilityRequiresIdle() {
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            firefliesTranscriptProvider: { _, _ in
                FirefliesTranscript(title: "test", text: "test")
            })
        state.transcript = [TranscriptEntry(
            source: .system, text: "private transcript", timestamp: Date())]

        for status: AppState.RecordingStatus in [.starting, .recording, .paused, .stopping] {
            state.status = status
            #expect(!state.canEnhanceWithFireflies)
        }
        state.status = .idle
        #expect(state.canEnhanceWithFireflies)
    }

    @Test("extractJSONObject tolerates fences and prose wrappers")
    func extractsObject() {
        let raw = """
        Sure.
        ```json
        {"summary":"ok","entries":[{"offsetSec":1,"speaker":"Ada","source":"system","text":"Hi"}]}
        ```
        """
        let json = TranscriptEnhancementService.extractJSONObject(raw)
        #expect(json?.contains("\"summary\":\"ok\"") == true)
    }

    @Test("enhance maps Fireflies+Whisper JSON into timed TranscriptEntry rows")
    func enhanceParsesEntries() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let whisper = [
            TranscriptEntry(source: .system, text: "we ship friday", timestamp: start.addingTimeInterval(12)),
            TranscriptEntry(source: .mic, text: "agreed", timestamp: start.addingTimeInterval(18), speaker: nil)
        ]
        let fireflies = FirefliesTranscript(
            title: "Sprint sync",
            text: "Ada: We ship Friday.\nYou: Agreed.")
        let llm = MockLLMGateway(response: """
        {"summary":"Aligned speakers and wording",
         "entries":[
           {"offsetSec":12,"speaker":"Ada","source":"system","text":"We ship Friday."},
           {"offsetSec":18,"speaker":"You","source":"mic","text":"Agreed."}
         ]}
        """)

        let grounding = [
            GroundingSnippet(serverName: "Notion", toolName: "notion-search",
                             text: "Project orakul ships Friday; owner Ada Lovelace.")
        ]
        let result = try await TranscriptEnhancementService.enhance(
            whisper: whisper,
            fireflies: fireflies,
            sessionStart: start,
            goal: "Ship Friday",
            grounding: grounding,
            llm: llm,
            model: LLMCatalog.model(id: "gpt-5.4-mini") ?? LLMCatalog.defaultModel(for: .free))

        #expect(llm.calls.contains(where: { $0.user.contains("SOURCE C") && $0.user.contains("orakul") }))
        #expect(result.entries.count == 2)
        #expect(result.entries[0].speaker == "Ada")
        #expect(result.entries[0].text == "We ship Friday.")
        #expect(result.entries[0].source == .system)
        #expect(abs(result.entries[0].timestamp.timeIntervalSince(start) - 12) < 0.01)
        #expect(result.entries[1].source == .mic)
        #expect(result.summary == "Aligned speakers and wording")
        #expect(result.firefliesTitle == "Sprint sync")
    }

    @Test("enhance rejects empty model payloads")
    func enhanceRejectsJunk() async {
        let start = Date()
        let llm = MockLLMGateway(response: "I cannot help with that.")
        await #expect(throws: TranscriptEnhancementError.self) {
            try await TranscriptEnhancementService.enhance(
                whisper: [TranscriptEntry(source: .system, text: "hi", timestamp: start)],
                fireflies: FirefliesTranscript(title: "x", text: "hi"),
                sessionStart: start,
                llm: llm,
                model: LLMCatalog.model(id: "gpt-5.4-mini") ?? LLMCatalog.defaultModel(for: .free))
        }
    }

    @Test("long-call merge keeps both source tails and cannot replace the full transcript")
    func longInputsKeepRecentWindowsAndArePartial() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var whisper: [TranscriptEntry] = []
        for index in 0..<180 {
            let text = index == 0
                ? "WHISPER_EARLY_SENTINEL " + String(repeating: "a", count: 100)
                : index == 179
                    ? "WHISPER_LATE_SENTINEL final words"
                    : "whisper line \(index) " + String(repeating: "a", count: 100)
            whisper.append(TranscriptEntry(
                source: .system,
                text: text,
                timestamp: start.addingTimeInterval(Double(index))))
        }
        var firefliesLines: [String] = []
        for index in 0..<220 {
            let text = index == 0
                ? "Speaker: FIREFLIES_EARLY_SENTINEL "
                    + String(repeating: "b", count: 100)
                : index == 219
                    ? "Speaker: FIREFLIES_LATE_SENTINEL final words"
                    : "Speaker: fireflies line \(index) "
                        + String(repeating: "b", count: 100)
            firefliesLines.append(text)
        }
        let llm = MockLLMGateway(response: """
        {"summary":"Merged retained windows","entries":[{"offsetSec":179,"speaker":"Speaker","source":"system","text":"final words"}]}
        """)

        let result = try await TranscriptEnhancementService.enhance(
            whisper: whisper,
            fireflies: FirefliesTranscript(
                title: "Long call",
                text: firefliesLines.joined(separator: "\n")),
            sessionStart: start,
            llm: llm,
            model: LLMCatalog.model(id: "gpt-5.4-mini")
                ?? LLMCatalog.defaultModel(for: .free))

        let prompt = try #require(llm.calls.last?.user)
        #expect(prompt.contains("WHISPER_LATE_SENTINEL"))
        #expect(prompt.contains("FIREFLIES_LATE_SENTINEL"))
        #expect(!prompt.contains("WHISPER_EARLY_SENTINEL"))
        #expect(!prompt.contains("FIREFLIES_EARLY_SENTINEL"))
        #expect(result.isPartial)
    }

    @Test("whole-line suffix drops a partial first exported row")
    func wholeLineSuffixStartsAtAFullRow() {
        let clipped = TranscriptEnhancementService.wholeLineSuffix(
            "first row\nsecond row\nthird row", maxCharacters: 18)
        #expect(clipped == "third row")
    }

    @Test("pickFirefliesMeeting prefers the listing closest to session start")
    func picksNearestMeeting() {
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)},
          {"id":"now","title":"This call","date":\(target.addingTimeInterval(120).timeIntervalSince1970)},
          {"id":"later","title":"Tomorrow","date":\(target.addingTimeInterval(86_400).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(from: list, near: target)
        #expect(pick.id == "now")
        #expect(pick.title == "This call")
    }

    @Test("a match window accepts the meeting that IS this call")
    func windowAcceptsTheSameCall() {
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)},
          {"id":"now","title":"This call","date":\(target.addingTimeInterval(120).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: list, near: target, within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == "now")
    }

    @Test("a match window rejects a call Fireflies never joined")
    func windowRejectsADifferentCall() {
        // Fireflies attends some meetings, not all. Without the window the
        // nearest-in-time rule handed this call yesterday's meeting and merged
        // another conversation's words into it.
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: list, near: target, within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == nil)
        #expect(pick.title == nil)
    }

    @Test("a match window needs dates — an undated listing is not a match")
    func windowRejectsUndatedListings() {
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: #"[{"id":"x","title":"Some meeting"}]"#,
            near: Date(),
            within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == nil)
    }
}
