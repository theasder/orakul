import Foundation
import Testing
@testable import MeetGPT

/// Recall is a new source of OLD meeting content in an outbound request, and
/// that is the part worth checking twice.
///
/// Everything else the model sees comes from the call in progress, which the
/// user is watching. A recall block quotes meetings from weeks ago — text the
/// user is not looking at and may have forgotten contains a client's name or a
/// personal address. If redaction covered the live transcript but missed this,
/// the feature would quietly widen what leaves the Mac, which is the one
/// promise this product cannot afford to break.
@Suite("Recall respects outbound redaction")
struct RecallRedactionTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private let embedder = HashingSkillTextEmbedder()

    @Test("a term the user redacts is stripped from a recall excerpt too")
    func userTermsRedactedInRecall() throws {
        let store = try scratchStore()
        let started = Date().addingTimeInterval(-5 * 86_400)
        try store.save(SavedSession(
            id: UUID(), title: "Renewal call", startedAt: started, savedAt: started,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to extend the Northwind contract for twelve months."))

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about the contract",
            store: store, embedder: embedder))
        #expect(block.contains("Northwind"), "precondition: the excerpt carries the name")

        // The same filter every outbound request goes through — RedactingGateway
        // wraps the outermost gateway and redacts system and user together.
        let cleaned = OutboundRedactor.redact(block, userTerms: ["Northwind"]).text
        #expect(!cleaned.contains("Northwind"),
                "a redacted term must not reach the model through recall either")
    }

    @Test("built-in detectors cover recalled content, not just the live call")
    func builtInDetectorsApplyToRecall() throws {
        // A secret spoken months ago and recalled today is the same secret. The
        // detectors are for payment cards, API keys, government IDs and
        // credentials — NOT email addresses, deliberately: attendee addresses
        // are load-bearing context here (they seed the glossary and the brief),
        // and stripping them would break features while protecting nothing the
        // user did not already choose to record.
        let store = try scratchStore()
        let started = Date().addingTimeInterval(-9 * 86_400)
        try store.save(SavedSession(
            id: UUID(), title: "Vendor intro", startedAt: started, savedAt: started,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to rotate the vendor key sk-live-4eC39HqLyjWDarjtT1zdp7dc in June."))

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about the vendor key rotation",
            store: store, embedder: embedder))
        let cleaned = OutboundRedactor.redact(block, userTerms: []).text
        #expect(!cleaned.contains("sk-live-4eC39HqLyjWDarjtT1zdp7dc"),
                "a key recalled from an old meeting is still a key")
        #expect(cleaned.contains(OutboundRedactor.marker))
    }

    @Test("redaction does not empty the block or destroy its instructions")
    func redactionLeavesAUsableBlock() throws {
        let store = try scratchStore()
        let started = Date().addingTimeInterval(-2 * 86_400)
        try store.save(SavedSession(
            id: UUID(), title: "Pricing sync", startedAt: started, savedAt: started,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to move to usage-based pricing at two cents per credit."))

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about pricing",
            store: store, embedder: embedder))
        let cleaned = OutboundRedactor.redact(block, userTerms: []).text
        // The model still needs to know what this block is and how to use it —
        // redaction that ate the instructions would turn a grounded answer into
        // an ungrounded one, which is worse than not recalling at all.
        #expect(cleaned.contains("PRIOR-MEETING RECORD"))
        #expect(cleaned.contains("Pricing sync"))
        #expect(cleaned.contains("usage-based pricing"))
    }
}
