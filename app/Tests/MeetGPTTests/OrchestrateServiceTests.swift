import Foundation
import Testing
@testable import MeetGPT

/// Intercepts URLSession for OrchestrateService so its SSE parsing, delta
/// emission, and error mapping are tested without a network. Own static state +
/// a serialized suite keep the shared responder race-free.
final class OrchestrateMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession strips the httpBody from the forwarded request; capture the
        // stream instead so tests can assert the payload.
        OrchestrateMockURLProtocol.lastBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                return data
            }
        guard let responder = OrchestrateMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrchestrateMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private func sse(_ payloads: [String]) -> Data {
    Data((payloads.map { "data: \($0)" }.joined(separator: "\n\n") + "\n").utf8)
}

@Suite("OrchestrateService", .serialized)
struct OrchestrateServiceTests {
    private func withResponder(_ status: Int, _ body: Data, _ run: () async throws -> Void) async rethrows {
        OrchestrateMockURLProtocol.responder = { _ in (status, body) }
        defer { OrchestrateMockURLProtocol.responder = nil; OrchestrateMockURLProtocol.lastBody = nil }
        try await run()
    }

    @Test("streams the council deltas and stops at [DONE]")
    func streamsDeltas() async throws {
        let body = sse([
            #"{"delta":"The panel "}"#,
            #"{"delta":"agrees."}"#,
            "[DONE]",
            #"{"delta":"ignored after done"}"#,
        ])
        try await withResponder(200, body) {
            let log = DeltaLog()
            let text = try await OrchestrateService.stream(
                level: "ultra", system: "S", user: "Q", baseURL: "https://api.example.com",
                session: OrchestrateMockURLProtocol.session()) { log.append($0) }
            #expect(text == "The panel agrees.")
            #expect(log.deltas == ["The panel ", "agrees."])
        }
    }

    @Test("sends level/system/user to /api/orchestrate")
    func sendsPayload() async throws {
        try await withResponder(200, sse(["[DONE]"])) {
            _ = try await OrchestrateService.stream(
                level: "max", system: "sys", user: "usr", baseURL: "https://api.example.com",
                session: OrchestrateMockURLProtocol.session()) { _ in }
            let body = try #require(OrchestrateMockURLProtocol.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["level"] as? String == "max")
            #expect(json["system"] as? String == "sys")
            #expect(json["user"] as? String == "usr")
        }
    }

    @Test("maps the server tier-gate 403 to an LLMError")
    func tierGate403() async throws {
        let body = Data(#"{"error":"The ultra council needs the ultra plan.","upgrade":true}"#.utf8)
        try await withResponder(403, body) {
            await #expect(throws: (any Error).self) {
                _ = try await OrchestrateService.stream(
                    level: "ultra", system: "S", user: "Q", baseURL: "https://api.example.com",
                    session: OrchestrateMockURLProtocol.session()) { _ in }
            }
        }
    }

    @Test("throws on a mid-stream error record")
    func midStreamError() async throws {
        let body = sse([
            #"{"delta":"partial"}"#,
            #"{"error":"a member died"}"#,
        ])
        try await withResponder(200, body) {
            await #expect(throws: (any Error).self) {
                _ = try await OrchestrateService.stream(
                    level: "ultra", system: "S", user: "Q", baseURL: "https://api.example.com",
                    session: OrchestrateMockURLProtocol.session()) { _ in }
            }
        }
    }
}
