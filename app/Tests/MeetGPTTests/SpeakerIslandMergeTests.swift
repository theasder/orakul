import Foundation
import Testing
@testable import MeetGPT

/// Collapsing one-word speaker "islands" produced by diarization.
///
/// Deepgram occasionally attributes a single word mid-sentence to a different
/// speaker. Each attribution change starts a new transcript entry with its own
/// gutter, so one sentence rendered as several labelled blocks — reported as
/// "recognition of speaker was very poor … duplicating speaker name all the
/// time".
///
/// Two existing tests cover this through `parseMessage` with real Deepgram
/// frames. These go at the merge directly, because the cases that decide
/// whether the rule is SAFE — islands at an utterance edge, consecutive
/// islands, multi-word runs — are awkward to express as JSON and are exactly
/// where an over-eager merge would silently delete a real interjection.
@Suite("Speaker island merging")
struct SpeakerIslandMergeTests {

    private typealias Run = (speaker: Int?, tokens: [String])

    private func merge(_ runs: [Run]) -> [(speaker: Int?, tokens: [String])] {
        DeepgramStreamer.mergeSpeakerIslands(runs)
    }

    /// Tuples are not Equatable, so compare a printable projection.
    private func shape(_ runs: [(speaker: Int?, tokens: [String])]) -> [String] {
        runs.map { "\($0.speaker.map(String.init) ?? "-"):\($0.tokens.joined(separator: " "))" }
    }

    // MARK: - Base

    @Test("a single word attributed to another speaker mid-sentence is absorbed")
    func mergesAnIsland() {
        let result = merge([
            (0, ["The", "pricing"]),
            (1, ["page"]),
            (0, ["ships", "Friday."]),
        ])
        #expect(shape(result) == ["0:The pricing page ships Friday."])
    }

    // MARK: - Layer: what must NOT be absorbed

    @Test("a short turn at the start of an utterance is a real interjection")
    func keepsLeadingShortRun() {
        // No same-speaker run before it, so there is nothing to absorb it into
        // — and "Agreed." genuinely is a different person talking.
        let result = merge([
            (1, ["Agreed."]),
            (0, ["So", "we", "ship."]),
        ])
        #expect(shape(result) == ["1:Agreed.", "0:So we ship."])
    }

    @Test("a short turn at the end of an utterance is kept too")
    func keepsTrailingShortRun() {
        let result = merge([
            (0, ["So", "we", "ship."]),
            (1, ["Agreed."]),
        ])
        #expect(shape(result) == ["0:So we ship.", "1:Agreed."])
    }

    @Test("a two-word run is a turn, not an island")
    func keepsMultiWordRuns() {
        // The rule is deliberately narrow: only a SINGLE token can be noise.
        // Widening it would swallow "No, wait" — a real objection.
        let result = merge([
            (0, ["We", "should"]),
            (1, ["No,", "wait"]),
            (0, ["ship", "Friday."]),
        ])
        #expect(shape(result) == ["0:We should", "1:No, wait", "0:ship Friday."])
    }

    @Test("a single word between two DIFFERENT speakers is a real turn")
    func keepsIslandBetweenDifferentSpeakers() {
        // Absorbing it would attribute B's word to A. The rule requires the
        // runs on both sides to be the same speaker — that is what makes the
        // middle word look like noise rather than a turn.
        let result = merge([
            (0, ["We", "should"]),
            (1, ["yes"]),
            (2, ["ship", "Friday."]),
        ])
        #expect(shape(result) == ["0:We should", "1:yes", "2:ship Friday."])
    }

    // MARK: - Layer: shape of the input

    @Test("empty and single-run inputs pass through untouched")
    func handlesTrivialInputs() {
        #expect(merge([]).isEmpty)
        #expect(shape(merge([(0, ["Hello", "there."])])) == ["0:Hello there."])
        #expect(shape(merge([(nil, ["Undiarized", "line."])])) == ["-:Undiarized line."])
    }

    @Test("consecutive islands collapse into one continuous utterance")
    func collapsesConsecutiveIslands() {
        // A noisy stretch flips speaker on several separate words. Each is
        // absorbed in turn, so the sentence ends up whole rather than in five
        // pieces — the reported symptom at its worst.
        let result = merge([
            (0, ["The"]),
            (1, ["pricing"]),
            (0, ["page"]),
            (2, ["ships"]),
            (0, ["Friday."]),
        ])
        #expect(shape(result) == ["0:The pricing page ships Friday."])
    }

    @Test("merging never loses or reorders a word")
    func preservesEveryToken() {
        // The property that matters most: this runs on the transcript, so a
        // dropped word is lost meeting content.
        let runs: [Run] = [
            (0, ["one", "two"]), (1, ["three"]), (0, ["four"]),
            (1, ["five", "six"]), (0, ["seven"]),
        ]
        let before = runs.flatMap(\.tokens)
        let after = merge(runs).flatMap(\.tokens)
        #expect(after == before, "tokens changed: \(before) -> \(after)")
    }

    @Test("an undiarized island between undiarized runs is left alone")
    func handlesNilSpeakers() {
        // Every speaker is nil, so no run "differs" from its neighbours and
        // nothing qualifies as an island. Merging here would be merging runs
        // the diarizer never split by speaker at all.
        let result = merge([
            (nil, ["one"]), (nil, ["two"]), (nil, ["three"]),
        ])
        #expect(shape(result) == ["-:one", "-:two", "-:three"])
    }

    @Test("a nil-speaker island between two identified runs is absorbed")
    func absorbsNilIsland() {
        // Deepgram emits a word with no speaker field mid-utterance. Treated as
        // its own turn it produces a gutter line labelled "Them" in the middle
        // of a named speaker's sentence.
        let result = merge([
            (0, ["The", "pricing"]),
            (nil, ["page"]),
            (0, ["ships."]),
        ])
        #expect(shape(result) == ["0:The pricing page ships."])
    }
}
