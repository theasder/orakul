import Foundation
import Testing
@testable import MeetGPT

// The app spends tokens on every call and has never counted them. Prompt
// caching in particular cannot be verified by reading the code — a breakpoint
// that is silently ignored (block too small, prefix drifted by one byte) looks
// exactly like one that works. The provider reports what actually happened;
// this reads it.

@Suite("Token usage accounting")
struct TokenUsageTests {
    private func event(_ json: String) -> Data { Data(json.utf8) }

    @Test("a message_start carries the input and output counts")
    func parsesMessageStart() {
        let usage = TokenUsage.parse(event("""
        {"type":"message_start","message":{"usage":{
        "input_tokens":1200,"output_tokens":8,
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """))
        #expect(usage?.inputTokens == 1200)
        #expect(usage?.outputTokens == 8)
        #expect(usage?.cacheReadTokens == 0)
    }

    @Test("cache reads and writes are reported separately")
    func parsesCacheCounters() {
        // These two are the whole point: a write costs more than an ordinary
        // input token and a read costs a fraction, so collapsing them into one
        // number hides both the win and the waste.
        let usage = TokenUsage.parse(event("""
        {"type":"message_start","message":{"usage":{
        "input_tokens":40,"output_tokens":0,
        "cache_creation_input_tokens":900,"cache_read_input_tokens":11000}}}
        """))
        #expect(usage?.cacheCreationTokens == 900)
        #expect(usage?.cacheReadTokens == 11_000)
    }

    @Test("a final usage delta updates the output count")
    func parsesMessageDelta() {
        // Output tokens are only final on message_delta; message_start reports
        // whatever has been emitted so far, which is nearly zero.
        let usage = TokenUsage.parse(event("""
        {"type":"message_delta","usage":{"output_tokens":642}}
        """))
        #expect(usage?.outputTokens == 642)
    }

    @Test("ordinary stream events carry no usage")
    func ignoresContentEvents() {
        #expect(TokenUsage.parse(event("""
        {"type":"content_block_delta","delta":{"text":"hello"}}
        """)) == nil)
        #expect(TokenUsage.parse(event("not json")) == nil)
    }

    @Test("merging keeps the largest counts seen across the stream")
    func mergeAccumulates() {
        // message_start reports input; message_delta reports final output. The
        // call's true cost is both, so neither event may overwrite the other.
        var total = TokenUsage(inputTokens: 1200, outputTokens: 2,
                               cacheCreationTokens: 900, cacheReadTokens: 0)
        total.merge(TokenUsage(inputTokens: 0, outputTokens: 642,
                               cacheCreationTokens: 0, cacheReadTokens: 0))
        #expect(total.inputTokens == 1200)
        #expect(total.outputTokens == 642)
        #expect(total.cacheCreationTokens == 900)
    }

    @Test("the cache hit rate is reported honestly, including when nothing was cached")
    func hitRate() {
        let cold = TokenUsage(inputTokens: 1200, outputTokens: 10,
                              cacheCreationTokens: 1000, cacheReadTokens: 0)
        #expect(cold.cacheHitRate == 0)

        let warm = TokenUsage(inputTokens: 40, outputTokens: 10,
                              cacheCreationTokens: 0, cacheReadTokens: 9_960)
        #expect(warm.cacheHitRate > 0.99)

        // No input at all must not divide by zero and claim a perfect rate.
        let empty = TokenUsage(inputTokens: 0, outputTokens: 0,
                               cacheCreationTokens: 0, cacheReadTokens: 0)
        #expect(empty.cacheHitRate == 0)
    }
}
