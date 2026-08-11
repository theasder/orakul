import Foundation

/// A connectable MCP server hosted by a work app. Connection is keyless:
/// OAuth 2.1 with PKCE + dynamic client registration (RFC 7591) — no API keys,
/// no client secrets, no backend.
struct MCPServerDescriptor: Identifiable, Codable, Equatable {
    let id: String        // stable key, e.g. "notion" — also the Keychain account suffix
    var name: String
    var endpoint: URL     // the Streamable HTTP MCP endpoint
    var symbol: String    // SF Symbol for the row
    var isCustom: Bool
    /// Some servers (live-probed: HubSpot) support PKCE but NOT dynamic client
    /// registration — they need a pre-registered app. When set, OAuth runs as
    /// a confidential client with these credentials and a FIXED loopback port
    /// (their consoles require exact redirect URIs, so no random ports).
    var fixedClientID: String?
    var fixedClientSecret: String?
    var fixedLoopbackPort: UInt16?
    /// Names people actually search for, when they differ from `name`.
    ///
    /// Several vendors sell one MCP server covering several products, so the
    /// product someone wants is not the row they are scanning for: Jira lives
    /// behind "Atlassian", wikis behind "Notion". Without aliases the honest
    /// answer to "why is there no Jira?" is "it is there, you could not find
    /// it" — which is the same as it not being there.
    var keywords: [String]

    init(id: String, name: String, endpoint: URL, symbol: String, isCustom: Bool,
         keywords: [String] = [],
         fixedClientID: String? = nil, fixedClientSecret: String? = nil,
         fixedLoopbackPort: UInt16? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.symbol = symbol
        self.isCustom = isCustom
        self.fixedClientID = fixedClientID
        self.fixedClientSecret = fixedClientSecret
        self.fixedLoopbackPort = fixedLoopbackPort
        self.keywords = keywords
    }

    /// Whether this server answers to a search term, by name or alias.
    func matches(search term: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if name.lowercased().contains(needle) { return true }
        return keywords.contains { $0.lowercased().contains(needle) }
    }
}

/// Credential-independent inventory entry for a hosted MCP provider. Keeping
/// gated providers here means tests and diagnostics can verify every endpoint
/// even when that build intentionally has no OAuth client secret baked in.
struct MCPProviderContract: Equatable {
    enum Registration: Equatable {
        case dynamicClientRegistration
        case preRegistered(loopbackPort: UInt16?)
    }

    let descriptor: MCPServerDescriptor
    let registration: Registration

    var id: String { descriptor.id }
}

