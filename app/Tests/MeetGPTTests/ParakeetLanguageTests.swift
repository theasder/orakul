import Foundation
import Testing
@testable import MeetGPT

/// Gating for the experimental Parakeet live-caption lane.
///
/// The rule under test: Parakeet serves ONLY an explicitly chosen language it
/// covers, only behind the flag. Everything else — the flag off, "multi"
/// auto-detect, a language outside its 25 — stays on Whisper, because the
/// cost of a wrong gate is a live call transcribed by a model that cannot
/// hear it.
@Suite("Parakeet language gating")
struct ParakeetLanguageTests {

    @Test("serves a covered language only when the flag is on")
    func flagGates() {
        #expect(ParakeetLiveTranscription.shouldServe(language: "ru", enabled: true))
        #expect(!ParakeetLiveTranscription.shouldServe(language: "ru", enabled: false))
    }

    @Test("auto-detect never lands on Parakeet")
    func multiStaysOnWhisper() {
        #expect(!ParakeetLiveTranscription.shouldServe(language: "multi", enabled: true))
    }

    @Test("languages outside the training set stay on Whisper")
    func uncoveredLanguagesFallBack() {
        for language in ["hi", "zh", "ja", "ko", "th", "ar", "he", "id"] {
            #expect(!ParakeetLiveTranscription.shouldServe(language: language, enabled: true),
                    "\(language) is not a Parakeet v3 language")
        }
    }

    @Test("case and whitespace are forgiven, coverage is broad European")
    func normalisation() {
        #expect(ParakeetLiveTranscription.shouldServe(language: " RU ", enabled: true))
        for language in ["en", "de", "fr", "es", "it", "pl", "nl", "pt", "uk", "cs"] {
            #expect(ParakeetLiveTranscription.shouldServe(language: language, enabled: true))
        }
    }

    /// Downloads the ~600 MB v3 model on first run and transcribes a real
    /// window through the exact shipped path (wav → floatSamples → stateful
    /// runtime with the language hint). Env-gated: this is a smoke run, not
    /// a unit test, and CI must never fetch half a gigabyte.
    ///
    ///   CRUXWING_PARAKEET_SMOKE=1 \
    ///   CRUXWING_PARAKEET_SMOKE_WAV=/path/to/window.wav \
    ///   CRUXWING_PARAKEET_SMOKE_LANG=ru \
    ///   swift test --filter smokeRealAudio
    @Test("smoke: model download and a real window through the shipped path",
          .enabled(if: ProcessInfo.processInfo.environment["CRUXWING_PARAKEET_SMOKE"] == "1"),
          .timeLimit(.minutes(30)))
    func smokeRealAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CRUXWING_PARAKEET_SMOKE_WAV"] ?? ""
        let language = environment["CRUXWING_PARAKEET_SMOKE_LANG"] ?? "ru"
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))

        let service = ParakeetLiveTranscription(language: language)
        let began = Date()
        let text = try await service.transcribe(wav: wav, streamID: "smoke:\(language)")
        let elapsed = Date().timeIntervalSince(began)

        print("[parakeet-smoke] \(String(format: "%.1f", elapsed))s "
              + "(incl. any model download), \(text.split(separator: " ").count) words")
        print("[parakeet-smoke] \(text.prefix(600))")
        #expect(!text.isEmpty, "a five-minute speech window must not transcribe to nothing")
    }
}
