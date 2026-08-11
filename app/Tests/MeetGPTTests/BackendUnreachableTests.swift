import Testing
import Foundation
@testable import MeetGPT

// When the backend can't be reached at all (offline, DNS, refused, timeout), the
// user should see the same "AI is down, local still works" framing as a gateway
// 502 — not Apple's generic "Could not connect to the server", and not a
// cancellation dressed up as an error. This pins the classification and that the
// re-map lands on the tested gateway-outage message.
@Suite("Backend unreachable")
struct BackendUnreachableTests {

    @Test("connection-level failures are recognised as unreachable", arguments: [
        URLError.Code.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .resourceUnavailable, .cannotLoadFromNetwork, .secureConnectionFailed,
    ])
    func unreachableCodes(code: URLError.Code) {
        #expect(BackendGateway.isBackendUnreachable(URLError(code)))
    }

    @Test("a cancellation is NOT an outage — it must pass through untouched")
    func cancellationIsNotUnreachable() {
        #expect(!BackendGateway.isBackendUnreachable(URLError(.cancelled)))
    }

    @Test("a reached-but-erroring server is not a connection failure")
    func nonConnectionErrorsAreNotUnreachable() {
        #expect(!BackendGateway.isBackendUnreachable(URLError(.badServerResponse)))
        #expect(!BackendGateway.isBackendUnreachable(LLMError.badResponse("Backend")))
        #expect(!BackendGateway.isBackendUnreachable(LLMError.http("Backend", 500, "boom")))
    }

    @Test("the re-map lands on the friendly gateway-outage message")
    func remapProducesFriendlyMessage() {
        // BackendGateway throws exactly this on an unreachable backend; assert the
        // user-facing text is the outage message, not a raw connection error.
        let msg = LLMError.http("Backend", 502, "Bad Gateway").errorDescription ?? ""
        #expect(msg.contains("temporarily unavailable"))
        #expect(msg.lowercased().contains("on-device transcription"))
        #expect(!msg.contains("<"))
    }
}
