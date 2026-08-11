import Foundation

/// The Efficiency Engine, client side: asks the backend for a follow-up SHAPED BY
/// THE DECISION'S GOAL (`POST /api/decisions/:id/follow-up`) and renders it.
///
/// NOT to be confused with `FollowUpService`, which proposes the next BUTTONS to
/// press. This produces the goal-shaped write-up of a decision — the M3
/// differentiator — and both run in the Log Decision flow, so the names are kept
/// apart deliberately.
///
/// Fields differ per goal: a close_deal follow-up carries `next_step` and
/// `pricing_state`, a retro carries `experiments` and `recurring_themes`. So the
/// renderer is GENERIC. Hardcoding ten layouts here would drift the moment a
/// contract changes server-side, and the server's contract table is the single
/// place a goal is supposed to be defined.
enum EfficiencyEngineService {
    /// A JSON value from a contract field. The contracts hold strings, dates,
    /// string lists and small records, so this is the whole vocabulary — used
    /// instead of `[String: Any]`, which cannot cross an isolation boundary under
    /// Swift 6 and cannot be constructed in a test without casting.
    enum Value: Decodable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case list([Value])
        case object([String: Value])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode([Value].self) { self = .list(value); return }
            if let value = try? container.decode([String: Value].self) { self = .object(value); return }
            self = .null
        }

        /// One-line rendering. Records become "key: value" pairs and nulls are
        /// dropped, so an unfilled contract field reads as absent rather than as
        /// the literal word "null".
        var inline: String? {
            switch self {
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .number(let value):
                return value == value.rounded() ? String(Int(value)) : String(value)
            case .bool(let value):
                return value ? "yes" : "no"
            case .list(let values):
                let parts = values.compactMap(\.inline)
                return parts.isEmpty ? nil : parts.joined(separator: "; ")
            case .object(let fields):
                let parts = fields.keys.sorted().compactMap { key -> String? in
                    guard let value = fields[key]?.inline else { return nil }
                    return "\(EfficiencyEngineService.humanize(key)): \(value)"
                }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            case .null:
                return nil
            }
        }
    }

    struct Efficiency: Decodable, Sendable, Equatable {
        let score: Double
        let missing: [String]
        let reasons: [String]
    }

    struct ActionItem: Decodable, Sendable, Equatable {
        let title: String
        let owner: String?
        let due: String?
        let ask: String?
        let efficiency: Efficiency
    }

    struct FollowUp: Decodable, Sendable, Equatable {
        let goalType: String
        let label: String
        let fields: [String: Value]
        let actionItems: [ActionItem]
        let efficiencyScore: Double
        let model: String?
    }

    enum Failure: LocalizedError {
        case notConfigured
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Follow-ups need a backend — set BACKEND_URL."
            case .http(let code, let message):
                return message.isEmpty ? "Follow-up failed (\(code))." : message
            case .malformed:
                return "The follow-up came back in an unreadable shape."
            }
        }
    }

    /// One goal's contract as `GET /api/goal-contracts` describes it. Fetched
    /// rather than duplicated in Swift: `fields` arrives in the server's
    /// DECLARATION order, which is the only thing that knows `next_step` should
    /// print above `objections`. A second hardcoded list here is exactly the
    /// drift the goal-type mirror test exists to stop.
    struct Contract: Decodable, Sendable, Equatable {
        let goalType: String
        let label: String
        let optimizes: String
        let fields: [String]
    }

    private struct Envelope: Decodable { let success: Bool; let data: FollowUp }
    private struct ContractsEnvelope: Decodable { let success: Bool; let data: [Contract] }

    static func contracts(base: String, token: String,
                          session: URLSession = BackendPinning.shared) async throws -> [Contract] {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !root.isEmpty, let url = URL(string: "\(root)/api/goal-contracts") else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode, "")
        }
        guard let decoded = try? JSONDecoder().decode(ContractsEnvelope.self, from: data), decoded.success else {
            throw Failure.malformed
        }
        return decoded.data
    }

    /// Ask for the follow-up. `goalType` overrides the decision's stored one
    /// WITHOUT persisting it, so the same decision can be written up as a deal
    /// and as a plan for comparison — that regeneration is what makes the
    /// per-goal shaping visible rather than merely claimed.
    static func generate(decisionID: String, goalType: String? = nil, sourceText: String? = nil,
                         base: String, token: String,
                         session: URLSession = BackendPinning.shared) async throws -> FollowUp {
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !root.isEmpty,
              let url = URL(string: "\(root)/api/decisions/\(decisionID)/follow-up") else {
            throw Failure.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // One model generation over transcript-length input outruns the 20s the
        // other ledger calls use; those are CRUD round-trips, this is not.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [:]
        if let goalType, !goalType.isEmpty { body["goalType"] = goalType }
        if let sourceText, !sourceText.isEmpty { body["text"] = String(sourceText.suffix(12_000)) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw Failure.http(http.statusCode, message)
        }
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data), decoded.success else {
            throw Failure.malformed
        }
        return decoded.data
    }

    // MARK: - Rendering

    /// `next_step` -> `Next step`, `unambiguous-ask` -> `Unambiguous ask`.
    ///
    /// BOTH separators matter. Contract field names are snake_case, but the
    /// scorer's `missing` reasons are hyphenated (`unambiguous-ask`), and they go
    /// through here too — splitting only on `_` rendered "Unambiguous-ask" in the
    /// one line whose whole job is telling the user what to fix.
    static func humanize(_ key: String) -> String {
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let first = words.first, !first.isEmpty else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// A 0–1 score as a five-block bar. Faster to scan than a decimal, and a weak
    /// item is obvious without reading the number.
    static func bar(_ score: Double) -> String {
        let filled = Int((max(0, min(1, score)) * 5).rounded())
        let clamped = max(0, min(5, filled))
        return String(repeating: "█", count: clamped) + String(repeating: "░", count: 5 - clamped)
    }

    /// Markdown for the assistant pane. Pure, so the tests render fixtures
    /// instead of driving the network.
    ///
    /// `fieldOrder` follows the server's declaration order when supplied: a
    /// dictionary has none, and alphabetising a contract would put `objections`
    /// above `next_step`, burying the thing the user has to act on.
    static func render(_ followUp: FollowUp, fieldOrder: [String] = []) -> String {
        var lines = ["### Follow-up — \(followUp.label)"]

        let known = fieldOrder.filter { followUp.fields[$0] != nil }
        let rest = followUp.fields.keys.filter { !fieldOrder.contains($0) }.sorted()
        for key in known + rest {
            guard let value = followUp.fields[key] else { continue }
            let title = humanize(key)
            if case .list(let items) = value, items.count > 1 {
                // Multi-entry lists earn bullets; one entry reads better inline.
                let rendered = items.compactMap(\.inline)
                if rendered.isEmpty {
                    lines.append("- **\(title):** _none recorded_")
                } else {
                    lines.append("- **\(title):**")
                    lines.append(contentsOf: rendered.map { "  - \($0)" })
                }
            } else {
                lines.append("- **\(title):** \(value.inline ?? "_none recorded_")")
            }
        }

        guard !followUp.actionItems.isEmpty else {
            lines.append("")
            lines.append("_No action items were supported by the transcript._")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("**Action items** — scored on owner, date, and one clear ask")
        for item in followUp.actionItems {
            var line = "- \(bar(item.efficiency.score)) \(item.title)"
            var facts: [String] = []
            if let owner = item.owner, !owner.isEmpty { facts.append(owner) }
            if let due = item.due, !due.isEmpty { facts.append("due \(due)") }
            if !facts.isEmpty { line += " — \(facts.joined(separator: ", "))" }
            lines.append(line)
            // Name what is missing rather than only scoring it down: the point is
            // for a human to fix the item, and that needs the reason.
            if !item.efficiency.missing.isEmpty {
                lines.append("  - _needs: \(item.efficiency.missing.map(humanize).joined(separator: ", "))_")
            }
        }
        return lines.joined(separator: "\n")
    }
}
