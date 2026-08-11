import Foundation
import Testing
@testable import MeetGPT

/// The anti-hallucination gate for blind spots.
///
/// Every surfaced suggestion must quote the transcript verbatim. That claim is
/// the whole reason a user trusts a co-pilot card enough to act on it mid-call,
/// and this one function is what enforces it — a suggestion whose evidence does
/// not appear is dropped entirely rather than shown unsourced.
///
/// One existing test covers the base case in Russian. These layer the rules
/// that decide what counts: how text is normalised before comparison, and the
/// minimum a quote must be before it proves anything.
@Suite("Suggestion grounding")
struct SuggestionGroundingTests {

    private let transcript = """
    [system] We reviewed the pricing page and the launch is slipping to September.
    [mic] Maria will send the updated contract to the client by Friday.
    """

    private func grounded(_ evidence: String?) -> Bool {
        SuggestionGrounding.contains(evidence: evidence, in: transcript)
    }

    // MARK: - Base

    @Test("a verbatim quote is grounded; an invented one is not")
    func exactQuoteIsGrounded() {
        #expect(grounded("the launch is slipping to September"))
        #expect(!grounded("the client already approved the budget"))
    }

    // MARK: - Layer: what normalisation forgives

    @Test("casing and punctuation differences do not break a real quote")
    func normalisationForgivesFormatting() {
        // A model re-wraps and re-punctuates what it heard. Treating that as a
        // fabrication would drop true evidence and make the feature look empty.
        #expect(grounded("The Launch Is Slipping To September"))
        #expect(grounded("the launch is slipping to September!"))
        #expect(grounded("the  launch   is\nslipping to September"))
        #expect(grounded("“the launch is slipping to September”"))
    }

