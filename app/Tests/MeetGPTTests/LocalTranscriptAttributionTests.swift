import AppKit
import Foundation
import Testing
@testable import MeetGPT

/// The private engine recognizes audio independently on the system and mic
/// capture tracks. Those tracks are useful for echo suppression, but they are
/// not speaker identities: speaker output can be picked up by both. The UI and
/// prompts must therefore stay anonymous until a real diarizer supplies a name.
@Suite("Private transcript attribution", .serialized)
struct LocalTranscriptAttributionTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Local system and mic lines never invent You or Them labels")
    func localLinesAreAnonymous() {
        let entries = [
            TranscriptEntry(
                source: .system, text: "The launch is Tuesday.", timestamp: base,
                transcriptionEngine: .local),
            TranscriptEntry(
                source: .mic, text: "Legal still needs to approve it.",
                timestamp: base.addingTimeInterval(4), transcriptionEngine: .local),
        ]

        let rendered = TranscriptTextRenderer.render(
            entries: entries, provisional: [], appearance: nil)
        #expect(!rendered.attributed.string.contains("You"))
        #expect(!rendered.attributed.string.contains("Them"))
        #expect(rendered.segments.allSatisfy { $0.speaker == nil })

        // Anonymous does not mean unusable: body ranges and exact quotes stay
        // available to the selection-driven "Ask about this" workflow.
        #expect(rendered.segments.count == 2)
        let quote = TranscriptTextRenderer.quote(
            for: rendered.segments[1].bodyRange,
            in: rendered.segments,
            fullText: rendered.attributed.string)
        #expect(quote.contains("Legal still needs to approve it."))
        #expect(quote.hasPrefix("["))
        #expect(!quote.contains("You:"))
        #expect(!quote.contains("Them:"))
    }

    @Test("real diarized labels remain visible for Instant and post-call diarization")
    func realDiarizedLabelsRemain() {
        let entries = [
            TranscriptEntry(
                source: .system, text: "Instant labeled this turn.", timestamp: base,
                speaker: "Speaker A", transcriptionEngine: .deepgram),
            // AssemblyAI/server diarization can label an entry whose original
            // live-engine provenance is absent; a real label still wins.
            TranscriptEntry(
                source: .system, text: "Post-call labeled this turn.",
                timestamp: base.addingTimeInterval(3), speaker: "Speaker B"),
        ]
        let rendered = TranscriptTextRenderer.render(
            entries: entries, provisional: [], appearance: nil)

        #expect(rendered.segments.map(\.speaker) == ["Speaker A", "Speaker B"])
        #expect(rendered.attributed.string.contains("Speaker A"))
        #expect(rendered.attributed.string.contains("Speaker B"))
    }

    @Test("private prompts use neutral audio provenance")
    func promptsDoNotInventSourceIdentity() {
        let local = TranscriptEntry(
            source: .mic, text: "One person is presenting.", timestamp: base,
            transcriptionEngine: .local)
        let instant = TranscriptEntry(
            source: .system, text: "A diarized reply.",
            timestamp: base.addingTimeInterval(2), speaker: "Speaker A",
            transcriptionEngine: .deepgram)
        let text = SystemInstructions.formatEntries([local, instant])

        #expect(text.contains("][audio] One person is presenting."))
        #expect(!text.contains("][mic] One person is presenting."))
        #expect(text.contains("][system] Speaker A: A diarized reply."))
    }

    @Test("private export omits false speakers but keeps timestamps and text")
    func exportStaysAnonymous() {
        let entries = [
            TranscriptEntry(
                source: .system, text: "Only one person is speaking.", timestamp: base,
                transcriptionEngine: .local),
            TranscriptEntry(
                source: .system, text: "A labeled cloud turn.",
                timestamp: base.addingTimeInterval(2), speaker: "Speaker A",
                transcriptionEngine: .deepgram),
        ]
        let output = TranscriptExporter.plainText(
            title: "Private call", date: base, entries: entries,
            timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(output.contains("Only one person is speaking."))
        #expect(!output.contains("You: Only one person"))
        #expect(!output.contains("Them: Only one person"))
        #expect(output.contains("Speaker A: A labeled cloud turn."))
    }
}

@MainActor
@Suite("Private transcript capture pipeline", .serialized)
struct LocalTranscriptCapturePipelineTests {
    private let cumulativeRussianEcho = """
    Сегодня мы обсудим архитектуру новой платформы. Сначала проверим интеграцию \
    с системой платежей. Затем согласуем сроки запуска с командой.
    """

