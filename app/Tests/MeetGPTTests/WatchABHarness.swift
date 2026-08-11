import Foundation
import Testing
@testable import MeetGPT

/// The live half of the A/B: replay recorded windows through the real gateway
/// and print the scoreboard.
///
/// Double-gated, because this one SPENDS. `CRUXWING_EVAL_CORPUS` points at the
/// sessions to replay and `CRUXWING_AB_LIVE=1` is the explicit yes; without
/// both it prints how to run it and stops. Three model calls per window, capped
/// at `CRUXWING_AB_WINDOWS` (default 12), so a full run is on the order of a
/// few dozen fast-model calls — a one-off experiment, not a per-tick cost.
///
///     CRUXWING_EVAL_CORPUS="$HOME/Library/Application Support/Cruxwing/Sessions" \
///     CRUXWING_AB_LIVE=1 CRUXWING_AB_WINDOWS=12 \
///       swift test --filter WatchABHarness
@Suite("Watch A/B harness")
struct WatchABHarness {

    private var corpusRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["CRUXWING_EVAL_CORPUS"],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var live: Bool {
        ProcessInfo.processInfo.environment["CRUXWING_AB_LIVE"] == "1"
    }

    private var windowLimit: Int {
        Int(ProcessInfo.processInfo.environment["CRUXWING_AB_WINDOWS"] ?? "") ?? 12
    }

    @Test("replay recorded windows through both variants and score them")
    func runExperiment() async throws {
        guard let corpusRoot, live else {
            print("""

            [watch-ab] skipped — this experiment spends model calls, so it needs both:
              CRUXWING_EVAL_CORPUS="$HOME/Library/Application Support/Cruxwing/Sessions" \\
              CRUXWING_AB_LIVE=1 \\
                swift test --filter WatchABHarness

            """)
            return
        }

        let sessions = SessionStore(root: corpusRoot).list()
        var windows: [WatchABExperiment.Window] = []
        for session in sessions where windows.count < windowLimit {
            windows.append(contentsOf: WatchABExperiment.windows(
                for: session, limit: windowLimit - windows.count))
        }

        guard !windows.isEmpty else {
            print("\n[watch-ab] no replayable windows — record a few calls first.\n")
            return
        }

        let model = await MainActor.run { LLMCatalog.fastAudit(for: Config.selectedModel) }
        let gateway = await MainActor.run { LLMGatewayFactory.make() }
        print("\n[watch-ab] replaying \(windows.count) window(s) — \(windows.count * 3) model calls on \(model.id)\n")

        var observations: [WatchABExperiment.Observation] = []
        for window in windows {
            observations.append(await WatchABExperiment.observe(
                window, gateway: gateway, model: model))
        }

        let score = WatchABExperiment.score(observations)
        print("\n" + WatchABExperiment.render(score) + "\n")

        // Every disagreement, so the verdict can be read rather than trusted.
        for observation in observations {
            let pairs = [("rhetoric", observation.separateRhetoric, observation.merged.rhetoric),
                         ("facilitation", observation.separateFacilitation, observation.merged.facilitation)]
            for (track, separate, merged) in pairs where separate != merged {
                print("  [\(track) @ \(Int(observation.window.offset))s] "
                      + "separate: \(separate ?? "—")")
                print("      merged:   \(merged ?? "—")")
            }
        }

        #expect(score.windows == observations.count)
    }
}
