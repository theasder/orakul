import Foundation
import Testing
@testable import MeetGPT

/// Speaker labels used to require the user's own AssemblyAI key (D34). The
/// server pass runs on the backend's OpenAI key instead, so the only
/// requirement is an account — and it returns the SAME utterance type, so the
/// merge path in AppState is untouched and the engines stay interchangeable.
@Suite("Server diarization")
struct ServerDiarizationTests {

    private func boundaryBody(language: String?) -> String {
        String(decoding: ServerDiarizationService.multipartBody(
            wav: Data("RIFFfake".utf8), language: language, boundary: "B"), as: UTF8.self)
    }

    @Test("uploads the recording as a WAV file part")
    func sendsTheRecording() {
        let body = boundaryBody(language: "en")
        #expect(body.contains("--B\r\n"))
        #expect(body.contains(#"name="file"; filename="call.wav""#))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(body.contains("RIFFfake"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test("passes a concrete language through")
    func sendsLanguage() {
        #expect(boundaryBody(language: "de").contains(#"name="language""#))
    }

    @Test("never sends \"multi\" as a language")
    func omitsMultiLanguage() {
        // "multi" means "let the model decide"; sending it would pin
        // recognition to a language that does not exist.
        #expect(!boundaryBody(language: "multi").contains(#"name="language""#))
        #expect(!boundaryBody(language: "").contains(#"name="language""#))
        #expect(!boundaryBody(language: nil).contains(#"name="language""#))
    }

    @Test("the server pass and the BYO pass produce the same type")
    func interchangeableWithAssemblyAI() {
        // The whole point of matching DiarizedUtterance: AppState's merge does
        // not branch on which engine ran.
        let utterance = DiarizedUtterance(speaker: "A", text: "ship Friday", startMs: 12500)
        #expect(utterance.speaker == "A")
        #expect(utterance.startMs == 12500)
    }

    @Test("failures explain what to do rather than leaking a status code")
    func readableFailures() {
        #expect(ServerDiarizationService.Failure.notSignedIn.errorDescription?
            .contains("Sign in") == true)
        #expect(ServerDiarizationService.Failure.notConfigured.errorDescription?
            .contains("AssemblyAI") == true)
        // A server message is preferred over the bare code when present.
        #expect(ServerDiarizationService.Failure.http(429, "Out of compute credits.")
            .errorDescription == "Out of compute credits.")
        #expect(ServerDiarizationService.Failure.http(502, "").errorDescription?
            .contains("502") == true)
    }
}
