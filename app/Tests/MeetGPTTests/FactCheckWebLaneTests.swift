import Testing
import Foundation
@testable import MeetGPT

/// Item 11, app half — the web lane's client contracts.
///
/// Four things hold or the lane is unsafe to ship:
///   - `searchWeb` rides the request body ONLY when true (the never-silent rule
///     as wire format: a background check's body is byte-identical to before);
///   - the response's `search` block and per-claim provenance decode, and a
///     legacy response without them still decodes (fact-check responses are
///     also persisted in saved sessions);
///   - a web `sourceUrl` is kept only for http(s) — a `javascript:` link inside
///     a claim card would hand attacker-influenceable web content a click;
///   - `FactClaim`'s new fields survive a Codable round-trip AND their absence
///     in a pre-web-lane session does not fail the decode.
@Suite("Fact-check web lane (client)")
struct FactCheckWebLaneTests {

    // MARK: Request body

    @Test("searchWeb rides the body only when true")
    func searchWebSentOnlyWhenTrue() {
        let on = FactCheckService.backendPayload(
            transcript: "t", context: "c", extraGuidance: nil, searchWeb: true)
        #expect(on["searchWeb"] as? Bool == true)
        // Absent, not false: an ordinary check's body is byte-identical to the
        // pre-web-lane wire format.
        let off = FactCheckService.backendPayload(
            transcript: "t", context: "c", extraGuidance: nil, searchWeb: false)
        #expect(off["searchWeb"] == nil)
        #expect(off["guidance"] == nil)
        #expect(off["transcript"] as? String == "t")
    }

    // MARK: Response decode

    private func decode(_ json: String) throws -> FactCheckService.Response {
        try JSONDecoder().decode(FactCheckService.Response.self, from: Data(json.utf8))
    }

    @Test("a web-lane response decodes the search block and per-claim provenance")
    func decodesWebLaneResponse() throws {
        let decoded = try decode("""
        {"claims":[{"claim":"the market grew 40%","status":"verified",
          "explanation":"a page supports it","source":"grew 40% last quarter",
          "provenance":"web","sourceUrl":"https://example.com/a","sourceTitle":"Market report"}],
         "search":{"ran":true,"reason":null,
          "sources":[{"url":"https://example.com/a","title":"Market report"}],"credits":3}}
        """)
        #expect(decoded.search?.ran == true)
        #expect(decoded.search?.credits == 3)
        #expect(decoded.search?.sources?.first?.url == "https://example.com/a")
        let item = try #require(decoded.claims?.first)
        let claim = try #require(FactCheckService.map(item))
        #expect(claim.isWebChecked)
        #expect(claim.sourceUrl == "https://example.com/a")
        #expect(claim.sourceTitle == "Market report")
    }

    @Test("a did-not-run search block carries its reason")
    func decodesNotConfiguredReason() throws {
        let decoded = try decode("""
        {"claims":[],"search":{"ran":false,"reason":"Web search is not configured on this server.","sources":[],"credits":0}}
        """)
        #expect(decoded.search?.ran == false)
        #expect(decoded.search?.reason?.contains("not configured") == true)
    }

    @Test("a legacy response without the web lane still decodes")
    func decodesLegacyResponse() throws {
        let decoded = try decode("""
        {"claims":[{"claim":"c","status":"verified","explanation":"e","source":"s"}]}
        """)
        #expect(decoded.search == nil)
        let item = try #require(decoded.claims?.first)
        let claim = try #require(FactCheckService.map(item))
        #expect(claim.provenance == nil)
        #expect(!claim.isWebChecked)
    }

    // MARK: URL scheme guard

