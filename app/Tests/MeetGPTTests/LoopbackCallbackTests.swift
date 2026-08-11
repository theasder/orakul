import Foundation
import Testing
@testable import MeetGPT

/// Which HTTP request is allowed to deliver an OAuth authorization code.
///
/// The loopback server is a ONE-SHOT: the first request it accepts resumes the
/// waiting continuation and tears the listener down. A browser aims several
/// requests at that port — the callback, `/favicon.ico`, occasionally a
/// preflight — so accepting the wrong one ends the sign-in with no code and no
/// error the user can act on.
///
/// Layered on one base fact — a well-formed callback yields its URL — with each
/// later test narrowing what else may pass: other paths, other methods, and
/// malformed lines that must not crash the parser.
@Suite("OAuth loopback callback parsing")
struct LoopbackCallbackTests {

    private let port: UInt16 = 51_234

    private func parse(_ line: String) -> URL? {
        LoopbackRedirectServer.callbackURL(fromRequestLine: line, port: port)
    }

    // MARK: - Base

    @Test("a well-formed callback yields a URL carrying its query")
    func acceptsTheCallback() throws {
        let url = try #require(parse("GET /callback?code=abc123&state=xyz HTTP/1.1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value == "abc123")
        #expect(items.first { $0.name == "state" }?.value == "xyz")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == Int(port))
    }

    // MARK: - Layer: what must not consume the one-shot

    @Test("the browser's favicon probe is ignored")
    func ignoresFavicon() {
        // The classic way a loopback flow dies: Safari asks for the favicon,
        // the server treats it as the callback, and the real one arrives after
        // the listener is gone.
        #expect(parse("GET /favicon.ico HTTP/1.1") == nil)
        #expect(parse("GET / HTTP/1.1") == nil)
        #expect(parse("GET /健康 HTTP/1.1") == nil)
    }

    @Test("a path that merely starts with /callback is not the callback")
    func requiresAnExactPath() {
        // A prefix match also accepted these. No provider is configured to
        // redirect to them, so allowing them only widened what could consume
        // the flow.
        #expect(parse("GET /callbackevil HTTP/1.1") == nil)
        #expect(parse("GET /callback2?code=abc HTTP/1.1") == nil)
        #expect(parse("GET /callback/../secret HTTP/1.1") == nil)
        // …while the two legitimate spellings still pass.
        #expect(parse("GET /callback HTTP/1.1") != nil)
        #expect(parse("GET /callback?code=abc HTTP/1.1") != nil)
    }

    @Test("only GET is accepted")
    func rejectsOtherMethods() {
        // An authorization code arrives in a redirect, which is always a GET.
        for method in ["POST", "PUT", "DELETE", "HEAD", "OPTIONS", "get"] {
            #expect(parse("\(method) /callback?code=abc HTTP/1.1") == nil,
                    "\(method) was accepted")
        }
    }

    @Test("malformed request lines are rejected, never crash")
    func handlesMalformedLines() {
        for line in ["", "   ", "GET", "GET/callback", "/callback?code=abc",
                     "HTTP/1.1", "GET  HTTP/1.1", "\u{0}\u{1}"] {
            #expect(parse(line) == nil, "accepted malformed line: \(line.debugDescription)")
        }
    }

    // MARK: - Layer: the code survives the round trip intact

    @Test("an error redirect is delivered too, not silently dropped")
    func deliversProviderErrors() throws {
        // The user pressing "Cancel" comes back as ?error=access_denied. It has
        // to reach the flow so it can report a refusal rather than time out
        // after five minutes.
        let url = try #require(parse("GET /callback?error=access_denied&state=xyz HTTP/1.1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "error" }?.value == "access_denied")
    }

    @Test("percent-encoded and long codes survive intact")
    func preservesEncodedValues() throws {
        // Real authorization codes carry /, + and = and can run hundreds of
        // characters; a parser that re-encodes or truncates breaks the exchange
        // with an opaque "invalid_grant" from the provider.
        let code = "4%2F0AY0e-g7" + String(repeating: "x", count: 300)
        let url = try #require(parse("GET /callback?code=\(code)&state=a%20b HTTP/1.1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value?.hasPrefix("4/0AY0e-g7") == true)
        #expect(items.first { $0.name == "code" }?.value?.count ?? 0 > 300)
        #expect(items.first { $0.name == "state" }?.value == "a b")
    }

    @Test("the URL is bound to loopback on the server's own port")
    func alwaysBindsToLoopback() throws {
        // The rebuilt URL must never point anywhere but this machine, whatever
        // the request line said — it is handed to the token exchange next.
        for line in ["GET /callback?code=a HTTP/1.1", "GET /callback HTTP/1.1"] {
            let url = try #require(parse(line))
            #expect(url.host == "127.0.0.1")
            #expect(url.scheme == "http")
            #expect(url.port == Int(port))
        }
    }
}
