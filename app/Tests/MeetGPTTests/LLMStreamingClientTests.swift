import Foundation
import Testing
@testable import MeetGPT

/// Intercepts URLSession for the streaming LLM clients so their SSE parsing,
/// delta emission, and error mapping are tested without a network. Its own
/// static state (separate from MockURLProtocol) + a serialized suite keep the
/// shared responder race-free under parallel test execution.
final class StreamMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        StreamMockURLProtocol.lastRequest = request
        guard let responder = StreamMockURLProtocol.responder else {
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
        config.protocolClasses = [StreamMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Sequential delta sink (onDelta fires synchronously inside the awaited byte
/// loop, so a plain reference type is enough).
final class DeltaLog {
    private(set) var deltas: [String] = []
    func append(_ s: String) { deltas.append(s) }
}

/// Build an SSE body: one `data: <payload>` line per element, blank-line
/// separated, exactly as the providers stream it.
private func sse(_ payloads: [String]) -> Data {
    Data((payloads.map { "data: \($0)" }.joined(separator: "\n\n") + "\n").utf8)
}

@Suite("LLM streaming clients", .serialized)
struct LLMStreamingClientTests {
    private func withResponder(_ status: Int, _ body: Data, _ run: () async throws -> Void) async rethrows {
        StreamMockURLProtocol.responder = { _ in (status, body) }
        defer { StreamMockURLProtocol.responder = nil; StreamMockURLProtocol.lastRequest = nil }
        try await run()
    }

    // MARK: OpenAI dialect

    @Test("OpenAI: missing key throws before any request")
    func openAIMissingKey() async {
        let client = OpenAIClient(session: StreamMockURLProtocol.session(), keyProvider: { "" })
        await #expect(throws: (any Error).self) {
            _ = try await client.streamChat(system: "s", user: "u", model: "gpt-5.4-mini") { _ in }
        }
    }

    @Test("OpenAI: concatenates content deltas and stops at [DONE]")
    func openAIStream() async throws {
        let body = sse([
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"role":"assistant"}}]}"#,   // no content -> ignored
            #"{"choices":[{"delta":{"content":" world"}}]}"#,
            "[DONE]",
            #"{"choices":[{"delta":{"content":" AFTER DONE"}}]}"#  // must never be read
        ])
        try await withResponder(200, body) {
            let log = DeltaLog()
            let client = OpenAIClient(session: StreamMockURLProtocol.session(), keyProvider: { "sk-test" })
            let full = try await client.streamChat(system: "s", user: "u", model: "gpt-5.4-mini") { log.append($0) }
            #expect(full == "Hello world")
            #expect(log.deltas == ["Hello", " world"])
        }
    }

    @Test("OpenAI: a non-2xx response throws")
    func openAIError() async throws {
        try await withResponder(401, Data(#"{"error":"bad key"}"#.utf8)) {
            let client = OpenAIClient(session: StreamMockURLProtocol.session(), keyProvider: { "sk-test" })
            await #expect(throws: (any Error).self) {
                _ = try await client.streamChat(system: "s", user: "u", model: "gpt-5.4-mini") { _ in }
            }
        }
    }

    @Test("OpenAI: posts to the configured endpoint")
    func openAIRequest() async throws {
        try await withResponder(200, sse(["[DONE]"])) {
            let client = OpenAIClient(session: StreamMockURLProtocol.session(), keyProvider: { "sk-test" })
            _ = try await client.streamChat(system: "s", user: "u", model: "gpt-5.4-mini") { _ in }
            #expect(StreamMockURLProtocol.lastRequest?.httpMethod == "POST")
            #expect(StreamMockURLProtocol.lastRequest?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        }
    }

    @Test("OpenAI dialect: a custom endpoint (CN provider) is honored")
    func openAIDialectEndpoint() async throws {
        try await withResponder(200, sse([#"{"choices":[{"delta":{"content":"你好"}}]}"#, "[DONE]"])) {
            let client = OpenAIClient(
                session: StreamMockURLProtocol.session(),
                providerName: "DeepSeek",
                endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                keyProvider: { "dk-test" })
            let full = try await client.streamChat(system: "s", user: "u", model: "deepseek-v4-pro") { _ in }
            #expect(full == "你好")
            #expect(StreamMockURLProtocol.lastRequest?.url?.host == "api.deepseek.com")
        }
    }

    // MARK: Anthropic

    @Test("Anthropic: parses content_block_delta events, ignoring the rest")
    func anthropicStream() async throws {
        let body = sse([
            #"{"type":"message_start","message":{}}"#,               // ignored
            #"{"type":"content_block_delta","delta":{"text":"Hi"}}"#,
            #"{"type":"ping"}"#,                                       // ignored
            #"{"type":"content_block_delta","delta":{"text":"!"}}"#,
            #"{"type":"message_stop"}"#                                // ignored
        ])
        try await withResponder(200, body) {
            let log = DeltaLog()
            let client = AnthropicClient(
                session: StreamMockURLProtocol.session(), keyProvider: { "ak-test" })
            let full = try await client.streamChat(system: "s", user: "u", model: "claude-sonnet-5") { log.append($0) }
            #expect(full == "Hi!")
            #expect(log.deltas == ["Hi", "!"])
        }
    }

    @Test("Anthropic: a non-2xx response throws")
    func anthropicError() async throws {
        try await withResponder(529, Data(#"{"type":"error"}"#.utf8)) {
            let client = AnthropicClient(
                session: StreamMockURLProtocol.session(), keyProvider: { "ak-test" })
            await #expect(throws: (any Error).self) {
                _ = try await client.streamChat(system: "s", user: "u", model: "claude-sonnet-5") { _ in }
            }
        }
    }

    /// Until the key became injectable this could not be written: an empty key was
    /// whatever `mac/.env` happened to hold. It also means `anthropicError` above
    /// now genuinely exercises the non-2xx path instead of passing on a
    /// `missingKey` throw that never reached the responder.
    @Test("Anthropic: missing key throws before any request")
    func anthropicMissingKey() async throws {
        let client = AnthropicClient(
            session: StreamMockURLProtocol.session(), keyProvider: { "" })
        await #expect(throws: (any Error).self) {
            _ = try await client.streamChat(system: "s", user: "u", model: "claude-sonnet-5") { _ in }
        }
    }

    // MARK: Gemini

    @Test("Gemini: concatenates candidate part text across chunks")
    func geminiStream() async throws {
        let body = sse([
            #"{"candidates":[{"content":{"parts":[{"text":"Good"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":" morning"}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[]}}]}"#   // empty -> ignored
        ])
        try await withResponder(200, body) {
            let log = DeltaLog()
            let client = GeminiClient(
                session: StreamMockURLProtocol.session(), keyProvider: { "gk-test" })
            let full = try await client.streamChat(system: "s", user: "u", model: "gemini-3.5-flash") { log.append($0) }
            #expect(full == "Good morning")
            #expect(log.deltas == ["Good", " morning"])
        }
    }

    @Test("Gemini: requests the SSE streaming endpoint for the model")
    func geminiRequest() async throws {
        try await withResponder(200, sse([#"{"candidates":[{"content":{"parts":[{"text":"x"}]}}]}"#])) {
            let client = GeminiClient(
                session: StreamMockURLProtocol.session(), keyProvider: { "gk-test" })
            _ = try await client.streamChat(system: "s", user: "u", model: "gemini-3.5-flash") { _ in }
            let url = StreamMockURLProtocol.lastRequest?.url?.absoluteString ?? ""
            #expect(url.contains("gemini-3.5-flash:streamGenerateContent"))
            #expect(url.contains("alt=sse"))
        }
    }

    @Test("Gemini: a non-2xx response throws")
    func geminiError() async throws {
        try await withResponder(400, Data(#"{"error":{"code":400}}"#.utf8)) {
            let client = GeminiClient(
                session: StreamMockURLProtocol.session(), keyProvider: { "gk-test" })
            await #expect(throws: (any Error).self) {
                _ = try await client.streamChat(system: "s", user: "u", model: "gemini-3.5-flash") { _ in }
            }
        }
    }

    @Test("Gemini: missing key throws before any request")
    func geminiMissingKey() async throws {
        let client = GeminiClient(
            session: StreamMockURLProtocol.session(), keyProvider: { "" })
        await #expect(throws: (any Error).self) {
            _ = try await client.streamChat(system: "s", user: "u", model: "gemini-3.5-flash") { _ in }
        }
    }
}
