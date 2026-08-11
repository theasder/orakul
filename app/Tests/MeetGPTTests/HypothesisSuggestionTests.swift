import Testing
import Foundation
@testable import MeetGPT

/// The hypothesis kind, client side. Two things here are load-bearing beyond
/// rendering: suggestions are PERSISTED inside saved sessions, so the new fields
/// must not break decoding of sessions recorded before they existed; and a
/// hypothesis with nothing to test must never reach a card, because the card
/// would show a claim with no way to settle it.
@Suite("Hypothesis suggestions")
struct HypothesisSuggestionTests {
    private let testable = Suggestion(
        title: "Procurement is the real blocker", detail: "Legal named twice, budget never.",
        kind: .hypothesis, evidence: "Legal still needs to look at the liability cap",
        claim: "They will stall at procurement, not on price",
        cheapTest: "Ask who signs once legal clears it, rather than what it costs",
        costOfMissing: "A discount given to solve a problem that was never price")

    // MARK: Persistence

    @Test("a session recorded before hypotheses existed still decodes")
    func decodesLegacyEncodedSuggestion() throws {
        // The exact trap that broke every saved session earlier in this project:
        // a non-optional property with a default is IGNORED by Codable's
        // synthesized init, so adding one fails to decode older data and takes
        // the whole session down with it. All three new fields are optional.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Ask about legal","detail":"d","kind":"question"}
        """
        let decoded = try JSONDecoder().decode(Suggestion.self, from: Data(legacy.utf8))
        #expect(decoded.kind == .question)
        #expect(decoded.claim == nil)
        #expect(decoded.cheapTest == nil)
        #expect(decoded.costOfMissing == nil)
        #expect(decoded.evidence == nil)
    }

    @Test("a hypothesis survives a Codable round-trip with all three fields")
    func roundTrips() throws {
        let data = try JSONEncoder().encode(testable)
        let decoded = try JSONDecoder().decode(Suggestion.self, from: data)
        #expect(decoded == testable)
        #expect(decoded.isTestableHypothesis)
    }

    @Test("the wire value \"hypothesis\" maps to the kind, not silently to advice")
    func kindDecodesFromWireValue() throws {
        // Before the case existed, SuggestionKind(rawValue: "hypothesis") returned
        // nil and the mapper fell back to .advice — so hypotheses arrived and were
        // flattened, losing every extra field without a trace.
        #expect(SuggestionKind(rawValue: "hypothesis") == .hypothesis)
        #expect(SuggestionKind(rawValue: "missing_info") == .missingInfo)
    }

    // MARK: The testability gate

    @Test("a hypothesis with no test is not treated as one")
    func untestableIsNotAHypothesis() {
        // A claim with nothing to say is a hunch the user cannot act on. It may
        // still render as advice; it must not render as a hypothesis.
        let noTest = Suggestion(title: "t", detail: "d", kind: .hypothesis,
                                claim: "They will stall", cheapTest: nil)
        let noClaim = Suggestion(title: "t", detail: "d", kind: .hypothesis,
                                 claim: nil, cheapTest: "Ask who signs this")
        let blank = Suggestion(title: "t", detail: "d", kind: .hypothesis,
                               claim: "   ", cheapTest: "   ")
        #expect(!noTest.isTestableHypothesis)
        #expect(!noClaim.isTestableHypothesis)
        #expect(!blank.isTestableHypothesis)
    }

    @Test("the other kinds are never mistaken for hypotheses")
    func otherKindsAreNotHypotheses() {
        for kind in [SuggestionKind.question, .risk, .missingInfo, .advice] {
            let suggestion = Suggestion(title: "t", detail: "d", kind: kind,
                                        claim: "smuggled", cheapTest: "smuggled test")
            #expect(!suggestion.isTestableHypothesis, "\(kind) read as a hypothesis")
        }
    }

    // MARK: Kind metadata

    @Test("every kind has a label and an icon, including the new one")
    func kindMetadataIsComplete() {
        // A missing case here is a card with a blank glyph, which reads as a
        // rendering failure rather than a category.
        for kind in [SuggestionKind.question, .risk, .missingInfo, .advice, .hypothesis] {
            #expect(!kind.label.isEmpty, "\(kind) has no label")
            #expect(!kind.systemImage.isEmpty, "\(kind) has no icon")
        }
        // Labels must stay distinguishable — two kinds reading "Risk" would make
        // an unsettled hunch look like a confirmed finding.
        let labels = [SuggestionKind.question, .risk, .missingInfo, .advice, .hypothesis].map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test("the label reads as an offer, not an assertion")
    func labelIsHedged() {
        // "Hypothesis" reads like a finding; the co-pilot is guessing, and the
        // UI has to say so in one word.
        #expect(SuggestionKind.hypothesis.label == "Hunch")
    }

    // MARK: Export

    @Test("exporting a hypothesis carries the test, which is the actionable part")
    func exportIncludesTheTest() {
        let line = testable.exportLine
        #expect(line.contains("Hunch:"))
        #expect(line.contains("Test:"))
        #expect(line.contains("Ask who signs"))
    }

    @Test("exporting an untestable hypothesis does not promise a test")
    func exportOmitsMissingTest() {
        let noTest = Suggestion(title: "t", detail: "d", kind: .hypothesis, claim: "c")
        #expect(!noTest.exportLine.contains("Test:"))
    }

    @Test("the other kinds export exactly as before")
    func exportUnchangedForOtherKinds() {
        // This line goes into Word and Google Docs exports; a format change would
        // silently alter documents users have already produced.
        let risk = Suggestion(title: "Loud accounts", detail: "Not the market", kind: .risk)
        #expect(risk.exportLine == "Risk: Loud accounts — Not the market")
    }
}

/// The decode path. The server already demotes a hypothesis it cannot make
/// testable, so this layer is defensive — but a client that trusted the kind
/// alone would render an empty card the moment that regressed, and an empty card
/// reads as a broken app rather than a missing guess.
@Suite("Hypothesis decoding from the backend")
struct HypothesisDecodeTests {
    private let transcript = "Legal still needs to look at the liability cap before we sign anything."

    private func item(kind: String, claim: String? = nil, cheapTest: String? = nil,
                      costOfMissing: String? = nil,
                      evidence: String? = "Legal still needs to look at the liability cap")
    -> BrainstormService.BackendResponse.Item {
        // Built through JSON so the test exercises the same Decodable path the
        // network does, rather than a memberwise init the app never uses.
        let payload: [String: Any?] = [
            "title": "Procurement is the blocker", "detail": "d", "kind": kind,
            "evidence": evidence, "claim": claim, "cheapTest": cheapTest,
            "costOfMissing": costOfMissing,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: payload.compactMapValues { $0 ?? nil })
        return try! JSONDecoder().decode(BrainstormService.BackendResponse.Item.self, from: data)
    }

    @Test("a complete hypothesis decodes as one, with its fields intact")
    func decodesComplete() throws {
        let mapped = try #require(BrainstormService.map(
            item(kind: "hypothesis",
                 claim: "They will stall at procurement",
                 cheapTest: "Ask who signs once legal clears it",
                 costOfMissing: "A needless discount"),
            transcript: transcript))
        #expect(mapped.kind == .hypothesis)
        #expect(mapped.isTestableHypothesis)
        #expect(mapped.costOfMissing == "A needless discount")
    }

    @Test("a hypothesis with no test is demoted to advice, not shown as a hunch")
    func demotesWithoutTest() throws {
        let mapped = try #require(BrainstormService.map(
            item(kind: "hypothesis", claim: "They will stall"), transcript: transcript))
        #expect(mapped.kind == .advice)
        // And the orphaned fields are cleared, so nothing renders half a hunch.
        #expect(mapped.claim == nil)
        #expect(mapped.cheapTest == nil)
    }

    @Test("a hypothesis with no claim is demoted too")
    func demotesWithoutClaim() throws {
        let mapped = try #require(BrainstormService.map(
            item(kind: "hypothesis", cheapTest: "Ask who signs this"), transcript: transcript))
        #expect(mapped.kind == .advice)
    }

    @Test("hypothesis fields on an ordinary kind are dropped, never smuggled through")
    func stripsFieldsFromOtherKinds() throws {
        let mapped = try #require(BrainstormService.map(
            item(kind: "question", claim: "smuggled", cheapTest: "smuggled test"),
            transcript: transcript))
        #expect(mapped.kind == .question)
        #expect(mapped.claim == nil)
        #expect(mapped.cheapTest == nil)
    }

    @Test("a hypothesis still needs a real transcript quote")
    func requiresEvidence() {
        // Inherited from the shared grounding check — the reason hypothesis is a
        // KIND and not a parallel list.
        #expect(BrainstormService.map(
            item(kind: "hypothesis", claim: "c", cheapTest: "Ask who signs this",
                 evidence: "words never spoken on this call"),
            transcript: transcript) == nil)
    }

    @Test("whitespace-only fields count as absent")
    func blankFieldsAreAbsent() throws {
        let mapped = try #require(BrainstormService.map(
            item(kind: "hypothesis", claim: "   ", cheapTest: "  \n "), transcript: transcript))
        #expect(mapped.kind == .advice)
    }
}
