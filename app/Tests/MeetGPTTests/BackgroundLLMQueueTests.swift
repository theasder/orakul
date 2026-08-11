import Testing
@testable import MeetGPT

/// The shared cost gate for the background watch loops. These pin the three
/// guarantees that keep aligned timers from burning paid LLM calls: coalesce
/// (skip-unchanged), single-flight per key, and a global concurrency cap.
@Suite("BackgroundLLMQueue")
struct BackgroundLLMQueueTests {
    @Test("coalesce: an unchanged signature is skipped, a changed one runs")
    func coalesceSkipsUnchanged() async {
        let q = BackgroundLLMQueue()
        #expect(await q.reserve(key: "a", signature: 1) == true)
        await q.finish(key: "a")
        // Same input → same answer → skip, don't re-bill.
        #expect(await q.reserve(key: "a", signature: 1) == false)
        // Transcript grew → run.
        #expect(await q.reserve(key: "a", signature: 2) == true)
    }

    @Test("single-flight: a second reserve for an in-flight key is dropped")
    func singleFlightPerKey() async {
        let q = BackgroundLLMQueue()
        #expect(await q.reserve(key: "a", signature: 1) == true)
        // Previous run for "a" hasn't finished — even a changed signature waits.
        #expect(await q.reserve(key: "a", signature: 2) == false)
        await q.finish(key: "a")
        #expect(await q.reserve(key: "a", signature: 2) == true)
    }

    @Test("backpressure: no more than maxConcurrent runs across all keys")
    func backpressureCapsConcurrency() async {
        let q = BackgroundLLMQueue(maxConcurrent: 2)
        #expect(await q.reserve(key: "a", signature: 1) == true)
        #expect(await q.reserve(key: "b", signature: 1) == true)
        // Two already in flight — the third loop skips this tick.
        #expect(await q.reserve(key: "c", signature: 1) == false)
        await q.finish(key: "a")
        // A slot freed — now the third can run.
        #expect(await q.reserve(key: "c", signature: 1) == true)
    }

    @Test("finish is idempotent — a stray call can't over-credit the cap")
    func finishIsIdempotent() async {
        let q = BackgroundLLMQueue(maxConcurrent: 1)
        #expect(await q.reserve(key: "a", signature: 1) == true)
        await q.finish(key: "a")
        await q.finish(key: "a")   // duplicate — must be a no-op
        #expect(await q.reserve(key: "b", signature: 1) == true)
        // If the duplicate finish had driven the counter to -1, this would
        // wrongly succeed; the cap of 1 must still hold.
        #expect(await q.reserve(key: "c", signature: 1) == false)
    }

    @Test("reset clears signatures and in-flight slots for a new meeting")
    func resetClearsState() async {
        let q = BackgroundLLMQueue(maxConcurrent: 1)
        #expect(await q.reserve(key: "a", signature: 5) == true)   // never finished
        await q.reset()
        // Signature forgotten AND the leaked slot reclaimed.
        #expect(await q.reserve(key: "a", signature: 5) == true)
    }

    @Test("maxConcurrent is floored at 1 so the queue never deadlocks")
    func maxConcurrentFloor() async {
        let q = BackgroundLLMQueue(maxConcurrent: 0)
        #expect(await q.reserve(key: "a", signature: 1) == true)
    }
}
