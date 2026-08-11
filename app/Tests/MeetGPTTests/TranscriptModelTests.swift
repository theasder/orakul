import Foundation
import Testing
@testable import MeetGPT

@Suite("Transcript model + config")
struct TranscriptModelTests {
    @Test("speaker index maps to letters and clamps out-of-range")
    func speakerLetters() {
        #expect(AppState.speakerLetter(0) == "A")
        #expect(AppState.speakerLetter(1) == "B")
        #expect(AppState.speakerLetter(25) == "Z")
        #expect(AppState.speakerLetter(26) == "Z")
        #expect(AppState.speakerLetter(-3) == "A")
    }

    @Test("TranscriptEntry round-trips through Codable")
    func codable() throws {
        let entry = TranscriptEntry(
            source: .mic, text: "hi", speaker: "You",
            transcriptionEngine: .local)
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        #expect(back == entry)
    }

    @Test("ProvisionalLine id is its source's raw value")
    func provisionalID() {
        #expect(ProvisionalLine(source: .system, text: "x").id == "system")
        #expect(ProvisionalLine(source: .mic, text: "x").id == "mic")
    }

    @Test @MainActor func provisionalLinesOrderSystemFirstAndDropEmpty() {
        let state = AppState(transcriber: MockTranscriptionService())
        state.provisional = [.mic: "typing", .system: "hearing"]
        #expect(state.provisionalLines.map(\.source) == [.system, .mic])
        state.provisional = [.mic: "", .system: "only"]
        #expect(state.provisionalLines.map(\.source) == [.system])
    }

    @Test("transcription config resolves to sane values")
    func config() {
        #expect(Config.transcriptionChunkSeconds >= 2 && Config.transcriptionChunkSeconds <= 15)
        #expect([.local, .server, .whisper, .deepgram].contains(Config.transcriptionEngineValue))
        #expect(!Config.localWhisperModel.isEmpty)
        #expect(Config.transcriptionModel == "whisper-1")
    }
}
