import Foundation

/// The Efficiency Engine's output, kept with the meeting that produced it.
///
/// It used to be rendered straight into the answer text and then discarded, so
/// the scoring that is the product's stated differentiator survived only as
/// prose: unreadable by anything, unmeasurable by the reflection eval, and
/// gone the moment the answer was replaced.
///
/// A purpose-built record rather than the wire type. `EfficiencyEngineService`
/// decodes a `fields: [String: Value]` bag whose `Value` is a hand-rolled
/// Decodable enum; making that round-trip through disk would mean an encoder
/// for a shape that exists only to be rendered once. What reflection needs is
/// the scored part, and that part is stable.
struct SavedActionItem: Codable, Equatable, Sendable {
    let title: String
    let owner: String?
    let due: String?
    let ask: String?
    /// 0…1, as scored server-side on owner, date, and one clear ask.
    let score: Double
    /// Which of those three the item lacks — the reason for the score, kept
    /// because a number without its reason cannot be acted on.
    let missing: [String]
}

struct SavedFollowUp: Codable, Equatable, Sendable {
    let goalType: String
    let label: String
    let efficiencyScore: Double
    let actionItems: [SavedActionItem]

    init(goalType: String, label: String, efficiencyScore: Double, actionItems: [SavedActionItem]) {
        self.goalType = goalType
        self.label = label
        self.efficiencyScore = efficiencyScore
        self.actionItems = actionItems
    }

    init(_ followUp: EfficiencyEngineService.FollowUp) {
        self.init(
            goalType: followUp.goalType,
            label: followUp.label,
            efficiencyScore: followUp.efficiencyScore,
            actionItems: followUp.actionItems.map {
                SavedActionItem(title: $0.title, owner: $0.owner, due: $0.due, ask: $0.ask,
                                score: $0.efficiency.score, missing: $0.efficiency.missing)
            })
    }
}
