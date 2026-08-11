import Foundation
import Testing
@testable import MeetGPT

/// Does the ranker say anything about real sentences?
///
/// Its unit tests feed it lines built to trip its keywords — "sunset the legacy
/// API", "lunch moves to Thursdays" — and it separates those perfectly. The
/// question those cannot answer is whether real speech ever reaches its tiers
/// at all. A ranker that scores every genuine sentence at baseline produces a
/// "What matters" block chosen by nothing, which is worse than no block: it
/// looks like a judgement and is a coin toss.
///
///     CRUXWING_REAL_TRANSCRIPT=/path/to/transcript.txt \
///     swift test --filter rankerOnRealSpeech
///
/// Read the output with its contract in mind. In production the ranker scores
/// DECISION LINES the model already extracted, never raw transcript sentences.
/// Run over a webinar it puts "let me pivot to the regular classwork" in the
/// high-stakes tier — on the word "pivot" — and "classes in cybersecurity" on
/// "security". Neither would ever be extracted as a decision, so neither is a
/// bug on its own; both show how much the tiers lean on single keywords, which
/// is worth knowing before anyone points this at a different input. Do not
/// retune the keyword lists from out-of-contract text: the same discipline that
/// stopped a diarization threshold being chosen from three files.
@Suite("Consequence ranker on real speech")
struct ConsequenceRankerRealTextTests {

    @Test("ranker: score distribution over real sentences")
    func rankerOnRealSpeech() throws {
        guard let path = ProcessInfo.processInfo.environment["CRUXWING_REAL_TRANSCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        // Sentence-ish units of a length a minutes line would actually have.
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: " ").count >= 6 && $0.count < 240 }
        guard sentences.count > 50 else { return }

        let scored = sentences.map { (text: $0, score: ConsequenceRanker.score($0)) }
        let above = scored.filter { $0.score > ConsequenceRanker.baselineScore }
        let below = scored.filter { $0.score < ConsequenceRanker.baselineScore }
        let high = scored.filter { $0.score >= ConsequenceRanker.highStakesScore }

        print("ranker over \(scored.count) real sentences: "
              + "\(above.count) above baseline, \(high.count) high-stakes, \(below.count) demoted")
        for line in scored.sorted(by: { $0.score > $1.score }).prefix(8) {
            print("  \(line.score): \(line.text.prefix(90))")
        }
        print("  --- demoted ---")
        for line in below.sorted(by: { $0.score < $1.score }).prefix(4) {
            print("  \(line.score): \(line.text.prefix(90))")
        }

        // The bar is only that the ranker DISCRIMINATES on real language. If
        // nothing clears baseline, the highlights block is decoration.
        #expect(!above.isEmpty, "no real sentence scored above baseline — the ranker is inert here")
        #expect(Set(scored.map(\.score)).count > 2, "real speech collapsed to one or two scores")
    }
}