/// Built-in catalog of popular work apps with hosted MCP servers.
///
/// Every endpoint below was live-verified (2026-07): responds to an MCP
/// initialize POST with a spec-compliant 401 + WWW-Authenticate challenge, and
/// its authorization server advertises PKCE S256 + `none` token auth + an open
/// registration endpoint — i.e. arbitrary third-party clients like us may
/// connect. Adding an app = adding a line (plus users can add custom servers).
enum MCPCatalog {
    static let builtIn: [MCPServerDescriptor] = [
        MCPServerDescriptor(id: "notion", name: "Notion",
                            endpoint: URL(string: "https://mcp.notion.com/mcp")!,
                            symbol: "note.text", isCustom: false, keywords: ["wiki", "docs", "pages", "knowledge base"]),
        MCPServerDescriptor(id: "fireflies", name: "Fireflies",
                            endpoint: URL(string: "https://api.fireflies.ai/mcp")!,
                            symbol: "flame.fill", isCustom: false, keywords: ["transcripts", "meeting notes", "recordings"]),
        MCPServerDescriptor(id: "linear", name: "Linear",
                            endpoint: URL(string: "https://mcp.linear.app/mcp")!,
                            symbol: "line.3.horizontal.decrease.circle", isCustom: false, keywords: ["issues", "tickets", "backlog", "sprint"]),
        MCPServerDescriptor(id: "asana", name: "Asana",
                            endpoint: URL(string: "https://mcp.asana.com/mcp")!,
                            symbol: "checklist", isCustom: false, keywords: ["tasks", "projects", "to-do"]),
        MCPServerDescriptor(id: "atlassian", name: "Atlassian · Jira & Confluence",
                            endpoint: URL(string: "https://mcp.atlassian.com/v1/mcp/authv2")!,
                            symbol: "square.grid.2x2", isCustom: false, keywords: ["jira", "confluence", "issues", "tickets", "sprint", "backlog", "wiki"]),
        MCPServerDescriptor(id: "intercom", name: "Intercom",
                            endpoint: URL(string: "https://mcp.intercom.com/mcp")!,
                            symbol: "bubble.left.and.bubble.right", isCustom: false, keywords: ["support", "helpdesk", "tickets", "conversations"]),
        MCPServerDescriptor(id: "sentry", name: "Sentry",
                            endpoint: URL(string: "https://mcp.sentry.dev/mcp")!,
                            symbol: "shield.lefthalf.filled", isCustom: false, keywords: ["errors", "crashes", "incidents", "bugs"]),
        // Live-probed 2026-07: 401 + WWW-Authenticate, PRM at
        // /.well-known/oauth-protected-resource/api/mcp/mcp, open DCR, PKCE S256.
        // Zapier is the meta-connector: Salesforce and thousands of other apps
        // reach MeetGPT through it.
        MCPServerDescriptor(id: "zapier", name: "Zapier",
                            endpoint: URL(string: "https://mcp.zapier.com/api/mcp/mcp")!,
                            symbol: "bolt.horizontal.circle", isCustom: false, keywords: ["salesforce", "automation", "integrations", "webhooks"]),
        // Live-probed 2026-07: 401 challenge, AS app.attio.com, open DCR, S256.
        MCPServerDescriptor(id: "attio", name: "Attio",
                            endpoint: URL(string: "https://mcp.attio.com/mcp")!,
                            symbol: "person.2.crop.square.stack", isCustom: false, keywords: ["crm", "contacts", "deals", "pipeline"]),

        // Product analytics. These matter more than their tool count suggests:
        // they are the only connectors that can CONTRADICT the room with data.
        // "Users love the export flow" is an opinion until someone checks how
        // many ran an export last week, and no transcript contains that number.
        //
        // All three live-probed 2026-07 — 401 + WWW-Authenticate carrying
        // resource_metadata, PKCE S256, and an OPEN registration endpoint, so
        // they connect keyless with no pre-registered app and no credentials in
        // mac/.env:
        //   PostHog   AS oauth.posthog.com   DCR /oauth/register/
        //   Amplitude AS mcp.amplitude.com   DCR /register
        //   Mixpanel  AS mcp.mixpanel.com    DCR /oauth/mcp/register/
        //     (Mixpanel publishes AS metadata per-path, at
        //      /.well-known/oauth-authorization-server/mcp, not at the root.)
        MCPServerDescriptor(id: "posthog", name: "PostHog",
                            endpoint: URL(string: "https://mcp.posthog.com/mcp")!,
                            symbol: "chart.bar.xaxis", isCustom: false, keywords: ["analytics", "product analytics", "events", "funnels"]),
        MCPServerDescriptor(id: "amplitude", name: "Amplitude",
                            endpoint: URL(string: "https://mcp.amplitude.com/mcp")!,
                            symbol: "waveform.path.ecg", isCustom: false, keywords: ["analytics", "product analytics", "events", "funnels"]),
        MCPServerDescriptor(id: "mixpanel", name: "Mixpanel",
                            endpoint: URL(string: "https://mcp.mixpanel.com/mcp")!,
                            symbol: "chart.dots.scatter", isCustom: false, keywords: ["analytics", "product analytics", "events", "funnels"]),
    ]

