import Foundation
import Testing
@testable import MeetGPT

@Suite("Google OAuth granted scopes")
struct GoogleAuthScopeTests {
    @Test("maps a complete granular grant to the connected services")
    func completeGrant() {
        let scope = [
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/documents.readonly",
            "https://www.googleapis.com/auth/spreadsheets.readonly",
            // Docs and Sheets each also need drive.file (create a Doc, create a
            // Sheet). Without it the compound grant is partial (see
            // partialGrant below).
            "https://www.googleapis.com/auth/drive.file",
        ].joined(separator: " ")

        #expect(GoogleAuth.servicesGranted(by: scope) == ["calendar", "docs", "sheets"])
    }

    @Test("does not claim a service whose compound grant is partial")
    func partialGrant() {
        let scope = [
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/documents.readonly",
            // drive.file was denied, so Docs cannot create anything and the
            // compound grant is not usable.
        ].joined(separator: " ")

        #expect(GoogleAuth.servicesGranted(by: scope) == ["calendar"])
    }

    @Test("missing or unrelated scopes grant no workflow service")
    func missingGrant() {
        #expect(GoogleAuth.servicesGranted(by: nil).isEmpty)
        #expect(GoogleAuth.servicesGranted(
            by: "openid email https://www.googleapis.com/auth/drive.file"
        ).isEmpty)
    }

    @Test("preserves Google's token endpoint error detail on HTTP failures")
    func tokenEndpointErrorDetail() {
        let data = Data(#"{"error":"invalid_grant","error_description":"Redirect URI mismatch"}"#.utf8)
        guard case .server(let code, let description) = GoogleAuth.oauthError(from: data) else {
            Issue.record("Expected a structured Google OAuth error")
            return
        }
        #expect(code == "invalid_grant")
        #expect(description == "Redirect URI mismatch")
    }

    @Test("rejects a missing Desktop client secret before opening a browser")
    @MainActor
    func missingClientSecret() async {
        do {
            _ = try await GoogleAuth().authorize(
                clientID: "test.apps.googleusercontent.com",
                clientSecret: "")
            Issue.record("Expected the missing client secret to stop authorization")
        } catch GoogleAuthError.missingClientSecret {
            // Expected: fail locally before starting the loopback/browser flow.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("sends the Desktop client secret in code exchange and refresh")
    func tokenFormsIncludeClientSecret() {
        let exchange = GoogleAuth.authorizationCodeTokenForm(
            clientID: "client-id",
            clientSecret: "desktop-secret",
            code: "code",
            verifier: "verifier",
            redirectURI: "http://127.0.0.1:54321/callback")
        let refresh = GoogleAuth.refreshTokenForm(
            clientID: "client-id",
            clientSecret: "desktop-secret",
            refreshToken: "refresh")

        #expect(exchange["client_secret"] == "desktop-secret")
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(refresh["client_secret"] == "desktop-secret")
        #expect(refresh["grant_type"] == "refresh_token")
    }
}

/// What the consent screen asks for.
///
/// This is the set Google's reviewer compares against the justifications in
/// `cruxwing-marketing/docs/legal/google-verification.md` and against the
/// disclosure on `google-data.html`. A scope added here and nowhere else is how
/// a submission gets rejected, so the whole set is pinned rather than sampled.
@Suite("Google consent-screen scope set")
struct GoogleConsentScopeSetTests {

    private var requested: Set<String> {
        Set(GoogleService.requestable.flatMap(\.scopeURLs))
    }

    @Test("the client requests exactly these four scopes")
    func exactSet() {
        #expect(requested == [
            "https://www.googleapis.com/auth/calendar.readonly",
            "https://www.googleapis.com/auth/documents.readonly",
            "https://www.googleapis.com/auth/spreadsheets.readonly",
            "https://www.googleapis.com/auth/drive.file",
        ])
    }

    @Test("nothing RESTRICTED is requested")
    func noRestrictedScopes() {
        // The reason the submission needs no CASA Tier 2 assessment. Adding any
        // of these back is a business decision with an annual bill attached, so
        // it must not happen as a side effect of some feature.
        // `drive.metadata.readonly` belongs on this list and was missing from
        // it, which is how an earlier version of this suite asserted "nothing
        // restricted" while the app still requested a restricted scope. The
        // Google Cloud console groups it under "Your restricted scopes" — that
        // grouping is the authority, not a reading of the tier tables.
        let restricted = [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.metadata.readonly",
            "https://www.googleapis.com/auth/drive.metadata",
            "https://www.googleapis.com/auth/drive",
            "https://www.googleapis.com/auth/drive.activity.readonly",
            "https://www.googleapis.com/auth/drive.meet.readonly",
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.drafts.readonly",
            "https://mail.google.com/",
        ]
        for scope in restricted { #expect(!requested.contains(scope)) }
    }

    @Test("no write scope broader than drive.file")
    func writesAreFileScopedOnly() {
        // `spreadsheets` and `documents` (without .readonly) are read-WRITE over
        // everything the user owns. Creating a file needs neither.
        #expect(!requested.contains("https://www.googleapis.com/auth/spreadsheets"))
        #expect(!requested.contains("https://www.googleapis.com/auth/documents"))
        let writes = requested.filter { !$0.hasSuffix(".readonly") }
        #expect(writes == ["https://www.googleapis.com/auth/drive.file"])
    }

    @Test("a withdrawn service is requested by nothing")
    func withdrawnServiceIsInert() {
        let withdrawn = Set(GoogleService.allCases).subtracting(GoogleService.requestable)
        #expect(withdrawn == [.drive], "Drive is withdrawn pending the restricted-scope submission")
        for service in withdrawn { #expect(service.scopeURLs.isEmpty) }
    }

    @Test("document search is off while its scope is withdrawn")
    func searchIsInertWithoutItsScope() {
        // Otherwise every grounding attempt is a 403 the user cannot act on.
        // Derived from the catalog, so restoring the scope re-enables it.
        #expect(!GoogleWorkspaceSearchService.isAvailable)
    }

    @Test("a withdrawn service is never reported as granted")
    func withdrawnServiceIsNotGranted() {
        // The empty set is a subset of every set, so a `servicesGranted` written
        // over `allCases` would report Drive as granted on every single connect,
        // including a calendar-only grant.
        #expect(!GoogleAuth.servicesGranted(
            by: "https://www.googleapis.com/auth/calendar.readonly").contains("drive"))
        #expect(!GoogleAuth.servicesGranted(by: nil).contains("drive"))
    }
}
