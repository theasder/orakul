import Testing
import Foundation
@testable import MeetGPT

// What the user sees when an AI call fails. The load-bearing case is a backend
// outage: nginx returns an HTML error page, and pasting it at the user is leaky
// and useless — the message must instead say AI is down and local features are
// not. Real API errors (429, an app's own 503 with a message) must keep their
// detail, and no status code may ever surface raw HTML.
@Suite("LLM error messages")
struct LLMErrorMessageTests {

    static let nginx502 = """
    <html>\r
    <head><title>502 Bad Gateway</title></head>\r
    <body>\r
    <center><h1>502 Bad Gateway</h1></center>\r
    <hr><center>nginx</center>\r
    </body>\r
    </html>
    """

    @Test("a 502 gateway page becomes a clean, actionable message")
    func gatewayOutageIsFriendly() {
        let msg = LLMError.http("Backend", 502, Self.nginx502).errorDescription ?? ""
        #expect(msg.contains("temporarily unavailable"))
        #expect(msg.lowercased().contains("on-device transcription"))
        // The whole point: no nginx page reaches the user.
        #expect(!msg.contains("<"))
        #expect(!msg.lowercased().contains("nginx"))
        #expect(!msg.contains("502 Bad Gateway"))
    }

    @Test("a 504 gateway timeout is treated the same")
    func gatewayTimeoutIsFriendly() {
        let body = "<html><head><title>504 Gateway Time-out</title></head><body><center>nginx</center></body></html>"
        let msg = LLMError.http("Backend", 504, body).errorDescription ?? ""
        #expect(msg.contains("temporarily unavailable"))
        #expect(!msg.contains("<"))
    }

    @Test("a real rate-limit error keeps its detail")
    func realErrorKeepsDetail() {
        let msg = LLMError.http("OpenAI", 429, "You exceeded your current rate limit.").errorDescription ?? ""
        #expect(msg.contains("429"))
        #expect(msg.contains("rate limit"))
    }

    @Test("an app 503 that carries a message is NOT swallowed as an outage")
    func appMessage503Kept() {
        // The server's own 503 tells the user something useful — that no credits
        // were spent. That must survive, unlike an nginx gateway page.
        let body = "AI usage metering is temporarily unavailable. No credits were spent."
        let msg = LLMError.http("Backend", 503, body).errorDescription ?? ""
        #expect(msg.contains("No credits were spent"))
    }

    @Test("HTML is stripped on ANY status code — nothing raw leaks")
    func htmlStrippedEverywhere() {
        let msg = LLMError.http("Backend", 500, "<pre>internal <b>trace</b> dump</pre>").errorDescription ?? ""
        #expect(!msg.contains("<"))
        #expect(msg.contains("internal"))
    }

    @Test("strippedMessage collapses tags and whitespace, bounded")
    func strippedMessageHelper() {
        #expect(LLMError.strippedMessage("<a>hi</a>   there") == "hi there")
        #expect(LLMError.strippedMessage(Self.nginx502).count <= 200)
    }

    @Test("isGatewayOutage only fires on 5xx boilerplate")
    func gatewayDetection() {
        #expect(LLMError.isGatewayOutage(code: 502, body: Self.nginx502))
        #expect(!LLMError.isGatewayOutage(code: 429, body: Self.nginx502))
        #expect(!LLMError.isGatewayOutage(code: 503, body: "No credits were spent."))
    }
}
