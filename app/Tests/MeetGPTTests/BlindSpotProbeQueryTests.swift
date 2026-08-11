import Testing
import Foundation
@testable import MeetGPT

/// Item 10, design #2 — the client half of the connector probeQuery.
///
/// Two contracts matter here and nothing else in the app asserts them:
///   - a brainstorm response carrying a top-level `probeQuery` decodes it, and a
///     response WITHOUT one (every response shipped before this change) still
///     decodes to nil rather than failing — the same optional-field trap that
///     once broke saved-session decoding.
///   - a request opts OUT of asking for a query by default, so the post-call
///     reflection pass and any other caller do not silently turn it on.
@Suite("Blind-spot probeQuery (client)")
struct BlindSpotProbeQueryTests {
    private func decode(_ json: String) throws -> BrainstormService.BackendResponse {
        try JSONDecoder().decode(BrainstormService.BackendResponse.self, from: Data(json.utf8))
    }

    @Test("a response with probeQuery decodes it")
    func decodesProbeQuery() throws {
        let decoded = try decode("""
        {"suggestions":[],"probeQuery":"Acme renewal history missed deadline"}
        """)
        #expect(decoded.probeQuery == "Acme renewal history missed deadline")
    }

    @Test("a response without probeQuery still decodes, to nil")
    func decodesLegacyResponse() throws {
        let decoded = try decode("""
        {"suggestions":[{"title":"Ask about legal","detail":"d","kind":"question","evidence":"e"}]}
        """)
        #expect(decoded.probeQuery == nil)
        #expect(decoded.suggestions?.count == 1)
    }

    @Test("SuggestionResult defaults probeQuery to nil")
    func resultDefaultsNil() {
        let result = BrainstormService.SuggestionResult(suggestions: [], execution: nil)
        #expect(result.probeQuery == nil)
    }

    @Test("SuggestionResult carries a probeQuery when given one")
    func resultCarriesQuery() {
        let result = BrainstormService.SuggestionResult(
            suggestions: [], execution: nil, probeQuery: "look this up")
        #expect(result.probeQuery == "look this up")
    }

    @Test("a BlindSpotProviderRequest opts out of probing by default")
    func requestDefaultsCanProbeFalse() {
        let request = AppState.BlindSpotProviderRequest(
            goal: "g", transcript: "t", priorTitles: [], accessToken: nil,
            guidance: nil, context: nil, probe: "", theme: "general", grounded: false)
        #expect(request.canProbe == false)
    }

    // MARK: The wire body

    private func payload(canProbe: Bool) -> [String: Any] {
        BrainstormService.backendPayload(
            goal: "g", transcript: "t", priorTitles: ["p"],
            extraGuidance: nil, context: nil, probe: nil,
            theme: nil, grounded: false, canProbe: canProbe)
    }

    @Test("canProbe rides the body only when true")
    func canProbeSentOnlyWhenTrue() {
        #expect(payload(canProbe: true)["canProbe"] as? Bool == true)
        // Absent, not false: a user without connectors sends a body
        // byte-identical to the pre-probeQuery wire format.
        #expect(payload(canProbe: false)["canProbe"] == nil)
    }

    @Test("empty optional fields are omitted from the body")
    func optionalsOmitted() {
        let body = payload(canProbe: false)
        #expect(body["guidance"] == nil)
        #expect(body["context"] == nil)
        #expect(body["probe"] == nil)
        #expect(body["theme"] == nil)
        #expect(body["goal"] as? String == "g")
        #expect(body["priorSuggestions"] as? [String] == ["p"])
    }
}
