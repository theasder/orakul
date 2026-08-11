import Foundation
import Testing
@testable import MeetGPT

/// The App-Review-required account-deletion call (M10d). Own static state + a
/// serialized suite keep the shared responder race-free.
final class AccountDeleteMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        AccountDeleteMockURLProtocol.lastRequest = request
        guard let responder = AccountDeleteMockURLProtocol.responder else {
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
        config.protocolClasses = [AccountDeleteMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("AccountDeletion", .serialized)
struct AccountDeletionTests {
    private func withResponder(_ status: Int, _ body: Data, _ run: () async -> Void) async {
        AccountDeleteMockURLProtocol.responder = { _ in (status, body) }
        defer { AccountDeleteMockURLProtocol.responder = nil; AccountDeleteMockURLProtocol.lastRequest = nil }
        await run()
    }

    @Test("2xx → .deleted, and sends DELETE + Bearer to /auth/account")
    func success() async {
        await withResponder(200, Data(#"{"success":true}"#.utf8)) {
            let outcome = await AccountDeletion.perform(
                baseURL: "https://api.example.com/", token: "tok-123",
                session: AccountDeleteMockURLProtocol.session())
            #expect(outcome == .deleted)
            let req = AccountDeleteMockURLProtocol.lastRequest
            #expect(req?.httpMethod == "DELETE")
            #expect(req?.url?.path == "/auth/account")
            #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        }
    }

    @Test("non-2xx → .failed carrying the status code")
    func serverError() async {
        await withResponder(500, Data(#"{"error":"boom"}"#.utf8)) {
            let outcome = await AccountDeletion.perform(
                baseURL: "https://api.example.com", token: "tok",
                session: AccountDeleteMockURLProtocol.session())
            guard case let .failed(message) = outcome else {
                Issue.record("expected .failed, got \(outcome)"); return
            }
            #expect(message.contains("500"))
        }
    }

    @Test("empty backend URL → .failed without making a request")
    func emptyBase() async {
        AccountDeleteMockURLProtocol.lastRequest = nil
        let outcome = await AccountDeletion.perform(
            baseURL: "   ", token: "tok", session: AccountDeleteMockURLProtocol.session())
        guard case .failed = outcome else { Issue.record("expected .failed"); return }
        #expect(AccountDeleteMockURLProtocol.lastRequest == nil)
    }
}
