import Foundation
import Testing
@testable import MeetGPT

/// Per-team custom vocabulary: the parser plus the per-engine plumbing that
/// carries it into every transcription backend (the M4 fidelity lever).
@Suite("Custom vocabulary / glossary")
struct GlossaryTests {
    // MARK: parser

    @Test("splits on newlines, commas, and semicolons; trims and drops blanks")
    func parsing() {
        let raw = "Cruxwing, RICE\nARR;  Kubernetes  \n\n"
        #expect(Glossary.terms(from: raw) == ["Cruxwing", "RICE", "ARR", "Kubernetes"])
    }

    @Test("dedupes case-insensitively, preserving first-seen order")
    func dedupe() {
        #expect(Glossary.terms(from: "ARR, arr, Arr, MRR") == ["ARR", "MRR"])
    }

    @Test("empty and whitespace-only input yields no terms and no hint")
    func empty() {
        #expect(Glossary.terms(from: "").isEmpty)
        #expect(Glossary.terms(from: "  ,\n; ").isEmpty)
        #expect(Glossary.promptHint(from: "").isEmpty)
    }

    @Test("promptHint is a comma-joined phrase of the terms")
    func hint() {
        #expect(Glossary.promptHint(from: "Cruxwing\nARR") == "Cruxwing, ARR")
    }

    @Test("caps the term count and drops overlong entries")
    func caps() {
        let many = (0..<300).map { "term\($0)" }.joined(separator: "\n")
        #expect(Glossary.terms(from: many).count == Glossary.maxTerms)
        let long = String(repeating: "x", count: Glossary.maxCharsPerTerm + 1)
        #expect(Glossary.terms(from: "ok, \(long)") == ["ok"])
    }

    // MARK: Deepgram plumbing

    @Test("Deepgram buildURL adds one keyterm query item per term")
    func deepgramKeyterms() throws {
        let url = try #require(DeepgramStreamer.buildURL(language: "multi", diarize: false,
                                                         keyterms: ["Cruxwing", "ARR"]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let keyterms = items.filter { $0.name == "keyterm" }.compactMap { $0.value }
        #expect(keyterms == ["Cruxwing", "ARR"])
    }

    @Test("Deepgram buildURL adds no keyterm items when the glossary is empty")
    func deepgramNoKeyterms() throws {
        let url = try #require(DeepgramStreamer.buildURL(language: "multi", diarize: true))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(where: { $0.name == "keyterm" }) == false)
    }

    // MARK: AssemblyAI plumbing

    @Test("AssemblyAI payload carries speaker labels, speakers-expected, and word_boost")
    func assemblyPayload() {
        let payload = AssemblyAIService.transcriptPayload(
            audioURL: "https://x/a.wav", speakersExpected: 3, keyterms: ["Cruxwing"],
            language: "multi")
        #expect(payload["speaker_labels"] as? Bool == true)
        #expect(payload["speakers_expected"] as? Int == 3)
        #expect(payload["word_boost"] as? [String] == ["Cruxwing"])
        #expect(payload["language_detection"] as? Bool == true)
        let options = payload["language_detection_options"] as? [String: Any]
        #expect(options?["code_switching"] as? Bool == true)
        #expect(options?["code_switching_confidence_threshold"] == nil)
        #expect(payload["language_code"] == nil)
    }

    @Test("AssemblyAI payload omits word_boost and speakers when unset")
    func assemblyPayloadMinimal() {
        let payload = AssemblyAIService.transcriptPayload(
            audioURL: "https://x/a.wav", speakersExpected: nil, keyterms: [],
            language: "ru")
        #expect(payload["word_boost"] == nil)
        #expect(payload["speakers_expected"] == nil)
        #expect(payload["audio_url"] as? String == "https://x/a.wav")
        #expect(payload["language_code"] as? String == "ru")
        #expect(payload["language_detection"] == nil)
        #expect(payload["language_detection_options"] == nil)
    }

    @Test("speakersExpected excludes the local user and clamps to 1–10, nil when unknown")
    func speakersExpected() {
        // Diarized track is the remote audio, so self is excluded.
        #expect(AssemblyAIService.speakersExpected(attendeeCount: 4) == 3)
        #expect(AssemblyAIService.speakersExpected(attendeeCount: 2) == 1)
        // Fewer than 2 attendees → no remote speakers to hint.
        #expect(AssemblyAIService.speakersExpected(attendeeCount: 1) == nil)
        #expect(AssemblyAIService.speakersExpected(attendeeCount: 0) == nil)
        // Clamped to AssemblyAI's ceiling.
        #expect(AssemblyAIService.speakersExpected(attendeeCount: 30) == 10)
    }
}