    /// Contracts for providers whose OAuth clients must be configured by the
    /// app operator. Their descriptors deliberately contain no credentials;
    /// the computed catalog properties below attach credentials only when both
    /// halves are present.
    private static let preRegisteredContracts: [MCPProviderContract] = [
        MCPProviderContract(
            descriptor: MCPServerDescriptor(
                id: "hubspot", name: "HubSpot",
                endpoint: URL(string: "https://mcp.hubspot.com/")!,
                symbol: "person.crop.square.filled.and.at.rectangle",
                isCustom: false,
                keywords: ["crm", "deals", "pipeline", "contacts", "marketing"],
                fixedLoopbackPort: 52700),
            registration: .preRegistered(loopbackPort: 52700)),
        MCPProviderContract(
            descriptor: MCPServerDescriptor(
                id: "affinity", name: "Affinity",
                endpoint: URL(string: "https://mcp.affinity.co/mcp")!,
                symbol: "chart.line.uptrend.xyaxis.circle",
                isCustom: false,
                keywords: ["crm", "deals", "pipeline", "investors"],
                fixedLoopbackPort: 52701),
            registration: .preRegistered(loopbackPort: 52701)),
        MCPProviderContract(
            descriptor: MCPServerDescriptor(
                id: "zoom", name: "Zoom",
                endpoint: URL(string: "https://mcp-us.zoom.us/mcp/zoom/streamable")!,
                symbol: "video", isCustom: false,
                keywords: ["meetings", "calls", "recordings", "video"],
                fixedLoopbackPort: 52702),
            registration: .preRegistered(loopbackPort: 52702)),
        MCPProviderContract(
            descriptor: MCPServerDescriptor(
                id: "gmail", name: "Gmail",
                endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!,
                symbol: "envelope", isCustom: false,
                keywords: ["email", "mail", "inbox"]),
            registration: .preRegistered(loopbackPort: nil)),
        MCPProviderContract(
            descriptor: MCPServerDescriptor(
                id: "google-analytics", name: "Google Analytics",
                endpoint: URL(string: "https://analyticsdata.googleapis.com/mcp/v1")!,
                symbol: "chart.line.uptrend.xyaxis",
                isCustom: false,
                keywords: ["ga4", "analytics", "web analytics", "traffic"]),
            registration: .preRegistered(loopbackPort: nil)),
    ]

    /// Complete, credential-independent provider contract inventory. This is
    /// the canonical audit/test surface: credential gating changes visibility,
    /// never the provider ID, endpoint, registration mode or callback port.
    static let providerContracts: [MCPProviderContract] =
        builtIn.map {
            MCPProviderContract(descriptor: $0, registration: .dynamicClientRegistration)
        } + preRegisteredContracts

    /// Servers that speak MCP + PKCE but require a pre-registered app (no open
    /// DCR) — each appears only when its client credentials are baked in.
    static var preRegistered: [MCPServerDescriptor] {
        [hubSpot, affinity, zoom, gmail, googleAnalytics].compactMap { $0 }
    }

    /// Google's own hosted GA4 Data API MCP (live-probed 2026-07:
    /// https://analyticsdata.googleapis.com/mcp/v1 — tools run_report,
    /// get_metadata, run_realtime_report, check_compatibility; AS
    /// accounts.google.com; NO open DCR → pre-registered app).
    ///
    /// The DATA endpoint, not the admin one. `analyticsadmin.googleapis.com/mcp`
    /// exists and lists twelve tools, but they describe configuration — property
    /// names, data streams, retention settings — and none of that settles an
    /// argument in a meeting. `run_report` does: it is what checks "users love the
    /// export flow" against how many actually ran one.
    ///
    /// Behaves like the Gmail MCP: `initialize` answers 200 without a token and
    /// only `tools/call` challenges, with a per-path `resource_metadata`.
    ///
    /// Its own client, deliberately. The server offers `analytics` as well as
    /// `analytics.readonly`, and plain `analytics` is READ-WRITE over your GA
    /// configuration — see GoogleAnalyticsLeastPrivilegeOAuthScopeSelector, which
    /// refuses it. Keeping this on a separate Cloud project also means that if
    /// Google classifies the scope as Restricted rather than Sensitive, the CASA
    /// obligation lands here and not on sign-in.
    static var googleAnalytics: MCPServerDescriptor? {
        configuredDescriptor(
            id: "google-analytics",
            clientID: Config.googleAnalyticsClientID,
            clientSecret: Config.googleAnalyticsClientSecret)
    }

