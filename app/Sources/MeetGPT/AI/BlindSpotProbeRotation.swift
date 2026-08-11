import Foundation

/// Paid blind-spot co-pilot rotates through these prompt workflows so each
/// wake probes different connector sets + skill lenses — not the same
/// "brainstorm" path every time. Higher tiers fan out across several
/// workflows in one tick.
enum BlindSpotProbeRotation: Sendable {
    /// Order is intentional: discovery → questioning → risk → blockers →
    /// evidence → counsel → conflict.
    static let paidProbeIDs: [String] = [
        "brainstorm",
        "whattoask",
        "risks",
        "unresolved",
        "factcheck",
        "advice",
        "dispute",
    ]

    static func probeID(at tick: Int) -> String {
        probeIDs(at: tick, count: 1).first ?? "brainstorm"
    }

    /// How many workflow connector graphs one blind-spot wake should hit.
    static func workflowCount(for tier: Tier) -> Int {
        switch tier {
        case .free: return 1
        case .pro: return 2
        case .premium: return 3
        case .ultra: return 4
        }
    }

    /// Consecutive probes from the rotation starting at `tick`, de-duplicated.
    /// Free callers typically pass count 1 with id "brainstorm" instead.
    static func probeIDs(at tick: Int, count: Int) -> [String] {
        let ids = paidProbeIDs
        guard !ids.isEmpty else { return ["brainstorm"] }
        let n = max(1, min(count, ids.count))
        // `tick` is 1-based (AppState increments before the first wake).
        var result: [String] = []
        var i = 0
        while result.count < n && i < ids.count * 2 {
            let id = ids[(((tick - 1) + i) % ids.count + ids.count) % ids.count]
            if !result.contains(id) { result.append(id) }
            i += 1
        }
        return result.isEmpty ? ["brainstorm"] : result
    }

    /// Short lens brief injected into brainstorm guidance so the model leans
    /// into this workflow's job while still returning the shared JSON schema.
    static func lensBrief(for probeID: String) -> String {
        switch probeID {
        case "whattoask":
            return "Probe lens: What To Ask — sharp questions that expose unsettled assumptions; prefer kind=question."
        case "risks":
            return "Probe lens: Risks — material downsides, blockers, and unsupported claims; prefer kind=risk."
        case "unresolved":
            return "Probe lens: Unresolved — open loops, parked decisions, missing owners; prefer kind=missing_info or advice."
        case "factcheck":
            return "Probe lens: Fact-check — claims that need evidence or contradict attached sources; prefer kind=risk or missing_info."
        case "advice":
            return "Probe lens: Advice — concrete next moves tied to the goal; prefer kind=advice."
        case "dispute":
            return "Probe lens: Dispute — contradictions with prior agreements or attached context; prefer kind=risk or question."
        case "brainstorm":
            return "Probe lens: Brainstorm — novel angles and parked ideas that advance the goal; mix kinds."
        default:
            return "Probe lens: \(probeID) — surface high-signal blind spots for this angle."
        }
    }

    /// Combined lens briefs when several workflows are probed in one wake.
    static func lensBriefs(for probeIDs: [String]) -> String {
        probeIDs.map(lensBrief(for:)).joined(separator: "\n")
    }
}
