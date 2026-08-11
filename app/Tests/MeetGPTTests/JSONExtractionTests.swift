import Foundation
import Testing
@testable import MeetGPT

/// Pulling JSON out of a model's reply.
///
/// Seven services each carried a private copy of these three lines — fact
/// check, decision log, structured buttons, brainstorm, agenda check,
/// clarifying questions. Now one implementation, so this is the single place
/// the rule is pinned, and a change here reaches every caller instead of one.
///
/// Every case below is a shape a model has actually produced: prose around the
/// payload, a fenced block, a refusal, a truncated object.
@Suite("Model JSON extraction")
struct JSONExtractionTests {

    // MARK: - Base

    @Test("a bare object is returned unchanged")
    func bareObject() {
        #expect(JSONExtraction.firstObject(in: #"{"claims":[]}"#) == #"{"claims":[]}"#)
    }

    // MARK: - Layer: the wrappers models put around it

    @Test("prose before and after the object is stripped")
    func stripsProse() {
        let reply = """
        Sure — here is the JSON you asked for:
        {"decision":{"title":"Ship Friday"}}
        Let me know if you'd like anything changed.
        """
        #expect(JSONExtraction.firstObject(in: reply) == #"{"decision":{"title":"Ship Friday"}}"#)
    }

    @Test("a fenced code block yields the object inside it")
    func stripsCodeFence() {
        let reply = """
        ```json
        {"claims":[{"claim":"Revenue doubled"}]}
        ```
        """
        let extracted = JSONExtraction.firstObject(in: reply)
        #expect(extracted == #"{"claims":[{"claim":"Revenue doubled"}]}"#)
        #expect(extracted?.contains("`") == false, "fence leaked into the payload")
    }

    @Test("nested objects keep their inner braces")
    func keepsNesting() {
        // The span runs first '{' to LAST '}', so nesting must survive intact —
        // a brace-counting parser that stopped at the first close would truncate
        // every non-trivial payload.
        let reply = #"noise {"a":{"b":{"c":1}}} trailing"#
        #expect(JSONExtraction.firstObject(in: reply) == #"{"a":{"b":{"c":1}}}"#)
    }

    @Test("braces inside string values do not end the span early")
    func toleratesBracesInStrings() {
        let reply = #"{"claim":"he said {yes} out loud","status":"true"}"#
        let extracted = JSONExtraction.firstObject(in: reply)
        #expect(extracted == reply)
        #expect(JSONExtraction.decodeObject(Probe.self, from: reply)?.status == "true")
    }

    // MARK: - Layer: replies with no usable payload

    @Test("a reply with no object yields nil, never an empty fragment")
    func noObjectIsNil() {
        for reply in ["", "   ", "I could not find any decisions in this transcript.",
                      "no json here", "[1,2,3]"] {
            #expect(JSONExtraction.firstObject(in: reply) == nil, "invented an object from: \(reply)")
        }
    }

    @Test("braces in the wrong order are not an object")
    func rejectsInvertedBraces() {
        // "} … {" would otherwise produce a negative span and trap on the
        // String subscript.
        #expect(JSONExtraction.firstObject(in: "} then {") == nil)
        #expect(JSONExtraction.firstObject(in: "{") == nil)
        #expect(JSONExtraction.firstObject(in: "}") == nil)
    }

    @Test("a truncated object is returned but fails to decode, rather than half-decoding")
    func truncatedObjectFailsCleanly() {
        // Output cut off at the token limit is the common case. Returning the
        // span is right — the decoder is the arbiter — but the decode must fail
        // so callers treat the pass as "produced nothing".
        let truncated = #"{"claims":[{"claim":"Revenue doubled","stat"#
        #expect(JSONExtraction.firstObject(in: truncated) == nil, "no closing brace at all")

        let partial = #"{"claims":[{"claim":"Revenue doubled"}"#
        #expect(JSONExtraction.firstObject(in: partial) != nil)
        #expect(JSONExtraction.decodeObject(Probe.self, from: partial) == nil)
    }

    // MARK: - Layer: decoding on top of extraction

    @Test("decoding pulls a typed value straight out of a prose-wrapped reply")
    func decodesFromProse() {
        let reply = """
        Here you go:
        {"status":"verified","claim":"Revenue doubled"}
        Hope that helps!
        """
        let probe = JSONExtraction.decodeObject(Probe.self, from: reply)
        #expect(probe?.status == "verified")
        #expect(probe?.claim == "Revenue doubled")
    }

    @Test("a shape mismatch returns nil instead of throwing")
    func mismatchIsNil() {
        // Every call site treats a bad reply as "this pass produced nothing";
        // none of them is prepared to catch.
        #expect(JSONExtraction.decodeObject(Probe.self, from: #"{"unexpected":true}"#) == nil)
        #expect(JSONExtraction.decodeObject(Probe.self, from: "not json") == nil)
    }

    // MARK: - Arrays

    @Test("the array form mirrors the object form")
    func extractsArrays() {
        #expect(JSONExtraction.firstArray(in: "prefix [1,2,3] suffix") == "[1,2,3]")
        #expect(JSONExtraction.firstArray(in: #"[{"id":"a"},{"id":"b"}]"#) == #"[{"id":"a"},{"id":"b"}]"#)
        #expect(JSONExtraction.firstArray(in: "no array here") == nil)
        #expect(JSONExtraction.firstArray(in: "] then [") == nil)
    }

    private struct Probe: Decodable {
        let status: String
        let claim: String
    }
}
