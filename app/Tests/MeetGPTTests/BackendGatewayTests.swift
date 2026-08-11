import Foundation
import Testing
@testable import MeetGPT

/// Deterministic transport for BackendGateway. It captures the request before
/// returning a complete SSE byte stream, a non-HTTP response, or a URL error.
/// The suite is serialized because URLProtocol's responder is shared static
/// state and URLSession invokes it on its own queue.
final class BackendGatewayMockURLProtocol: URLProtocol {
    enum Outcome {
        case response(status: Int, body: Data)
        case responseChunks(status: Int, chunks: [Data])
        case nonHTTP(body: Data)
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var outcome: Outcome?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)

        guard let outcome = Self.outcome else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch outcome {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .responseChunks(let status, let chunks):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .nonHTTP(let body):
            let response = URLResponse(
                url: request.url!, mimeType: "text/plain",
                expectedContentLength: body.count, textEncodingName: "utf-8")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendGatewayMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        outcome = nil
        lastRequest = nil
        lastBody = nil
    }
}

private func backendSSE(_ payloads: [String]) -> Data {
    Data((payloads.map { "data: \($0)" }.joined(separator: "\n\n") + "\n").utf8)
}

@Suite("Backend gateway", .serialized)
struct BackendGatewayTests {
    private let model = LLMModel(
        id: "gpt-5.4-mini", label: "GPT-5.4 mini", provider: .openAI,
        minTier: .free, supportsVision: true)

    private func gateway(baseURL: String = "https://api.example.test/",
                         timeout: TimeInterval = 120,
                         token: String? = nil) -> BackendGateway {
        BackendGateway(
            session: BackendGatewayMockURLProtocol.session(),
            baseURL: baseURL,
            requestTimeout: timeout,
            tokenProvider: { token })
    }

    private func withOutcome<T>(
        _ outcome: BackendGatewayMockURLProtocol.Outcome,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        BackendGatewayMockURLProtocol.outcome = outcome
        defer { BackendGatewayMockURLProtocol.reset() }
        return try await operation()
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(BackendGatewayMockURLProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func expectHTTPError(
        _ operation: () async throws -> Void
    ) async -> (provider: String, status: Int, body: String)? {
        do {
            try await operation()
            Issue.record("expected an HTTP error")
            return nil
        } catch let error as LLMError {
            guard case .http(let provider, let status, let body) = error else {
                Issue.record("expected LLMError.http, got \(error)")
                return nil
            }
            return (provider, status, body)
        } catch {
            Issue.record("expected LLMError.http, got \(error)")
            return nil
        }
    }

    // MARK: - Request contract and bounds

    @Test("bespoke background routes share guarded dev-tier headers and server-deadline headroom")
    func managedBackgroundRequestPolicy() throws {
        let url = try #require(URL(string: "https://api.example.test/api/brainstorm"))
        let brainstorm = BrainstormService.managedRequest(
            url: url, accessToken: "  token-a  ", devTierOverride: .premium)
        #expect(brainstorm.httpMethod == "POST")
        #expect(brainstorm.timeoutInterval == ManagedBackendRequestPolicy.backgroundRequestTimeout)
        #expect(brainstorm.timeoutInterval == 90)
        #expect(brainstorm.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(brainstorm.value(forHTTPHeaderField: "Authorization") == "Bearer token-a")
        #expect(brainstorm.value(forHTTPHeaderField: "X-Dev-Tier") == "premium")

        let factCheck = FactCheckService.managedRequest(
            url: url, accessToken: "   ", devTierOverride: nil)
        #expect(factCheck.timeoutInterval == 90)
        #expect(factCheck.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(factCheck.value(forHTTPHeaderField: "X-Dev-Tier") == nil)
    }

    @Test("POSTs the bounded chat payload, images, auth, and injected timeout")
    func requestContract() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        try await withOutcome(.response(status: 200, body: backendSSE(["[DONE]"]))) {
            _ = try await gateway(timeout: 7.5, token: "test-bearer").streamChat(
                system: "system rules", user: "user question", images: [png, jpeg],
                model: model, maxOutputTokens: nil) { _ in }

            let request = try #require(BackendGatewayMockURLProtocol.lastRequest)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://api.example.test/api/llm/chat")
            #expect(request.timeoutInterval == 7.5)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")

            let json = try bodyJSON()
            #expect(json["model"] as? String == model.id)
            #expect(json["system"] as? String == "system rules")
            #expect(json["user"] as? String == "user question")
            #expect(json["maxOutputTokens"] == nil, "nil must preserve the server default")
            let images = try #require(json["images"] as? [String])
            #expect(images.count == 2)
            #expect(images[0].hasPrefix("data:image/png;base64,"))
            #expect(images[1].hasPrefix("data:image/jpeg;base64,"))
        }
    }

    @Test("explicit output budgets are clamped at both boundaries")
    func outputBudgetBounds() async throws {
        for (requested, expected) in [(1, OutputTokenBudget.minimum),
                                      (Int.max, OutputTokenBudget.maximum)] {
            try await withOutcome(.response(status: 200, body: backendSSE(["[DONE]"]))) {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model,
                    maxOutputTokens: requested) { _ in }
                #expect(try bodyJSON()["maxOutputTokens"] as? Int == expected)
            }
        }
    }

