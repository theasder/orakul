import Foundation
import Testing
@testable import MeetGPT

/// The eval harness: judge REAL recorded sessions with the deterministic
/// critics and print the rates.
///
/// It lives in the test target because that is the only thing in this package
/// that can import the app, and it is gated on an environment variable so a
/// machine with no corpus (CI, a fresh checkout) stays green instead of
/// reporting a perfect score over zero sessions.
///
///     CRUXWING_EVAL_CORPUS="$HOME/Library/Application Support/MeetGPT/Sessions" \
///       swift test --filter ReflectionEvalHarness
///
/// Nothing here calls a model. The corpus is the user's own history: every
/// saved session carries the transcript alongside the blind spots, answers and
/// digest produced from it, so the harness measures production output for free.
@Suite("Reflection eval harness")
struct ReflectionEvalHarness {

    private var corpusRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["CRUXWING_EVAL_CORPUS"],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    @Test("judge the recorded corpus and report violation rates per rule")
    func evaluateCorpus() throws {
        guard let corpusRoot else {
            // Not a failure and not a pass to celebrate: there is nothing to
            // measure. Say which variable turns it on and stop.
            print("""

            [reflection-eval] skipped — set CRUXWING_EVAL_CORPUS to a Sessions directory:
              CRUXWING_EVAL_CORPUS="$HOME/Library/Application Support/MeetGPT/Sessions" \\
                swift test --filter ReflectionEvalHarness

            """)
            return
        }

        let store = SessionStore(root: corpusRoot)
        let (summary, scores) = ReflectionEval.run(store: store)
        print("\n" + ReflectionEval.render(summary) + "\n")

        // The sessions with the most to answer for, so a regression points at a
        // meeting rather than at a percentage.
        let worstSessions = scores
            .filter { !$0.tally.findings.isEmpty }
            .sorted { $0.tally.findings.count > $1.tally.findings.count }
            .prefix(5)
        if !worstSessions.isEmpty {
            print("Worst sessions:")
            for score in worstSessions {
                print("  \(score.tally.findings.count) finding(s) — \(score.title)")
            }
            print("")
        }

        // The harness reports; it does not fail on the rate. A threshold here
        // would have to be invented before anyone has seen a single number, and
        // an arbitrary bar either fires constantly or never. Set one once the
        // baseline is known — that is what this run produces.
        #expect(summary.sessions >= 0)
    }
}