    /// Google's own hosted Gmail MCP (live-probed 2026-07:
    /// https://gmailmcp.googleapis.com/mcp/v1, AS accounts.google.com, PKCE
    /// S256, client_secret_post, NO open DCR → pre-registered app).
    ///
    /// Two things about this server are unlike the rest of the catalog:
    ///
    /// 1. `initialize` and `tools/list` answer **200 without a token** — it
    ///    only challenges on `tools/call`. So authorization happens on first
    ///    use, not at connect. The transport's 401 handler covers this; the
    ///    challenge carries `resource_metadata`, which is per-tool
    ///    (`/.well-known/oauth-protected-resource/<tool>`) because each tool
    ///    declares its own scopes.
    /// 2. Its scopes are Gmail scopes, and every one that reads mail is
    ///    RESTRICTED under Google's API Services User Data Policy — publishing
    ///    them means an annual third-party CASA assessment. That is why this
    ///    uses its OWN client (GMAIL_CLIENT_ID) rather than the app's
    ///    GOOGLE_CLIENT_ID: verification tiers are per-consent-screen, so
    ///    keeping Gmail on a separate Cloud project leaves sign-in and the
    ///    Calendar/Docs/Sheets grant in the cheaper Sensitive tier.
    ///
    /// No fixed loopback port: Google Desktop clients accept any 127.0.0.1
    /// port without registering it, so the random port is fine here.
    static var gmail: MCPServerDescriptor? {
        configuredDescriptor(
            id: "gmail",
            clientID: Config.gmailClientID,
            clientSecret: Config.gmailClientSecret)
    }

    /// HubSpot's hosted MCP (live-probed: https://mcp.hubspot.com/, PKCE S256,
    /// NO dynamic client registration → needs a pre-registered HubSpot app).
    /// Appears in the catalog only when HUBSPOT_CLIENT_ID/SECRET are set in
    /// mac/.env; register `http://127.0.0.1:52700/callback` as the app's
    /// redirect URL in the HubSpot developer console.
    static var hubSpot: MCPServerDescriptor? {
        configuredDescriptor(
            id: "hubspot",
            clientID: Config.hubSpotClientID,
            clientSecret: Config.hubSpotClientSecret)
    }

    /// Affinity's hosted MCP (live-probed 2026-07: https://mcp.affinity.co/mcp,
    /// AS login.affinity.co, PKCE S256, NO open DCR → pre-registered app).
    /// Register `http://127.0.0.1:52701/callback` as the app's redirect URL.
    static var affinity: MCPServerDescriptor? {
        configuredDescriptor(
            id: "affinity",
            clientID: Config.affinityClientID,
            clientSecret: Config.affinityClientSecret)
    }

    /// Zoom's hosted MCP (live-probed 2026-07: mcp-us.zoom.us, AS zoom.us,
    /// PKCE S256, NO open DCR → pre-registered Zoom app). Scopes include
    /// meeting search, AI Companion search, and cloud-recording content.
    /// Register `http://127.0.0.1:52702/callback` as the app's redirect URL.
    static var zoom: MCPServerDescriptor? {
        configuredDescriptor(
            id: "zoom",
            clientID: Config.zoomClientID,
            clientSecret: Config.zoomClientSecret)
    }

    private static func configuredDescriptor(id: String, clientID: String,
                                             clientSecret: String) -> MCPServerDescriptor? {
        guard !clientID.isEmpty, !clientSecret.isEmpty,
              let contract = preRegisteredContracts.first(where: { $0.id == id })
        else { return nil }
        var descriptor = contract.descriptor
        descriptor.fixedClientID = clientID
        descriptor.fixedClientSecret = clientSecret
        return descriptor
    }
}
