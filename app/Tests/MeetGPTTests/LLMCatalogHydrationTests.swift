import Foundation
import Testing
@testable import MeetGPT

/// M6b — the mac catalog hydrates from the backend (GET /api/llm/models) with the
/// static table as the offline fallback. Mutating shared static state → serialized
/// suite + resetHydration() after each test.
final class CatalogMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let responder = CatalogMockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("LLMCatalog hydration", .serialized)
struct LLMCatalogHydrationTests {
    private func entry(_ id: String, _ provider: String, _ tier: String, _ vision: Bool = true) -> LLMCatalog.CatalogEntry {
        LLMCatalog.CatalogEntry(id: id, provider: provider, minTier: tier, supportsVision: vision)
    }

    @Test("maps entries: known id keeps its label, unknown id uses the id, order preserved")
    func mapping() {
        let models = LLMCatalog.models(from: [
            entry("gpt-5.4-mini", "openai", "free"),
            entry("brand-new-model", "anthropic", "premium", false),
        ])
        #expect(models.count == 2)
        #expect(models[0].label == "GPT-5.4 mini")            // known → polished label
        #expect(models[1].id == "brand-new-model")
        #expect(models[1].label == "brand-new-model")          // unknown → id as label
        #expect(models[1].provider == .anthropic)
        #expect(models[1].minTier == .premium)
        #expect(models[1].supportsVision == false)
    }

    @Test("drops entries with an unmappable provider or tier (client can't route them)")
    func dropsUnroutable() {
        let models = LLMCatalog.models(from: [
            entry("ok", "openai", "pro"),
            entry("bad-provider", "skynet", "pro"),
            entry("bad-tier", "openai", "titanium"),
        ])
        #expect(models.map(\.id) == ["ok"])
    }

    @Test("applyHydration replaces `all`; an empty map is ignored (never blanks the picker)")
    func apply() {
        defer { LLMCatalog.resetHydration() }
        LLMCatalog.applyHydration([entry("gpt-5.4", "openai", "pro")])
        #expect(LLMCatalog.all.map(\.id) == ["gpt-5.4"])

        LLMCatalog.applyHydration([entry("nope", "skynet", "pro")]) // all drop → empty → ignored
        #expect(LLMCatalog.all.map(\.id) == ["gpt-5.4"])            // previous hydration stands
    }

    @Test("hydrate() adopts a 200 catalog; resetHydration reverts to the fallback")
    func hydrateOnline() async {
        defer { LLMCatalog.resetHydration(); CatalogMockURLProtocol.responder = nil }
        let json = #"{"models":[{"id":"gpt-5.4-mini","provider":"openai","minTier":"free","supportsVision":true}]}"#
        CatalogMockURLProtocol.responder = { _ in (200, Data(json.utf8)) }
        await LLMCatalog.hydrate(baseURL: "https://api.example.com", session: CatalogMockURLProtocol.session())
        #expect(LLMCatalog.all.map(\.id) == ["gpt-5.4-mini"])
        LLMCatalog.resetHydration()
        #expect(LLMCatalog.all.count == LLMCatalog.fallback.count)  // back to offline table
    }

    @Test("offline hydrate leaves the fallback intact")
    func hydrateOffline() async {
        defer { LLMCatalog.resetHydration(); CatalogMockURLProtocol.responder = nil }
        CatalogMockURLProtocol.responder = nil // → connection error
        await LLMCatalog.hydrate(baseURL: "https://api.example.com", session: CatalogMockURLProtocol.session())
        #expect(LLMCatalog.all.count == LLMCatalog.fallback.count)
    }

    @Test("the offline fallback still lists every tier (no empty picker without a backend)")
    func fallbackComplete() {
        LLMCatalog.resetHydration()
        #expect(LLMCatalog.all.contains { $0.minTier == .free })
        #expect(LLMCatalog.all.contains { $0.minTier == .premium })
    }
}