    @Test("managed orchestration forwards the bounded chairman output ceiling")
    func orchestrationOutputBudget() async throws {
        try await withOutcome(.response(status: 200, body: backendSSE(["[DONE]"]))) {
            _ = try await OrchestrateService.stream(
                level: "ultra", system: "system rules", user: "user question",
                maxOutputTokens: Int.max,
                baseURL: "https://api.example.test/",
                session: BackendGatewayMockURLProtocol.session()) { _ in }

            let request = try #require(BackendGatewayMockURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://api.example.test/api/orchestrate")
            let json = try bodyJSON()
            #expect(json["level"] as? String == "ultra")
            #expect(json["maxOutputTokens"] as? Int == OutputTokenBudget.maximum)
        }
    }

    @Test("a copilot watch is labelled in the payload; ordinary chat is not")
    func featureLabel() async throws {
        try await withOutcome(.response(status: 200, body: backendSSE(["[DONE]"]))) {
            try await CopilotBilling.labelled(.agenda) {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model) { _ in }
            }
            #expect(try bodyJSON()["feature"] as? String == "agenda")
        }

        try await withOutcome(.response(status: 200, body: backendSSE(["[DONE]"]))) {
            _ = try await gateway().streamChat(
                system: "s", user: "u", images: [], model: model) { _ in }
            #expect(try bodyJSON()["feature"] == nil)
        }
    }

    @Test("more images than the tariff can quote are rejected before transport")
    func imageCountBound() async {
        BackendGatewayMockURLProtocol.reset()
        let images = Array(repeating: Data([0x00]), count: BackendGateway.maxImages + 1)
        let error = await expectHTTPError {
            _ = try await gateway().streamChat(
                system: "s", user: "u", images: images, model: model) { _ in }
        }
        #expect(error?.provider == "Backend")
        #expect(error?.status == 413)
        #expect(error?.body.contains("at most 8 images") == true)
        #expect(BackendGatewayMockURLProtocol.lastRequest == nil)
    }

    @Test("an oversized image is rejected before base64 expansion or transport")
    func imageByteBound() async {
        BackendGatewayMockURLProtocol.reset()
        let oversized = Data(count: BackendGateway.maxImageBytes + 1)
        let error = await expectHTTPError {
            _ = try await gateway().streamChat(
                system: "s", user: "u", images: [oversized], model: model) { _ in }
        }
        #expect(error?.status == 413)
        #expect(error?.body.contains("20 MB") == true)
        #expect(BackendGatewayMockURLProtocol.lastRequest == nil)
    }

    @Test("empty and malformed backend URLs fail before transport")
    func invalidBaseURL() async {
        for baseURL in ["", "not-a-network-url"] {
            BackendGatewayMockURLProtocol.reset()
            await #expect(throws: (any Error).self) {
                _ = try await gateway(baseURL: baseURL).streamChat(
                    system: "s", user: "u", images: [], model: model) { _ in }
            }
            #expect(BackendGatewayMockURLProtocol.lastRequest == nil)
        }
    }

    // MARK: - SSE stream

    @Test("streams deltas, ignores malformed and notice records, and stops at DONE")
    func successSSE() async throws {
        let stream = Data("""
        event: message
        data: not-json

        data: {"notice":"served by a fallback model"}

        data: {"delta":"Hello"}

        data: {"delta":""}

        data: {"delta":" world"}

        data: [DONE]

        data: {"delta":" ignored"}

        """.utf8)
        try await withOutcome(.response(status: 200, body: stream)) {
            let deltas = BackendDeltaLog()
            let answer = try await gateway().streamChat(
                system: "s", user: "u", images: [], model: model) { deltas.append($0) }
            #expect(answer == "Hello world")
            #expect(deltas.values == ["Hello", " world"])
        }
    }

    @Test("a mid-stream error preserves emitted deltas and terminates the run")
    func midStreamError() async throws {
        let stream = backendSSE([
            #"{"delta":"partial"}"#,
            #"{"error":"upstream model timed out"}"#,
            #"{"delta":"must not emit"}"#,
        ])
        try await withOutcome(.response(status: 200, body: stream)) {
            let deltas = BackendDeltaLog()
            let error = await expectHTTPError {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model) { deltas.append($0) }
            }
            #expect(deltas.values == ["partial"])
            #expect(error?.status == 502)
            #expect(error?.body == "upstream model timed out")
        }
    }

    @Test("EOF without the completion sentinel fails before or after output",
          arguments: [false, true])
    func missingCompletionSentinel(afterOutput: Bool) async throws {
        let body = afterOutput
            ? backendSSE([#"{"delta":"convincing partial"}"#])
            : Data()
        try await withOutcome(.response(status: 200, body: body)) {
            let deltas = BackendDeltaLog()
            do {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model) {
                        deltas.append($0)
                    }
                Issue.record("expected incomplete-stream failure")
            } catch let error as LLMError {
                guard case .badResponse(let provider) = error else {
                    Issue.record("expected badResponse, got \(error)")
                    return
                }
                #expect(provider == "Backend")
            }
            #expect(deltas.values == (afterOutput ? ["convincing partial"] : []))
        }
    }

    @Test("a completion sentinel split across transport chunks still succeeds")
    func splitCompletionSentinel() async throws {
        let chunks = [
            Data("data: {\"delta\":\"complete\"}\n\ndata: [DO".utf8),
            Data("NE]\n\n".utf8),
        ]
        try await withOutcome(.responseChunks(status: 200, chunks: chunks)) {
            let deltas = BackendDeltaLog()
            let answer = try await gateway().streamChat(
                system: "s", user: "u", images: [], model: model) {
                    deltas.append($0)
                }
            #expect(answer == "complete")
            #expect(deltas.values == ["complete"])
        }
    }

    @Test("a non-HTTP success transport is rejected as an invalid response")
    func nonHTTPResponse() async throws {
        try await withOutcome(.nonHTTP(body: Data("ok".utf8))) {
            do {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model) { _ in }
                Issue.record("expected an invalid-response error")
            } catch let error as LLMError {
                guard case .badResponse(let provider) = error else {
                    Issue.record("expected badResponse, got \(error)")
                    return
                }
                #expect(provider == "Backend")
            }
        }
    }

    // MARK: - HTTP and transport failures

    @Test("non-2xx JSON errors unwrap string, nested, and message envelopes")
    func jsonErrors() async throws {
        let cases: [(Data, String)] = [
            (Data(#"{"error":"sign in required"}"#.utf8), "sign in required"),
            (Data(#"{"error":{"message":"provider unavailable"}}"#.utf8), "provider unavailable"),
            (Data(#"{"message":"request refused"}"#.utf8), "request refused"),
        ]
        for (body, expected) in cases {
            try await withOutcome(.response(status: 503, body: body)) {
                let error = await expectHTTPError {
                    _ = try await gateway().streamChat(
                        system: "s", user: "u", images: [], model: model) { _ in }
                }
                #expect(error?.provider == "Backend")
                #expect(error?.status == 503)
                #expect(error?.body == expected)
            }
        }
    }

    @Test("plain error bodies are retained but capped before reaching the UI")
    func plainErrorIsCapped() async throws {
        let body = String(repeating: "x", count: 600)
        try await withOutcome(.response(status: 500, body: Data(body.utf8))) {
            let error = await expectHTTPError {
                _ = try await gateway().streamChat(
                    system: "s", user: "u", images: [], model: model) { _ in }
            }
            #expect(error?.status == 500)
            #expect(error?.body.count == 300)
            #expect(error?.body == String(repeating: "x", count: 300))
        }
    }

    @Test("timeout and offline surface as the gateway outage, not raw transport errors")
    func transportFailures() async throws {
        // Superseded contract: these used to pass through as URLErrors, and the
        // banner then read "could not connect" — technically true, useless to
        // the user. They are now deliberately part of the unreachable class
        // (see isBackendUnreachable) and land on the same friendly outage
        // message as a 502, so the app says "AI is down, local still works".
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            try await withOutcome(.failure(code)) {
                do {
                    _ = try await gateway().streamChat(
                        system: "s", user: "u", images: [], model: model) { _ in }
                    Issue.record("expected the outage error for \(code)")
                } catch let error as LLMError {
                    guard case .http(_, let status, _) = error else {
                        Issue.record("expected the 502 outage mapping for \(code), got \(error)")
                        return
                    }
                    #expect(status == 502)
                } catch {
                    Issue.record("expected the outage error for \(code), got \(error)")
                }
            }
        }
    }
}

private final class BackendDeltaLog {
    private(set) var values: [String] = []
    func append(_ delta: String) { values.append(delta) }
}
