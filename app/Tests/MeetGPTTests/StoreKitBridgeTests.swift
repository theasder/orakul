import Foundation
import Testing
@testable import MeetGPT

/// The client half of the StoreKit receipt bridge (M11b-3a). Own static responder
/// + a serialized suite keep the shared stub race-free (mirrors AccountDeletionTests).
final class StoreKitBridgeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        StoreKitBridgeMockURLProtocol.lastRequest = request
        // URLProtocol strips httpBody into httpBodyStream — read it back for assertions.
        StoreKitBridgeMockURLProtocol.lastBody = request.httpBody ?? Self.drain(request.httpBodyStream)
        guard let responder = StoreKitBridgeMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StoreKitBridgeMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("StoreKitBridge", .serialized)
struct StoreKitBridgeTests {
    private func withResponder(_ status: Int, _ body: Data, _ run: () async -> Void) async {
        StoreKitBridgeMockURLProtocol.responder = { _ in (status, body) }
        defer {
            StoreKitBridgeMockURLProtocol.responder = nil
            StoreKitBridgeMockURLProtocol.lastRequest = nil
            StoreKitBridgeMockURLProtocol.lastBody = nil
        }
        await run()
    }

    @Test("verified subscription 200 → .activated with tier + plan; POSTs JWS + Bearer to /api/billing/storekit")
    func subscriptionActivated() async {
        let body = Data(#"{"ok":true,"kind":"subscription","planId":"premium-monthly","tier":"premium","idempotent":false}"#.utf8)
        await withResponder(200, body) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "signed-jws-blob",
                baseURL: "https://api.example.com/", token: "tok-9",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .activated(tier: .premium, planId: "premium-monthly", idempotent: false))

            let req = StoreKitBridgeMockURLProtocol.lastRequest
            #expect(req?.httpMethod == "POST")
            #expect(req?.url?.path == "/api/billing/storekit")
            #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-9")
            let sent = StoreKitBridgeMockURLProtocol.lastBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            #expect((sent?["signedTransaction"] as? String) == "signed-jws-blob")
        }
    }

    @Test("replayed transaction → .activated with idempotent == true")
    func idempotentReplay() async {
        let body = Data(#"{"ok":true,"kind":"subscription","planId":"ultra-monthly","tier":"ultra","idempotent":true}"#.utf8)
        await withResponder(200, body) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .activated(tier: .ultra, planId: "ultra-monthly", idempotent: true))
        }
    }

    @Test("add-on consumable → .notGrantable (not a silent no-op)")
    func addOnNotGrantable() async {
        let body = Data(#"{"ok":false,"kind":"addon","addOnId":"compute-250","error":"Add-on packs are not yet grantable."}"#.utf8)
        await withResponder(400, body) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .notGrantable("Add-on packs are not yet grantable."))
        }
    }

    @Test("co-pilot consumable 200 → durable add-on grant")
    func copilotAddOnGranted() async {
        let body = Data(#"{"ok":true,"kind":"addon","addOnId":"copilot-10","quantity":10,"unit":"hours","copilotHours":10,"copilotCredits":2240,"idempotent":false}"#.utf8)
        await withResponder(200, body) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .addOnGranted(
                addOnId: "copilot-10", quantity: 10, unit: "hours", idempotent: false))
        }
    }

    @Test("compute consumable 200 → durable add-on grant")
    func computeAddOnGranted() async {
        let body = Data(#"{"ok":true,"kind":"addon","addOnId":"compute-250","quantity":250,"unit":"credits","computeCredits":250,"idempotent":true}"#.utf8)
        await withResponder(200, body) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .addOnGranted(
                addOnId: "compute-250", quantity: 250, unit: "credits", idempotent: true))
        }
    }

    @Test("verification failure (400) → .failed with the server message")
    func verificationFailed() async {
        await withResponder(400, Data(#"{"error":"Transaction verification failed."}"#.utf8)) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .failed("Transaction verification failed."))
        }
    }

    @Test("verifier unavailable (503) → .failed (fail-closed, nothing granted)")
    func verifierUnavailable() async {
        await withResponder(503, Data(#"{"error":"Purchase verification is unavailable."}"#.utf8)) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            #expect(outcome == .failed("Purchase verification is unavailable."))
        }
    }

    @Test("200 but ok:false / missing tier → .failed (never fabricates an entitlement)")
    func malformedSuccess() async {
        await withResponder(200, Data(#"{"ok":true,"kind":"subscription","planId":"pro-monthly"}"#.utf8)) {
            let outcome = await StoreKitBridge.submit(
                signedTransaction: "jws", baseURL: "https://api.example.com", token: "t",
                session: StoreKitBridgeMockURLProtocol.session())
            guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
        }
    }

    @Test("empty signed transaction → .failed without a request")
    func emptySignedTransaction() async {
        StoreKitBridgeMockURLProtocol.lastRequest = nil
        let outcome = await StoreKitBridge.submit(
            signedTransaction: "   ", baseURL: "https://api.example.com", token: "t",
            session: StoreKitBridgeMockURLProtocol.session())
        guard case .failed = outcome else { Issue.record("expected .failed"); return }
        #expect(StoreKitBridgeMockURLProtocol.lastRequest == nil)
    }

    @Test("empty token → .failed without a request (must be signed in)")
    func emptyToken() async {
        StoreKitBridgeMockURLProtocol.lastRequest = nil
        let outcome = await StoreKitBridge.submit(
            signedTransaction: "jws", baseURL: "https://api.example.com", token: "  ",
            session: StoreKitBridgeMockURLProtocol.session())
        guard case .failed = outcome else { Issue.record("expected .failed"); return }
        #expect(StoreKitBridgeMockURLProtocol.lastRequest == nil)
    }

    @Test("empty backend URL → .failed without a request")
    func emptyBase() async {
        StoreKitBridgeMockURLProtocol.lastRequest = nil
        let outcome = await StoreKitBridge.submit(
            signedTransaction: "jws", baseURL: "   ", token: "t",
            session: StoreKitBridgeMockURLProtocol.session())
        guard case .failed = outcome else { Issue.record("expected .failed"); return }
        #expect(StoreKitBridgeMockURLProtocol.lastRequest == nil)
    }
}
