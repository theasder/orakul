import Foundation
import Testing
@testable import MeetGPT

/// Dedicated URL-protocol stub.
///
/// `MockURLProtocol` keeps its responder in a STATIC, and nine suites share it.
/// `.serialized` only orders tests *within* a suite — suites still run in
/// parallel — so this suite was reading whichever payload another suite had
/// installed (it asserted "hello server" and received "hello there" from
/// `WhisperAPITranscriptionTests`). Owning the class removes the shared slot.
/// The same hazard remains latent for the other seven sharers.
final class ServerWhisperMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let responder = ServerWhisperMockURLProtocol.responder else {
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
        config.protocolClasses = [ServerWhisperMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("Server Whisper transcription", .serialized)
struct ServerWhisperTranscriptionTests {
    @Test("missing backend URL throws before upload")
    func missingBackend() async throws {
        // When BACKEND_URL resolves empty the service fails closed. If this
        // build has a product default backend, skip — availability is covered
        // by Config.engineAvailable(.server).
        guard Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let service = ServerWhisperTranscription(
            session: ServerWhisperMockURLProtocol.session(),
            language: "en",
            tokenProvider: { "tok" }
        )
        await #expect(throws: (any Error).self) {
            _ = try await service.transcribe(wav: Data(count: 100))
        }
    }

    @Test("missing sign-in token throws before upload")
    func missingToken() async {
        let service = ServerWhisperTranscription(
            session: ServerWhisperMockURLProtocol.session(),
            language: "en",
            tokenProvider: { nil }
        )
        // Only assert when a backend is configured; otherwise the backend
        // check fires first.
        guard !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await #expect(throws: (any Error).self) {
            _ = try await service.transcribe(wav: Data(count: 100))
        }
    }

    @Test("a 200 response is decoded to trimmed text")
    func success() async throws {
        guard !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        ServerWhisperMockURLProtocol.responder = { request in
            #expect(request.url?.path.hasSuffix("/api/transcribe") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, Data(#"{"text":"  hello server  "}"#.utf8))
        }
        defer { ServerWhisperMockURLProtocol.responder = nil }
        let service = ServerWhisperTranscription(
            session: ServerWhisperMockURLProtocol.session(),
            language: "en",
            tokenProvider: { "test-token" }
        )
        let text = try await service.transcribe(wav: AudioFixtures.wav())
        #expect(text == "hello server")
    }

    @Test("factory returns the fallback-wrapped server engine")
    func factory() {
        let service = TranscriptionFactory.make(engine: .server, language: "ru")
        let typed = service as? ServerFallbackTranscription
        #expect(typed != nil)
        #expect(typed?.languageSnapshot() == "ru")
    }
}
