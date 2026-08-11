import Testing
import Foundation
@testable import MeetGPT

/// Gmail's MCP server advertises, per tool, EVERY scope that would satisfy that
/// tool — `https://mail.google.com/` (permanent delete) and `gmail.modify`
/// (send) included. A selector that trusts the advertised set asks the user to
/// hand a meeting app the ability to empty their mailbox.
///
/// That is the failure these tests exist to prevent, so they assert on the
/// refusals as hard as on the grants.
@Suite("Gmail least-privilege scopes")
struct GmailScopeSelectorTests {
    private let selector = GmailLeastPrivilegeOAuthScopeSelector()

    /// Verbatim from https://gmailmcp.googleapis.com/.well-known/oauth-protected-resource/<tool>
    /// (probed 2026-07). If Google widens these, the intersection still holds.
    private let listLabelsScopes = [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.metadata",
    ]
    private let createDraftScopes = [
        "https://mail.google.com/",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
    ]

    @Test("never requests full-mailbox access, whatever the server offers")
    func refusesFullMailAccess() {
        for advertised in [listLabelsScopes, createDraftScopes] {
            let selected = selector.selectScopes(challengeScope: nil, scopesSupported: advertised) ?? []
            #expect(!selected.contains("https://mail.google.com/"))
        }
    }

    @Test("never requests gmail.modify — that scope can send mail as the user")
    func refusesModify() {
        for advertised in [listLabelsScopes, createDraftScopes] {
            let selected = selector.selectScopes(challengeScope: nil, scopesSupported: advertised) ?? []
            #expect(!selected.contains("https://www.googleapis.com/auth/gmail.modify"))
        }
    }

    @Test("keeps the reading tools working")
    func grantsReadScopes() {
        let selected = selector.selectScopes(challengeScope: nil, scopesSupported: listLabelsScopes) ?? []
        #expect(selected.contains("https://www.googleapis.com/auth/gmail.readonly"))
        #expect(selected.contains("https://www.googleapis.com/auth/gmail.labels"))
    }

    @Test("drafting a follow-up gets compose, and only compose")
    func grantsComposeForDrafts() {
        let selected = selector.selectScopes(challengeScope: nil, scopesSupported: createDraftScopes) ?? []
        #expect(selected == ["https://www.googleapis.com/auth/gmail.compose"])
    }

    @Test("a read challenge does not quietly acquire drafting rights")
    func readChallengeStaysRead() {
        // search_threads offers no compose scope; the token must not gain one.
        let searchThreads = [
            "https://mail.google.com/",
            "https://www.googleapis.com/auth/gmail.modify",
            "https://www.googleapis.com/auth/gmail.readonly",
        ]
        let selected = selector.selectScopes(challengeScope: nil, scopesSupported: searchThreads) ?? []
        #expect(selected == ["https://www.googleapis.com/auth/gmail.readonly"])
    }

    @Test("the WWW-Authenticate scope hint wins over the metadata list")
    func challengeScopeTakesPriority() {
        let selected = selector.selectScopes(
            challengeScope: "https://www.googleapis.com/auth/gmail.readonly https://mail.google.com/",
            scopesSupported: createDraftScopes) ?? []
        #expect(selected == ["https://www.googleapis.com/auth/gmail.readonly"])
    }

    @Test("with no hint at all, falls back to read-only rather than everything")
    func unhintedFallsBackToReadOnly() {
        // Atlassian's selector falls back to its whole allowlist here. Gmail's
        // must not: an unhinted request is the one case where we have the least
        // information, so it gets the least privilege.
        let selected = selector.selectScopes(challengeScope: nil, scopesSupported: nil)
        #expect(selected == ["https://www.googleapis.com/auth/gmail.readonly"])
    }

    @Test("returns nil when nothing offered is acceptable, rather than guessing")
    func refusesEntirelyUnacceptableSets() {
        let selected = selector.selectScopes(
            challengeScope: nil,
            scopesSupported: ["https://mail.google.com/",
                              "https://www.googleapis.com/auth/gmail.settings.basic"])
        #expect(selected == nil)
    }

    @Test("the allowlist excludes broad mailbox, modify, and send-only scopes")
    func allowlistExcludesBroadWriteScopes() {
        let forbidden = ["https://mail.google.com/",
                         "https://www.googleapis.com/auth/gmail.modify",
                         "https://www.googleapis.com/auth/gmail.send",
                         "https://www.googleapis.com/auth/gmail.insert",
                         "https://www.googleapis.com/auth/gmail.settings.basic",
                         "https://www.googleapis.com/auth/gmail.settings.sharing"]
        for scope in forbidden {
            #expect(!GmailLeastPrivilegeOAuthScopeSelector.allowed.contains(scope),
                    "\(scope) must never be requestable")
        }
    }

    @Test("Gmail actions can create drafts but can never invoke a send tool")
    func gmailExecutionPolicyIsDraftOnly() {
        let draft = AnswerActionPlanner.ToolCapability(
            serverID: "gmail", serverName: "Gmail", toolName: "create_draft",
            argumentKeys: ["subject", "body"], requiredKeys: ["body"])
        let send = AnswerActionPlanner.ToolCapability(
            serverID: "gmail", serverName: "Gmail", toolName: "send_email",
            argumentKeys: ["subject", "body"], requiredKeys: ["body"])
        #expect(AnswerActionPlanner.isOfferableWriteCapability(draft))
        #expect(!AnswerActionPlanner.isOfferableWriteCapability(send))
    }
}