    @Test("a non-http(s) sourceUrl is dropped, the claim survives")
    func dropsUnsafeSourceURL() throws {
        for bad in ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd"] {
            let claim = try #require(FactCheckService.map(.init(
                claim: "c", status: "verified", explanation: "e", source: "s",
                confidence: nil, counterQuestion: nil,
                provenance: "web", sourceUrl: bad, sourceTitle: "T")))
            #expect(claim.sourceUrl == nil, Comment(rawValue: bad))
            #expect(claim.isWebChecked) // provenance label survives; only the link dies
        }
    }

    // MARK: Persistence

    @Test("a session saved before the web lane still decodes")
    func decodesLegacyPersistedClaim() throws {
        let legacy = """
        {"text":"the ARR claim","status":"verified","explanation":"e","source":"s"}
        """
        let claim = try JSONDecoder().decode(FactClaim.self, from: Data(legacy.utf8))
        #expect(claim.provenance == nil)
        #expect(claim.sourceUrl == nil)
        #expect(!claim.isWebChecked)
    }

    @Test("the new fields survive a Codable round-trip")
    func roundTripsWebFields() throws {
        let original = FactClaim(
            text: "t", status: .verified, explanation: "e", source: "s",
            provenance: "web", sourceUrl: "https://example.com/a", sourceTitle: "A")
        let decoded = try JSONDecoder().decode(
            FactClaim.self, from: JSONEncoder().encode(original))
        #expect(decoded.provenance == "web")
        #expect(decoded.sourceUrl == "https://example.com/a")
        #expect(decoded.sourceTitle == "A")
        #expect(decoded.isWebChecked)
    }
}

// MARK: - AppState plumbing

/// A capturing fact-check provider: records every request AppState sends and
/// answers with a fixed outcome, so the searchWeb plumbing is observable
/// without a backend.
private final class CapturingFactCheckProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var requestsStorage: [AppState.FactCheckProviderRequest] = []
    let search: FactCheckService.WebSearchOutcome?

    init(search: FactCheckService.WebSearchOutcome? = nil) {
        self.search = search
    }

    var requests: [AppState.FactCheckProviderRequest] {
        lock.withLock { requestsStorage }
    }

    func respond(
        to request: AppState.FactCheckProviderRequest
    ) -> (claims: [FactClaim], search: FactCheckService.WebSearchOutcome?) {
        lock.withLock { requestsStorage.append(request) }
        return ([FactClaim(text: "the vendor date claim", status: .needsContext,
                           explanation: "not in context", source: nil)], search)
    }
}

/// The searchWeb PLUMBING: the sheet's button intent must reach the service as
/// `searchWeb: true`, an ordinary run must not, and the search outcome must be
/// stored for the sheet (and cleared when a new run starts). Driven through a
/// real AppState so the enforcement point — only runFactCheck's parameter, no
/// ambient state — is what's under test.
@MainActor
@Suite("Fact-check searchWeb plumbing", .serialized)
struct FactCheckPlumbingTests {

    private func makeState(provider: CapturingFactCheckProvider) -> AppState {
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            factCheckProvider: { request, _ in provider.respond(to: request) },
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        state.applyTestWorkspace(recording: true)
        state.callGoal = "De-risk the rollout"
        state.transcript = [TranscriptEntry(
            source: .mic,
            text: "The vendor has not confirmed the delivery date for Friday's rollout.")]
        return state
    }

    private func waitUntil(
        iterations: Int = 4_000, _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return predicate()
    }

    @Test("the sheet's button intent reaches the service as searchWeb true, and the outcome is stored")
    func buttonPathPassesSearchWebTrue() async {
        let outcome = FactCheckService.WebSearchOutcome(
            ran: true, reason: nil,
            sources: [.init(url: "https://example.com/a", title: "A")], credits: 3)
        let provider = CapturingFactCheckProvider(search: outcome)
        let state = makeState(provider: provider)

        state.runFactCheck(searchWeb: true)

        #expect(await waitUntil { provider.requests.count >= 1 })
        #expect(provider.requests.first?.searchWeb == true)
        #expect(await waitUntil { state.factCheckSearch == outcome })
        #expect(await waitUntil { !state.factClaims.isEmpty })
    }

    @Test("an ordinary run passes searchWeb false and clears a stale outcome")
    func defaultRunPassesFalseAndClears() async {
        let provider = CapturingFactCheckProvider(search: nil)
        let state = makeState(provider: provider)
        // A stale outcome from an earlier web-checked run must not survive into
        // a fresh, non-web run's sheet.
        state.factCheckSearch = FactCheckService.WebSearchOutcome(
            ran: true, reason: nil, sources: [], credits: 3)

        state.runFactCheck()

        #expect(await waitUntil { provider.requests.count >= 1 })
        #expect(provider.requests.first?.searchWeb == false)
        #expect(await waitUntil { state.factCheckSearch == nil })
    }
}
