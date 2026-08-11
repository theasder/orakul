import Foundation
import Testing
@testable import MeetGPT

/// Client funnel telemetry (M15b). Own static responder + serialized suite keep
/// the shared stub race-free (mirrors AccountDeletionTests / StoreKitBridgeTests).
final class FunnelMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        FunnelMockURLProtocol.lastRequest = request
        FunnelMockURLProtocol.lastBody = request.httpBody ?? Self.drain(request.httpBodyStream)
        guard let responder = FunnelMockURLProtocol.responder else {
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
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: 4096)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FunnelMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("FunnelTracker", .serialized)
struct FunnelTrackerTests {
    @Test("posts stage + anonId to /api/funnel and returns true on 202")
    func sends() async {
        FunnelMockURLProtocol.responder = { _ in (202, Data(#"{"ok":true}"#.utf8)) }
        defer { FunnelMockURLProtocol.responder = nil; FunnelMockURLProtocol.lastRequest = nil; FunnelMockURLProtocol.lastBody = nil }

        let ok = await FunnelTracker.send(
            stage: "paywall_view", props: ["arm": "iap"],
            baseURL: "https://api.example.com/", anonId: "dev-xyz",
            session: FunnelMockURLProtocol.session())
        #expect(ok)

        let req = FunnelMockURLProtocol.lastRequest
        #expect(req?.httpMethod == "POST")
        #expect(req?.url?.path == "/api/funnel")
        let body = FunnelMockURLProtocol.lastBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect((body?["stage"] as? String) == "paywall_view")
        #expect((body?["anonId"] as? String) == "dev-xyz")
        #expect(((body?["props"] as? [String: Any])?["arm"] as? String) == "iap")
    }

    @Test("non-2xx → false, but never throws")
    func serverError() async {
        FunnelMockURLProtocol.responder = { _ in (400, Data(#"{"ok":false}"#.utf8)) }
        defer { FunnelMockURLProtocol.responder = nil }
        let ok = await FunnelTracker.send(
            stage: "app_open", baseURL: "https://api.example.com", anonId: "d",
            session: FunnelMockURLProtocol.session())
        #expect(ok == false)
    }

    @Test("empty backend URL → false without a request")
    func emptyBase() async {
        FunnelMockURLProtocol.lastRequest = nil
        let ok = await FunnelTracker.send(
            stage: "app_open", baseURL: "   ", anonId: "d",
            session: FunnelMockURLProtocol.session())
        #expect(ok == false)
        #expect(FunnelMockURLProtocol.lastRequest == nil)
    }
}
