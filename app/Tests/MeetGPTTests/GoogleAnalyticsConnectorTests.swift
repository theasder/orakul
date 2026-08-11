import Testing
import Foundation
@testable import MeetGPT

/// Google Analytics via Google's hosted GA4 Data API MCP.
///
/// Live-probed 2026-07: https://analyticsdata.googleapis.com/mcp/v1 exposes
/// run_report, get_metadata, run_realtime_report and check_compatibility; the
/// authorization server is accounts.google.com with no open DCR; and the
/// protected-resource metadata offers TWO scopes —
/// `analytics.readonly` and plain `analytics`.
///
/// That second one is the reason most of this file exists: plain `analytics` is
/// READ-WRITE over the property and can modify GA configuration. A meeting
/// co-pilot reads numbers to check a claim; a token that could edit someone's
/// analytics setup is a token worth stealing.
@Suite("Google Analytics scope policy")
struct GoogleAnalyticsScopeTests {
    private let selector = GoogleAnalyticsLeastPrivilegeOAuthScopeSelector()
    /// Verbatim from the probed protected-resource metadata.
    private let advertised = [
        "https://www.googleapis.com/auth/analytics.readonly",
        "https://www.googleapis.com/auth/analytics",
    ]

    @Test("never requests the read-write analytics scope")
    func refusesWriteScope() {
        let selected = selector.selectScopes(challengeScope: nil, scopesSupported: advertised) ?? []
        #expect(!selected.contains("https://www.googleapis.com/auth/analytics"))
        #expect(selected == ["https://www.googleapis.com/auth/analytics.readonly"])
    }

    @Test("the challenge hint cannot smuggle the write scope in")
    func challengeCannotWiden() {
        let selected = selector.selectScopes(
            challengeScope: "https://www.googleapis.com/auth/analytics",
            scopesSupported: advertised)
        // Intersection is empty -> nil, so the connection fails rather than
        // quietly taking write access.
        #expect(selected == nil)
    }

    @Test("with no hint at all it asks for read-only, not the union on offer")
    func unhintedIsReadOnly() {
        #expect(selector.selectScopes(challengeScope: nil, scopesSupported: nil)
                == ["https://www.googleapis.com/auth/analytics.readonly"])
    }

    @Test("the allowlist contains exactly one scope, and it is the read one")
    func allowlistIsMinimal() {
        #expect(GoogleAnalyticsLeastPrivilegeOAuthScopeSelector.allowed.count == 1)
        #expect(GoogleAnalyticsLeastPrivilegeOAuthScopeSelector.allowed
                .contains("https://www.googleapis.com/auth/analytics.readonly"))
        for forbidden in ["https://www.googleapis.com/auth/analytics",
                          "https://www.googleapis.com/auth/analytics.edit",
                          "https://www.googleapis.com/auth/analytics.manage.users"] {
            #expect(!GoogleAnalyticsLeastPrivilegeOAuthScopeSelector.allowed.contains(forbidden))
        }
    }
}

@Suite("Google Analytics catalog entry")
struct GoogleAnalyticsCatalogTests {
    @Test("absent until its own client credentials are configured")
    func gatedOnCredentials() {
        let hasCreds = !Config.googleAnalyticsClientID.isEmpty
            && !Config.googleAnalyticsClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.googleAnalytics == nil)
        } else {
            #expect(MCPCatalog.googleAnalytics?.id == "google-analytics")
        }
    }

    @Test("points at the DATA endpoint, not the admin one")
    func usesTheDataEndpoint() {
        // analyticsadmin exposes twelve tools, all describing configuration —
        // property names, data streams, retention. None of that settles an
        // argument in a meeting; run_report does.
        let descriptor = MCPServerDescriptor(
            id: "google-analytics", name: "Google Analytics",
            endpoint: URL(string: "https://analyticsdata.googleapis.com/mcp/v1")!,
            symbol: "chart.line.uptrend.xyaxis", isCustom: false,
            fixedClientID: "id", fixedClientSecret: "secret")
        #expect(descriptor.endpoint.host == "analyticsdata.googleapis.com")
        #expect(descriptor.endpoint.scheme == "https")
        // Google Desktop clients accept any loopback port, so pinning one would
        // collide with a busy port for no benefit.
        #expect(descriptor.fixedLoopbackPort == nil)
    }

    @Test("does not reuse the app's own Google client or the Gmail one")
    func usesASeparateClient() {
        // Verification tier is per consent screen. If analytics.readonly turns out
        // to be Restricted rather than Sensitive, that obligation must land here
        // and not on sign-in.
        guard !Config.googleAnalyticsClientID.isEmpty else { return }
        #expect(Config.googleAnalyticsClientID != Config.googleClientID)
        #expect(Config.googleAnalyticsClientID != Config.gmailClientID)
    }

    @Test("its probe tells the model to contradict the room with the number")
    func probeLicensesContradiction() {
        let probe = ConnectorProbeStrategy.probe(forServerID: "google-analytics")
        #expect(probe != nil)
        let readFor = probe?.readFor.lowercased() ?? ""
        #expect(readFor.contains("not support") || readFor.contains("quote the number"))
    }

    @Test("research is pinned to run_report, not a schema tool")
    func researchToolIsPinned() {
        // get_metadata and check_compatibility are readable and take arguments, so
        // the generic heuristic would happily pick one and return a SCHEMA instead
        // of a number — the same trap Gmail's list_drafts set.
        let src = try? String(contentsOfFile: "Sources/MeetGPT/MCP/MCPGrounding.swift", encoding: .utf8)
        let text = src ?? ""
        #expect(text.contains("\"google-analytics\": [\"run_report\""),
                "GA research must be pinned to run_report")
    }
}