    private func instantStateWithRussianFinals() -> AppState {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.ingestStreamedLine(
            text: "Сегодня мы обсудим архитектуру новой платформы.",
            source: .system, speaker: "Speaker A", transcriptionEngine: .deepgram)
        state.ingestStreamedLine(
            text: "Сначала проверим интеграцию с системой платежей.",
            source: .system, speaker: "Speaker A", transcriptionEngine: .deepgram)
        state.ingestStreamedLine(
            text: "Затем согласуем сроки запуска с командой.",
            source: .system, speaker: "Speaker A", transcriptionEngine: .deepgram)
        return state
    }

    @Test("one utterance reaching Local system and mic tracks is kept once")
    func crossTrackEchoIsOneEntry() {
        let saved = Config.transcriptDeduplicationEnabled
        defer { Config.transcriptDeduplicationEnabled = saved }
        Config.transcriptDeduplicationEnabled = true

        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.ingestStreamedLine(
            text: "we need legal to look at the liability cap before signing",
            source: .system, transcriptionEngine: .local)
        state.ingestStreamedLine(
            text: "we need legal to look at that liability cap before we sign",
            source: .mic, transcriptionEngine: .local)

        #expect(state.transcript.count == 1)
        #expect(state.transcript[0].transcriptionEngine == .local)
        #expect(state.transcript[0].attributionLabel == nil)
    }

    @Test("genuinely different Local speech on the two tracks is preserved")
    func distinctCrossTrackSpeechSurvives() {
        let saved = Config.transcriptDeduplicationEnabled
        defer { Config.transcriptDeduplicationEnabled = saved }
        Config.transcriptDeduplicationEnabled = true

        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.ingestStreamedLine(
            text: "can we push the launch to the following Tuesday",
            source: .system, transcriptionEngine: .local)
        state.ingestStreamedLine(
            text: "I still need legal to sign off on the data clause",
            source: .mic, transcriptionEngine: .local)

        #expect(state.transcript.count == 2)
        #expect(state.transcript.map(\.text) == [
            "can we push the launch to the following Tuesday",
            "I still need legal to sign off on the data clause",
        ])
        #expect(state.transcript.allSatisfy { $0.attributionLabel == nil })
    }

    @Test("Instant cumulative mic final does not create a giant false You block")
    func instantCumulativeFinalIsDropped() {
        let saved = Config.transcriptDeduplicationEnabled
        defer { Config.transcriptDeduplicationEnabled = saved }
        Config.transcriptDeduplicationEnabled = true
        let state = instantStateWithRussianFinals()

        state.ingestStreamedLine(
            text: cumulativeRussianEcho, source: .mic,
            transcriptionEngine: .deepgram)

        #expect(state.transcript.count == 3)
        #expect(state.transcript.allSatisfy { $0.source == .system })
        let rendered = TranscriptTextRenderer.render(
            entries: state.transcript, provisional: [], appearance: nil)
        #expect(!rendered.attributed.string.contains("You"))
        #expect(rendered.attributed.string.contains("Speaker A"))
    }

    @Test("Instant cumulative mic interim is hidden, then exposes only novel speech")
    func instantCumulativeInterimIsFiltered() {
        let state = instantStateWithRussianFinals()

        state.applyTestProvisionalLine(cumulativeRussianEcho, source: .mic)
        #expect(state.provisionalLines.isEmpty)

        state.applyTestProvisionalLine(
            cumulativeRussianEcho + " Но я хочу уточнить план отката.",
            source: .mic)
        #expect(state.provisionalLines.count == 1)
        #expect(state.provisionalLines[0].source == .mic)
        #expect(state.provisionalLines[0].text == "Но я хочу уточнить план отката.")
    }

    @Test("Instant cumulative final keeps only a genuinely novel user suffix")
    func instantFinalKeepsNovelSuffix() {
        let state = instantStateWithRussianFinals()

        state.ingestStreamedLine(
            text: cumulativeRussianEcho + " Но я хочу уточнить план отката.",
            source: .mic, transcriptionEngine: .deepgram)

        #expect(state.transcript.count == 4)
        #expect(state.transcript.last?.text == "Но я хочу уточнить план отката.")
        #expect(state.transcript.last?.source == .mic)
        #expect(state.transcript.last?.attributionLabel == "You")
    }

    @Test("restoring a saved Local session applies session provenance to legacy entries")
    func restoredLocalSessionStaysAnonymous() {
        let legacyEntry = TranscriptEntry(
            source: .mic, text: "Saved before per-line provenance existed.")
        let session = SavedSession(
            id: UUID(), title: "Private history", startedAt: Date(), savedAt: Date(),
            goal: "", entries: [legacyEntry], transcriptionEngine: .local,
            aiResponse: "", digest: "")
        let state = AppState(credentialStore: InMemoryKeychain())

        state.restoreSession(session)

        #expect(state.transcript.count == 1)
        #expect(state.transcript[0].id == legacyEntry.id)
        #expect(state.transcript[0].transcriptionEngine == .local)
        #expect(state.transcript[0].attributionLabel == nil)
    }
}
