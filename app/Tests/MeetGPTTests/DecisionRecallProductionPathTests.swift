import Foundation
import Testing
@testable import MeetGPT

/// F1 through the embedder it actually ships with.
///
/// Every other recall test injects `HashingSkillTextEmbedder` so the maths is
/// deterministic. That leaves the real question untested: production uses
/// `NLSkillTextEmbedder`, which is built `for: .english` and returns nil when
/// Apple's sentence model is missing. `DecisionRecallService` treats a nil
/// query vector as "no hits", so both cases would make the top-RICE feature
/// silently do nothing — and the Russian intent gate would route straight into
/// an English-only model.
@Suite("Decision recall — production path")
struct DecisionRecallProductionPathTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-prod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(_ title: String, _ digest: String, daysAgo: Double = 3) -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(id: UUID(), title: title, startedAt: started, savedAt: started,
                            goal: "", entries: [], aiResponse: "", digest: digest)
    }

    @Test("recall answers an English question through the shipped embedder")
    func englishThroughProductionEmbedder() throws {
        let store = try scratchStore()
        try store.save(session("Pricing sync",
                               "Decided to move to usage-based pricing at two cents per credit."))
        try store.save(session("Hiring pipeline",
                               "Agreed to open two senior backend roles."))

        let hits = DecisionRecallService.recall(
            query: "what did we decide about pricing",
            store: store, embedder: RecallEmbedder.production)
        #expect(hits.first?.sessionTitle == "Pricing sync",
                "the shipped path must answer the question the feature is sold on")
    }

    @Test("recall answers a Russian question, whatever the sentence model supports")
    func russianThroughProductionEmbedder() throws {
        // The intent gate accepts "что мы решили…", so recall must not be an
        // English-only feature behind a bilingual door.
        let store = try scratchStore()
        try store.save(session("Планёрка по тарифам",
                               "Решили перейти на оплату по потреблению: два цента за кредит."))
        try store.save(session("Наём",
                               "Договорились открыть две вакансии бэкенд-разработчиков."))

        let hits = DecisionRecallService.recall(
            query: "что мы решили про тарифы и оплату по потреблению",
            store: store, embedder: RecallEmbedder.production)
        #expect(hits.first?.sessionTitle == "Планёрка по тарифам")
    }

    @Test("an unavailable sentence model degrades to lexical recall, never to silence")
    func fallsBackRatherThanReturningNothing() throws {
        let store = try scratchStore()
        try store.save(session("Platform review",
                               "Decided to sunset the legacy API in June."))

        // Stands in for a Mac where NLEmbedding has no model for the locale:
        // the composite must keep answering rather than quietly returning [].
        let broken = RecallEmbedder(primary: AlwaysNilEmbedder(),
                                    fallback: HashingSkillTextEmbedder())
        let hits = DecisionRecallService.recall(
            query: "when did we decide to sunset the legacy API",
            store: store, embedder: broken)
        #expect(!hits.isEmpty, "a missing model must cost quality, not the feature")
        #expect(hits.first?.excerpt.contains("sunset the legacy API") == true)
    }

    @Test("the composite prefers the sentence model on the language it was built for")
    func primaryWins() {
        let composite = RecallEmbedder(primary: ConstantEmbedder(value: 1),
                                       fallback: ConstantEmbedder(value: 9))
        #expect(composite.embed("we decided to sunset the legacy API in June")?.first == 1)
    }

    @Test("non-English text goes to the lexical embedder, not to an English model's guess")
    func nonEnglishRoutesToFallback() {
        // Measured: NLEmbedding's English sentence model returns a vector for
        // Russian input, and no Russian sentence model exists to fall back to.
        // A nil check alone therefore never reroutes Cyrillic — it just ranks
        // it with an English model's opinion. Language is the honest gate.
        let composite = RecallEmbedder(primary: ConstantEmbedder(value: 1),
                                       fallback: ConstantEmbedder(value: 9))
        #expect(composite.embed("что мы решили про тарифы и оплату")?.first == 9)
        #expect(!composite.usesPrimary(for: "что мы решили про тарифы и оплату"))
        #expect(composite.usesPrimary(for: "what did we decide about pricing"))
    }

    @Test("unrecognisable text still produces a vector rather than nothing")
    func gibberishStillEmbeds() {
        // Short or symbol-heavy queries defeat language detection. Whatever the
        // recogniser says, recall must come back with a ranking rather than an
        // empty answer that reads as "we have no memory of that".
        #expect(RecallEmbedder.production.embed("Q3 ARR?") != nil)
        #expect(RecallEmbedder.production.embed("👋 2026") != nil)
    }
}

/// Never produces a vector — the "model missing" case.
private struct AlwaysNilEmbedder: SkillTextEmbedder {
    func embed(_ text: String) -> [Float]? { nil }
}

/// Produces a recognisable constant so precedence is observable.
private struct ConstantEmbedder: SkillTextEmbedder {
    let value: Float
    func embed(_ text: String) -> [Float]? { [value, 0, 0] }
}
