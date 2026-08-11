import Testing
import Foundation
@testable import MeetGPT

// The scan sends a slice of the transcript. A plain suffix(cap) is correct
// content but a moving target — once the call passes `cap`, its start advances
// every scan and the provider prompt cache re-bills the whole transcript
// (freemium finding 11). cacheStableWindow anchors the start to `step`
// boundaries so the window is append-only between jumps. These pin the two
// properties that make that safe AND effective: it never drops recent
// transcript (a superset of suffix(cap)), and its start holds still across the
// growth within one step (so the prefix a cache keys on is stable).
@Suite("Cache-stable transcript window")
struct CacheStableWindowTests {

    // 40 distinct-ish chars; content is compared against the transcript itself,
    // so exact glyphs don't matter.
    static let full = String((0..<40).map { Character(UnicodeScalar(UInt8(48 + $0))) })

    @Test("a transcript shorter than the cap is returned whole — already append-only")
    func shortReturnedWhole() {
        let short = String(Self.full.prefix(8))
        #expect(BrainstormService.cacheStableWindow(short, cap: 10, step: 4) == short)
        // Exactly at the cap is still whole.
        let atCap = String(Self.full.prefix(10))
        #expect(BrainstormService.cacheStableWindow(atCap, cap: 10, step: 4) == atCap)
    }

    @Test("the window always contains the most recent `cap` chars (a superset of suffix)")
    func alwaysASupersetOfSuffix() {
        for len in 11...40 {
            let t = String(Self.full.prefix(len))
            let window = BrainstormService.cacheStableWindow(t, cap: 10, step: 4)
            // Ends with exactly what suffix(cap) would have sent — evidence quotes
            // come from here and are never dropped.
            #expect(window.hasSuffix(String(t.suffix(10))), "len \(len): recent chars missing")
            #expect(window.count >= 10)
            #expect(window.count <= 10 + 4 - 1, "len \(len): window \(window.count) exceeds cap+step-1")
        }
    }

    @Test("within one step the start holds still, so growth is append-only")
    func appendOnlyWithinAStep() {
        // count 30 and 31 sit in the same step bucket (minStart 20 and 21 both
        // snap to 20), so the shorter window must be a prefix of the longer.
        let a = BrainstormService.cacheStableWindow(String(Self.full.prefix(30)), cap: 10, step: 4)
        let b = BrainstormService.cacheStableWindow(String(Self.full.prefix(31)), cap: 10, step: 4)
        #expect(b.hasPrefix(a), "window grew by replacing its start instead of appending")
        #expect(b.count == a.count + 1)
    }

    @Test("the start advances by exactly one step when a boundary is crossed")
    func startJumpsByAStep() {
        // minStart goes 20 (len 30) → 24 (len 34): a full step boundary.
        let atBoundary = BrainstormService.cacheStableWindow(String(Self.full.prefix(30)), cap: 10, step: 4)
        let afterJump = BrainstormService.cacheStableWindow(String(Self.full.prefix(34)), cap: 10, step: 4)
        // Both are cap-length windows (both starts land on a step multiple), and
        // the later one starts one step (4 chars) further into the transcript.
        #expect(atBoundary.count == 10)
        #expect(afterJump.count == 10)
        #expect(afterJump == String(Self.full.prefix(34).suffix(10)))
        #expect(atBoundary == String(Self.full.prefix(30).suffix(10)))
    }

    @Test("step <= 0 degrades to a plain suffix rather than dividing by zero")
    func degradesSafely() {
        let t = String(Self.full.prefix(30))
        #expect(BrainstormService.cacheStableWindow(t, cap: 10, step: 0) == String(t.suffix(10)))
    }

    @Test("the real defaults keep a long call's window byte-stable across a scan")
    func realDefaultsAreStable() {
        // ~9k chars, then +200 (a few seconds of speech). With the shipped
        // 8000/2000 defaults, minStart 1000 → 1200 stays in the same bucket, so
        // the earlier window is a prefix of the later — the cache prefix survives.
        let base = String(repeating: "x", count: 9_000)
        let grown = base + String(repeating: "y", count: 200)
        let w1 = BrainstormService.cacheStableWindow(base)
        let w2 = BrainstormService.cacheStableWindow(grown)
        #expect(w2.hasPrefix(w1))
    }
}
