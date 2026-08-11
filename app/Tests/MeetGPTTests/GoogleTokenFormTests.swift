import Foundation
import Testing
@testable import MeetGPT

/// The OAuth token requests, and how a failure from Google is read.
///
/// One existing test checks the client secret reaches both forms. These layer
/// what else has to be true for the exchange to work at all — and, in the PKCE
/// case, to be secure. Every field here is one Google validates: a missing or
/// extra parameter comes back as `invalid_request` with no hint about which,
/// which is a genuinely hard failure to diagnose from the outside.
@Suite("Google token forms")
struct GoogleTokenFormTests {

    private let redirect = "http://127.0.0.1:51234/callback"

    private func authForm(verifier: String = "verifier-abc") -> [String: String] {
        GoogleAuth.authorizationCodeTokenForm(
            clientID: "client-id", clientSecret: "client-secret",
            code: "auth-code", verifier: verifier, redirectURI: redirect)
    }

    private func refreshForm() -> [String: String] {
        GoogleAuth.refreshTokenForm(
            clientID: "client-id", clientSecret: "client-secret",
            refreshToken: "refresh-token")
    }

    // MARK: - Base

    @Test("the code exchange carries every field Google requires")
    func codeExchangeIsComplete() {
        let form = authForm()
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "auth-code")
        #expect(form["client_id"] == "client-id")
        #expect(form["client_secret"] == "client-secret")
        #expect(form["redirect_uri"] == redirect)
    }

    // MARK: - Layer: PKCE

    @Test("the code exchange proves possession of the PKCE verifier")
    func codeExchangeCarriesTheVerifier() {
        // Without code_verifier the exchange is no longer bound to the
        // challenge the browser was sent with — it would still succeed for a
        // client configured to allow it, having silently dropped the protection
        // PKCE exists to provide.
        #expect(authForm(verifier: "the-verifier")["code_verifier"] == "the-verifier")
    }

    @Test("the refresh request does not carry a verifier or a code")
    func refreshOmitsExchangeOnlyFields() {
        // A refresh is not an authorization-code exchange. Sending code,
        // code_verifier or redirect_uri here is an invalid_request.
        let form = refreshForm()
        #expect(form["code_verifier"] == nil)
        #expect(form["code"] == nil)
        #expect(form["redirect_uri"] == nil)
    }

    @Test("the refresh request carries exactly what a refresh needs")
    func refreshIsComplete() {
        let form = refreshForm()
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "refresh-token")
        #expect(form["client_id"] == "client-id")
        #expect(form["client_secret"] == "client-secret")
    }

    // MARK: - Layer: no surplus, no surprises

    @Test("neither form sends a field Google did not ask for")
    func formsCarryNoExtras() {
        // A stray parameter is rejected as invalid_request, and the response
        // does not say which one — so the surface is pinned exactly.
        #expect(Set(authForm().keys) == [
            "client_id", "client_secret", "code", "code_verifier",
            "grant_type", "redirect_uri",
        ])
        #expect(Set(refreshForm().keys) == [
            "client_id", "client_secret", "refresh_token", "grant_type",
        ])
    }

    @Test("values are passed through raw, for the encoder to escape once")
    func valuesAreNotPreEncoded() {
        // The request body is form-encoded when it is built. A value escaped
        // here as well would arrive double-encoded — the redirect_uri would no
        // longer match the one registered, and Google rejects the exchange.
        let form = authForm()
        #expect(form["redirect_uri"] == redirect)
        #expect(form["redirect_uri"]?.contains("%3A") == false)
        #expect(form["redirect_uri"]?.contains("://") == true)
    }

    @Test("an unusual code or verifier survives unchanged")
    func preservesAwkwardValues() {
        // Real codes carry /, + and =; a verifier is base64url. Nothing here
        // may normalise them.
        let form = GoogleAuth.authorizationCodeTokenForm(
            clientID: "c", clientSecret: "s",
            code: "4/0AY0e-g7+ab==", verifier: "aB-_09", redirectURI: redirect)
        #expect(form["code"] == "4/0AY0e-g7+ab==")
        #expect(form["code_verifier"] == "aB-_09")
    }

    // MARK: - Layer: reading Google's failures

    @Test("a standards-shaped error is surfaced with its code and description")
    func parsesOAuthError() throws {
        let body = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        let error = try #require(GoogleAuth.oauthError(from: body))
        guard case .server(let code, let description) = error else {
            Issue.record("expected .server, got \(error)")
            return
        }
        #expect(code == "invalid_grant")
        #expect(description == "Token has been expired or revoked.")
    }

    @Test("an error without a description is still an error")
    func parsesErrorWithoutDescription() throws {
        let error = try #require(GoogleAuth.oauthError(from: Data(#"{"error":"invalid_client"}"#.utf8)))
        guard case .server(let code, let description) = error else {
            Issue.record("expected .server, got \(error)")
            return
        }
        #expect(code == "invalid_client")
        #expect(description == nil)
    }

    @Test("a successful token response is not mistaken for an error")
    func successBodyIsNotAnError() {
        // This matters more than it looks: the parser runs BEFORE the HTTP
        // status check, so reading a success body as an error would fail every
        // sign-in.
        let success = Data(#"{"access_token":"ya29.abc","expires_in":3599,"scope":"openid email"}"#.utf8)
        #expect(GoogleAuth.oauthError(from: success) == nil)
    }

    @Test("a body that is not an OAuth error yields nil rather than a false failure")
    func malformedBodiesAreNotErrors() {
        for body in ["", "   ", "not json", "[]", "{}", "null",
                     #"{"error_description":"orphaned description"}"#] {
            #expect(GoogleAuth.oauthError(from: Data(body.utf8)) == nil,
                    "invented an error from: \(body.debugDescription)")
        }
    }

    @Test("an HTML error page does not become a fabricated OAuth error")
    func htmlBodiesAreNotErrors() {
        // A proxy or captive portal returns HTML. It must fall through to the
        // HTTP status path, not be reported as an OAuth protocol error.
        let html = Data("<html><body><h1>502 Bad Gateway</h1></body></html>".utf8)
        #expect(GoogleAuth.oauthError(from: html) == nil)
    }
}