/// Google issues a refresh token only for `access_type=offline`, and only
/// re-issues one when consent is re-shown. The SDK builds a spec-conformant
/// authorization URL with no hook for either, so they are appended on the way
/// to the browser — without disturbing the parameters the SDK did set.
@Suite("Google offline-access authorization parameters")
struct LoopbackAuthDelegateQueryTests {
    private let base = URL(string:
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&scope=x&state=s&code_challenge=c&code_challenge_method=S256")!

    private func items(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("adds offline access and forced consent")
    func addsOfflineAccess() {
        let out = items(LoopbackAuthDelegate.applying(GoogleOfflineAccess.queryItems, to: base))
        #expect(out["access_type"] == "offline")
        #expect(out["prompt"] == "consent")
    }

    @Test("leaves the SDK's own parameters untouched")
    func preservesExistingParameters() {
        let out = items(LoopbackAuthDelegate.applying(GoogleOfflineAccess.queryItems, to: base))
        #expect(out["client_id"] == "abc")
        #expect(out["scope"] == "x")
        #expect(out["state"] == "s")
        #expect(out["code_challenge"] == "c")
        #expect(out["code_challenge_method"] == "S256")
    }

    @Test("never overrides a parameter the SDK already set")
    func doesNotOverrideExisting() {
        // Overriding `scope` or `state` would break the exchange outright.
        let hostile = [URLQueryItem(name: "scope", value: "https://mail.google.com/"),
                       URLQueryItem(name: "state", value: "attacker")]
        let out = items(LoopbackAuthDelegate.applying(hostile, to: base))
        #expect(out["scope"] == "x")
        #expect(out["state"] == "s")
    }

    @Test("no extras means the URL is returned unchanged")
    func emptyIsIdentity() {
        #expect(LoopbackAuthDelegate.applying([], to: base) == base)
    }

    @Test("handles a URL that has no query string yet")
    func addsToBareURL() {
        let bare = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let out = items(LoopbackAuthDelegate.applying(GoogleOfflineAccess.queryItems, to: bare))
        #expect(out["access_type"] == "offline")
        #expect(out["prompt"] == "consent")
    }

    @Test("only Gmail gets the Google-specific parameters")
    func otherServersAreUnaffected() {
        // The delegate defaults to no extras, so Notion/Linear/HubSpot flows are
        // byte-identical to before this change.
        let delegate = LoopbackAuthDelegate(port: 50000)
        #expect(delegate.extraQueryItems.isEmpty)
        #expect(LoopbackAuthDelegate.applying(delegate.extraQueryItems, to: base) == base)
    }
}

@Suite("Gmail catalog entry")
struct GmailCatalogTests {
    @Test("absent unless its own client credentials are configured")
    func gatedOnCredentials() {
        let hasCreds = !Config.gmailClientID.isEmpty && !Config.gmailClientSecret.isEmpty
        if !hasCreds {
            #expect(MCPCatalog.gmail == nil)
        } else {
            #expect(MCPCatalog.gmail?.id == "gmail")
        }
    }

    @Test("points at Google's hosted MCP endpoint over https")
    func endpoint() {
        // Built without going through Config, so the assertion holds in a build
        // that has no Gmail credentials baked in.
        let descriptor = MCPServerDescriptor(
            id: "gmail", name: "Gmail",
            endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!,
            symbol: "envelope", isCustom: false,
            fixedClientID: "id", fixedClientSecret: "secret")
        #expect(descriptor.endpoint.scheme == "https")
        #expect(descriptor.endpoint.host == "gmailmcp.googleapis.com")
        // Google Desktop clients accept any loopback port, so unlike HubSpot et
        // al. this must NOT pin one — pinning would collide with a busy port
        // for no benefit.
        #expect(descriptor.fixedLoopbackPort == nil)
    }

    @Test("does not reuse the app's own Google client")
    func usesASeparateClient() {
        // Same client would mean same consent screen, which would drag sign-in
        // and the Calendar/Docs/Sheets grant into Gmail's Restricted tier.
        guard !Config.gmailClientID.isEmpty, !Config.googleClientID.isEmpty else { return }
        #expect(Config.gmailClientID != Config.googleClientID)
    }
}
