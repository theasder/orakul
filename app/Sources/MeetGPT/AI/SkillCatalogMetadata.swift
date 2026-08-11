import Foundation

/// Canonical, generated metadata for the vendored skill catalog.
///
/// Third-party `description:` prose is written for wildly different audiences,
/// which is why both keyword rules (~45% accurate on a hand-checked sample) and
/// sentence embeddings mis-route on it. `Resources/Skills/skill-metadata.json`
/// is one pass over all 1,188 skills producing a fixed shape instead:
///
///   domain            closed vocabulary (meeting-craft, sales, dev-tooling, …)
///   meeting_relevance high | medium | none
///   use_when          one canonical trigger line
///
/// Regenerate after a bulk ingest; a skill with no entry is treated as relevant
/// so a newly added skill is never silently dropped from routing.
enum SkillCatalogMetadata {
    struct Entry: Decodable, Sendable {
        let domain: String
        let meetingRelevance: String
        let useWhen: String

        private enum CodingKeys: String, CodingKey {
            case domain
            case meetingRelevance = "meeting_relevance"
            case useWhen = "use_when"
        }
    }

    static let byID: [String: Entry] = {
        guard let url = SkillResources.bundle?
            .url(forResource: "Skills", withExtension: nil)?
            .appendingPathComponent("skill-metadata.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            Log.general.info("skill-metadata.json unavailable — routing falls back to unfiltered catalog")
            return [:]
        }
        return decoded
    }()

    static func entry(for id: String) -> Entry? { byID[id] }

    /// False only for a skill explicitly catalogued as `none`. Unknown ids are
    /// relevant by default: a missing label must never quietly remove a skill
    /// from routing, because that failure is invisible at runtime.
    static func isMeetingRelevant(_ id: String) -> Bool {
        byID[id]?.meetingRelevance != "none"
    }

    /// Count catalogued at each relevance level — for diagnostics and tests.
    static var relevanceHistogram: [String: Int] {
        byID.values.reduce(into: [:]) { counts, entry in
            counts[entry.meetingRelevance, default: 0] += 1
        }
    }
}
