import Foundation
import Testing
@testable import MeetGPT

/// Intercepts URLSession so the API engine's success + error mapping can be
/// tested without hitting OpenAI.
final class MockURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("Whisper API transcription", .serialized)
struct WhisperAPITranscriptionTests {
    @Test("Auto omits the language field while fixed mode sends it")
    func languageRouting() {
        #expect(WhisperAPITranscription.languageField("multi") == nil)
        #expect(WhisperAPITranscription.languageField("") == nil)
        #expect(WhisperAPITranscription.languageField("  ") == nil)
        #expect(WhisperAPITranscription.languageField("ru") == "ru")
    }

    @Test("a missing key throws before any upload")
    func missingKey() async {
        let service = WhisperAPITranscription(session: MockURLProtocol.session(), apiKey: "", model: "whisper-1")
        await #expect(throws: (any Error).self) {
            _ = try await service.transcribe(wav: Data(count: 100))
        }
    }

    @Test("oversize audio is rejected before upload")
    func oversize() async {
        let service = WhisperAPITranscription(session: MockURLProtocol.session(), apiKey: "sk-test", model: "whisper-1")
        await #expect(throws: (any Error).self) {
            _ = try await service.transcribe(wav: Data(count: 26 * 1024 * 1024))
        }
    }

    @Test("a 200 response is decoded to trimmed text")
    func success() async throws {
        MockURLProtocol.responder = { _ in (200, Data(#"{"text":"  hello there  "}"#.utf8)) }
        defer { MockURLProtocol.responder = nil }
        let service = WhisperAPITranscription(session: MockURLProtocol.session(), apiKey: "sk-test", model: "whisper-1")
        let text = try await service.transcribe(wav: AudioFixtures.wav())
        #expect(text == "hello there")
    }

    @Test("a non-2xx response throws")
    func serverError() async {
        MockURLProtocol.responder = { _ in (401, Data(#"{"error":"bad key"}"#.utf8)) }
        defer { MockURLProtocol.responder = nil }
        let service = WhisperAPITranscription(session: MockURLProtocol.session(), apiKey: "sk-test", model: "whisper-1")
        await #expect(throws: (any Error).self) {
            _ = try await service.transcribe(wav: AudioFixtures.wav())
        }
    }
}
