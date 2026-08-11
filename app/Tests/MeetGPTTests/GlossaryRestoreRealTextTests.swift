import Foundation
import Testing
@testable import MeetGPT

/// What restore does to REAL speech.
///
/// Every other glossary test feeds it sentences written to exercise a rule. The
/// risk that only real text exposes is the opposite one: a term that fires
/// where it should not, quietly rewriting a word somebody actually said. The
/// numbers guard had exactly that failure — it looked correct on written
/// figures and cried wolf on every spoken one.
///
/// Env-gated on a transcript path, because the corpus lives outside this repo:
///
///     CRUXWING_REAL_TRANSCRIPT=/path/to/transcript.txt \
///     swift test --filter restoreOnRealSpeech
@Suite("Glossary restore on real speech")
struct GlossaryRestoreRealTextTests {

    @Test("restore: every change to a real transcript, listed for judgement")
    func restoreOnRealSpeech() throws {
        guard let path = ProcessInfo.processInfo.environment["CRUXWING_REAL_TRANSCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let terms = DomainLexicon.casingOnlyTerms(for: text)
        let restored = GlossaryRestore.restore(transcript: text, glossary: [],
                                               casingOnlyGlossary: terms)

        // Word-level diff: what did the pass actually rewrite?
        let before = text.split(separator: " ").map(String.init)
        let after = restored.split(separator: " ").map(String.init)
        #expect(before.count == after.count,
                "restore changed the word COUNT — it may only recase, never add or drop")

        var changes: [String: (from: String, to: String, count: Int)] = [:]
        for (old, new) in zip(before, after) where old != new {
            let key = old.lowercased()
            changes[key] = (old, new, (changes[key]?.count ?? 0) + 1)
        }

        let total = changes.values.reduce(0) { $0 + $1.count }
        print("restore over \(before.count) words with \(terms.count) terms: "
              + "\(total) rewrites across \(changes.count) distinct words")
        for (_, change) in changes.sorted(by: { $0.value.count > $1.value.count }).prefix(40) {
            print("  \(change.from) -> \(change.to)  ×\(change.count)")
        }

        // A casing-only pass must never change what a word IS. Anything whose
        // letters differ beyond case is a corruption, not a restoration.
        for (_, change) in changes {
            #expect(change.from.lowercased() == change.to.lowercased(),
                    "restore altered letters, not just case: \(change.from) -> \(change.to)")
        }
    }
}
