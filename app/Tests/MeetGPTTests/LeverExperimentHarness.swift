import Foundation
import Testing
@testable import MeetGPT

// Everything about the token levers has so far been reasoning from code shape.
// This is the command that ends that.
//
// It replays real recorded sessions through a lever ON and OFF against a live
// provider, scores both with the deterministic critics, and prints one line:
// what was saved, and what broke. Skipped unless a corpus is named, because it
// spends real tokens — two requests per window, by construction.
//
//   CRUXWING_LEVER_CORPUS=~/path/to/Sessions \
//   CRUXWING_LEVER=digest \
//   CRUXWING_LEVER_WINDOWS=12 \
//   swift test --filter LeverExperimentHarness
//
// The window cap defaults low on purpose: a corpus of 200 calls would spend
// hundreds of requests to answer a question 12 windows can usually settle.

@Suite("Lever experiment harness")
struct LeverExperimentHarness {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private var corpusPath: String? {
        let raw = environment["CRUXWING_LEVER_CORPUS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var lever: LeverExperiment.Lever {
        environment["CRUXWING_LEVER"] == "order" ? .promptOrder : .transcriptDigest
    }

    private var windowCap: Int {
        Int(environment["CRUXWING_LEVER_WINDOWS"] ?? "") ?? 12
    }

    @Test("replay a corpus with the lever on and off")
    func run() async throws {
        guard let corpusPath else {
            print("""
            [lever-eval] skipped — set CRUXWING_LEVER_CORPUS to a Sessions directory.
            [lever-eval] optional: CRUXWING_LEVER=digest|order (default digest),
                         CRUXWING_LEVER_WINDOWS=12
            [lever-eval] NOTE: this spends real tokens — two requests per window.
            """)
            return
        }

        let root = URL(fileURLWithPath: NSString(string: corpusPath).expandingTildeInPath)
        let store = SessionStore(root: root)
        let sessions = store.list().compactMap { store.load(id: $0.id) }
        let windows = Array(sessions.flatMap(LeverExperiment.windows(for:)).prefix(windowCap))

        guard !windows.isEmpty else {
            print("[lever-eval] no replayable windows in \(corpusPath) — nothing to compare")
            return
        }

        let gateway = LLMGatewayFactory.make()
        let model = LLMCatalog.background(for: Config.selectedModel)
        print("[lever-eval] lever \(lever) · \(windows.count) windows · model \(model.id)")

        var observations: [LeverExperiment.Observation] = []
        for (index, window) in windows.enumerated() {
            let transcript = window.transcript.map(\.text).joined(separator: "\n")
            for applied in [false, true] {
                let message = LeverExperiment.message(window, lever: lever, applied: applied)
                let answer: String
                do {
                    answer = try await gateway.streamChat(
                        system: SystemInstructions.base,
                        user: message,
                        images: [],
                        model: model,
                        maxOutputTokens: OutputTokenBudget.standard) { _ in }
                } catch {
                    // A provider failure is not a quality verdict. Drop the pair
                    // rather than score half of it and call the lever guilty.
                    print("[lever-eval] window \(index) \(applied ? "on" : "off") failed: \(error)")
                    continue
                }
                observations.append(.init(
                    window: "w\(index)",
                    applied: applied,
                    answer: answer,
                    transcript: transcript,
                    inputTokens: LeverExperiment.estimatedTokens(message)))
            }
        }

        let score = LeverExperiment.score(observations)
        print(LeverExperiment.render(score))
        print("[lever-eval] VERDICT: \(LeverExperiment.verdict(score))")

        // The harness reports; it does not fail the build. A lever that costs
        // quality is a decision for a person, and a red test on someone's laptop
        // because a provider was slow would teach them to stop running this.
        #expect(score.pairedWindows >= 0)
    }
}