    @Test("diacritics are folded, so an accent restored or dropped still matches")
    func normalisationFoldsDiacritics() {
        let accented = "[mic] Le déploiement est reporté à septembre prochain."
        #expect(SuggestionGrounding.contains(
            evidence: "Le deploiement est reporte a septembre", in: accented))
        #expect(SuggestionGrounding.contains(
            evidence: "Le déploiement est reporté à septembre", in: accented))
    }

    @Test("speaker tags in the transcript do not have to appear in the quote")
    func quoteNeedNotIncludeTheGutter() {
        // Lines are stored with a "[mic]" / "[system]" prefix; a quote of what
        // was SAID must still match.
        #expect(grounded("Maria will send the updated contract"))
    }

    // MARK: - Layer: what is too weak to be evidence

    @Test("a quote too short to be distinctive proves nothing")
    func rejectsShortQuotes() {
        // Both gates: at least three words AND twelve characters. A two-word
        // fragment appears in almost any transcript, so accepting it would let
        // a fabricated card cite "the client" and pass.
        #expect(!grounded("the launch"))          // 2 words
        #expect(!grounded("we the a"))            // 3 words, too few characters
        #expect(!grounded("and"))
        #expect(!grounded(""))
    }

    @Test("a missing quote is never grounded")
    func rejectsMissingEvidence() {
        // The default for a model that omitted the field entirely. Silence is
        // not evidence.
        #expect(!grounded(nil))
        #expect(!grounded("   "))
        #expect(!grounded("\n\t"))
    }

    @Test("a quote assembled from scattered words is not grounded")
    func rejectsRecombinedQuotes() {
        // Every word below appears in the transcript, but never in this order.
        // A substring check on the normalised text is what refuses it — the
        // difference between quoting and paraphrasing.
        #expect(!grounded("pricing page contract Friday"))
        #expect(!grounded("September the launch is slipping to"))
    }

    @Test("a quote spanning two speakers' lines is not grounded")
    func rejectsCrossLineQuotes() {
        // Joining across the line break would attribute to one speaker
        // something two people said in sequence.
        #expect(!grounded("slipping to September Maria will send"))
    }

    // MARK: - Layer: the mapping that consumes the gate

    @Test("an ungrounded item is dropped rather than shown unsourced")
    func mapDropsUngroundedItems() throws {
        let item = try JSONDecoder().decode(
            BrainstormService.BackendResponse.Item.self,
            from: Data(#"{"title":"Pricing risk","detail":"…","evidence":"nobody said this at all"}"#.utf8))
        #expect(BrainstormService.map(item, transcript: transcript) == nil)
    }

    @Test("a grounded item becomes a suggestion carrying its quote")
    func mapKeepsGroundedItems() throws {
        let item = try JSONDecoder().decode(
            BrainstormService.BackendResponse.Item.self,
            from: Data(#"{"title":"Launch slip","detail":"The date moved.","kind":"risk","evidence":"the launch is slipping to September"}"#.utf8))
        let suggestion = try #require(BrainstormService.map(item, transcript: transcript))
        #expect(suggestion.title == "Launch slip")
        #expect(suggestion.kind == .risk)
        #expect(suggestion.evidence == "the launch is slipping to September")
    }

    @Test("an item with no title is dropped even when its quote is real")
    func mapRequiresATitle() throws {
        // A card with no headline is not renderable; grounding alone is not
        // enough to surface one.
        let item = try JSONDecoder().decode(
            BrainstormService.BackendResponse.Item.self,
            from: Data(#"{"title":"   ","evidence":"the launch is slipping to September"}"#.utf8))
        #expect(BrainstormService.map(item, transcript: transcript) == nil)
    }

    @Test("an unknown kind falls back to advice rather than being dropped")
    func mapFallsBackOnUnknownKind() throws {
        // A newer server vocabulary must not make a grounded suggestion vanish.
        let item = try JSONDecoder().decode(
            BrainstormService.BackendResponse.Item.self,
            from: Data(#"{"title":"Something","kind":"brand-new-kind","evidence":"the launch is slipping to September"}"#.utf8))
        #expect(BrainstormService.map(item, transcript: transcript)?.kind == .advice)
    }

    @Test("managed execution metadata decodes without exposing response bodies")
    func executionTraceDecodes() throws {
        let response = try JSONDecoder().decode(
            BrainstormService.BackendResponse.self,
            from: Data(#"{"suggestions":[],"execution":{"correlationId":"8DA46379-851D-4A51-95FE-0080AB24B544","provider":"openrouter","model":"deepseek/deepseek-v4","latencyMs":731,"chargedCredits":3,"cacheHit":false,"attemptCount":2}}"#.utf8))

        let trace = try #require(response.execution)
        #expect(trace.correlationId == "8DA46379-851D-4A51-95FE-0080AB24B544")
        #expect(trace.provider == "openrouter")
        #expect(trace.model == "deepseek/deepseek-v4")
        #expect(trace.latencyMs == 731)
        #expect(trace.chargedCredits == 3)
        #expect(trace.cacheHit == false)
        #expect(trace.attemptCount == 2)
        #expect(trace.attempts == nil)

        let legacy = try JSONDecoder().decode(
            BrainstormService.BackendResponse.self,
            from: Data(#"{"suggestions":[]}"#.utf8))
        #expect(legacy.execution == nil)

        let failure = LLMError.http(
            "Brainstorm", 502,
            #"{"error":"temporarily unavailable","execution":{"correlationId":"157D23DD-018B-45B5-9B31-E00674A3B7F1","provider":null,"model":"gpt-4o-mini","latencyMs":84,"chargedCredits":0,"cacheHit":false,"attemptCount":2,"attempts":[{"provider":"openai","model":"gpt-4o-mini","reason":"funds exhausted"},{"provider":"openrouter","model":"openai/gpt-4o-mini","reason":"timed out"}]}}"#)
        let failedTrace = try #require(BrainstormService.executionTrace(from: failure))
        #expect(failedTrace.provider == nil)
        #expect(failedTrace.chargedCredits == 0)
        #expect(failedTrace.attemptCount == 2)
        #expect(failedTrace.attempts == [
            .init(provider: "openai", model: "gpt-4o-mini", reason: "funds exhausted"),
            .init(provider: "openrouter", model: "openai/gpt-4o-mini", reason: "timed out"),
        ])

        let hostileFailure = LLMError.http(
            "Brainstorm", 502,
            #"{"execution":{"correlationId":"safe","attemptCount":1,"attempts":[{"provider":"vendor","model":"model","reason":"private body sk-secret","body":"must-not-decode"}]}}"#)
        let hostileTrace = try #require(BrainstormService.executionTrace(from: hostileFailure))
        #expect(hostileTrace.attempts == [
            .init(provider: "vendor", model: "model", reason: "request failed"),
        ])
        let reencodedAttempts = try JSONEncoder().encode(hostileTrace.attempts)
        let reencodedText = String(decoding: reencodedAttempts, as: UTF8.self)
        #expect(reencodedText.contains(#""reason":"request failed""#))
        #expect(!reencodedText.contains("must-not-decode"))
        #expect(!reencodedText.contains("sk-secret"))
    }
}
