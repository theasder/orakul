import Foundation

/// Reads `contract/contract.json` — the shared vocabulary emitted by
/// `cruxwing-api/scripts/emit-contract.js` and replicated into every repo that
/// has to agree with the server about plans, models and funnel stages.
///
/// Tests read it directly from the repo rather than through a bundled resource:
/// the point is to catch drift between this checkout's copy and what the code
/// asserts, and a copy staged into a test bundle would only prove the staging
/// worked.
enum SharedContract {
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetGPTTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // cruxwing-app
            .appendingPathComponent("contract/contract.json")
    }

    private static var json: [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static var funnelStages: [String] { json["funnelStages"] as? [String] ?? [] }

    struct ModelEntry {
        let minTier: String
        let supportsVision: Bool
        /// Absent when the server has not verified the window. Nil must mean
        /// "not offered", never "unknown, try it".
        let contextTokens: Int?
    }

    struct Allowance: Equatable {
        let copilotHours: Int
        let computeCredits: Int
        let groundedCycles: Int
    }

    /// Per-tier allowances as the SERVER defines them.
    static var allowances: [String: Allowance] {
        guard let raw = json["allowances"] as? [String: [String: Any]] else { return [:] }
        return raw.compactMapValues { entry in
            guard let hours = entry["copilotHours"] as? Int,
                  let credits = entry["computeCredits"] as? Int,
                  let cycles = entry["groundedCycles"] as? Int else { return nil }
            return Allowance(copilotHours: hours, computeCredits: credits,
                             groundedCycles: cycles)
        }
    }

    struct Plan: Equatable {
        let id: String
        let tier: String
        let interval: String
        let priceCents: Int
    }

    static var plans: [Plan] {
        guard let raw = json["plans"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, let tier = entry["tier"] as? String,
                  let interval = entry["interval"] as? String,
                  let price = entry["priceCents"] as? Int else { return nil }
            return Plan(id: id, tier: tier, interval: interval, priceCents: price)
        }
    }

    static var models: [String: ModelEntry] {
        guard let raw = json["models"] as? [String: [String: Any]] else { return [:] }
        return raw.mapValues { entry in
            ModelEntry(minTier: entry["minTier"] as? String ?? "",
                       supportsVision: entry["supportsVision"] as? Bool ?? false,
                       contextTokens: entry["contextTokens"] as? Int)
        }
    }
}
