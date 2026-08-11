import Foundation

/// The Log Decision button's engine: extract the decision just made on the call
/// as a structured record, then file it into the Decision Ledger backend
/// (`POST /api/decisions`). With no backend configured (or signed out) the
/// capture still renders locally — the ledger write is best-effort on top.
enum DecisionLogService {
    private static let maxTranscriptChars = 12_000

    /// Ledger goal types — must mirror the server's contract table
    /// (functions/ledger/goalContracts.js), since the extractor coerces anything
    /// outside this list to `planning` before the API sees it.
    ///
    /// That coercion makes drift SILENT rather than loud: while this list held
    /// only the original six, a retro or design review was rewritten as a
    /// planning decision and got a planning-shaped follow-up, with no error
    /// anywhere. `test/goalTypeMirror.test.js` fails if the two lists diverge.
    static let goalTypes = [
        "close_deal", "product_feedback", "hiring", "incident", "planning", "vendor_eval",
        "one_on_one", "retro", "status_review", "design_review",
    ]

    struct CapturedDecision: Codable, Equatable {
        var title: String
        var statement: String?
        var goalType: String
        var status: String?           // proposed | decided
        var rationale: String?
        var optionsConsidered: [String]?
        var risks: [String]?
        var stakeholders: [String]?

        var markdown: String {
            var lines = ["## 📌 \(title)"]
            if let statement, !statement.isEmpty { lines.append(statement) }
            lines.append("- **Status:** \(status ?? "proposed") · **Goal:** \(goalType.replacingOccurrences(of: "_", with: " "))")
            if let rationale, !rationale.isEmpty { lines.append("- **Why:** \(rationale)") }
            if let options = optionsConsidered, !options.isEmpty {
                lines.append("- **Options considered:** \(options.joined(separator: "; "))")
            }
            if let risks, !risks.isEmpty { lines.append("- **Risks:** \(risks.joined(separator: "; "))") }
            if let stakeholders, !stakeholders.isEmpty {
                lines.append("- **Stakeholders:** \(stakeholders.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Extraction

    /// Pull the most recent concrete decision out of the transcript. Returns nil
    /// when the model reports no decision was actually made (an honest miss
    /// beats logging noise into the ledger).
    static func extract(transcript: String, context: String, goal: String,
                        extraGuidance: String? = nil,
                        model: LLMModel = Config.selectedRequestModel) async throws -> CapturedDecision? {
        let clip = String(transcript.suffix(maxTranscriptChars))
        guard !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var system = """
        You capture the decision a meeting just made, for a durable decision ledger. Find the most \
        recent CONCRETE decision in the transcript — a commitment the group actually made, not a \
        topic discussed or an option floated. Record only what was said: quote-faithful statement, \
        the stated rationale, options that were raised (mark rejected ones), risks voiced, and the \
        people involved. Never invent rationale or consensus; if dissent was voiced, include it in \
        the rationale ("decided over X's objection that ..."). If the provided background lists an \
        earlier ledger decision this one reopens or contradicts, say so in the rationale \
        ("reopens the <date> decision to ..."). status: "decided" when the group \
        committed, "proposed" when it still needs sign-off. goalType MUST be one of: \
        \(goalTypes.joined(separator: ", ")). If NO real decision was made, return {"decision":null}.
        Return ONLY JSON:
        {"decision":{"title":"<=12 words","statement":"1-2 sentences","goalType":"...","status":"decided|proposed","rationale":"...","optionsConsidered":["..."],"risks":["..."],"stakeholders":["..."]}}
        """
        if let extraGuidance, !extraGuidance.isEmpty { system += "\n\n" + extraGuidance }

        var user = "Transcript:\n\(clip)"
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty { user = "Meeting goal: \(trimmedGoal)\n\n" + user }
        if !context.isEmpty { user += "\n\nAdditional context:\n\(String(context.prefix(6000)))" }

        let text = try await LLMGatewayFactory.make().streamChat(
            system: system, user: user, model: model) { _ in }
        guard let json = JSONExtraction.firstObject(in: text), let data = json.data(using: .utf8) else { return nil }
        struct Envelope: Decodable { let decision: CapturedDecision? }
        guard var decision = (try? JSONDecoder().decode(Envelope.self, from: data))?.decision,
              !decision.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Coerce out-of-vocabulary goal types instead of letting the API 400.
        if !goalTypes.contains(decision.goalType) { decision.goalType = "planning" }
        if let status = decision.status, status != "decided", status != "proposed" {
            decision.status = "proposed"
        }
        return decision
    }

    // MARK: - Ledger as context (A9)

    /// A ledger decision as the list endpoint returns it — the subset the
    /// grounding renderer needs.
    struct LedgerDecision: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let statement: String?
        let status: String
        let goalType: String
        let decidedAt: String?
        let createdAt: String
        let rationale: String?
        let outcome: String?
    }

    /// The team's most recent decisions (newest first; API scopes to the
    /// caller's teams). Continuity grounding for dispute/unresolved/agenda/
    /// summary/log-decision.
    static func recentDecisions(base: String, token: String, limit: Int = 15) async throws -> [LedgerDecision] {
        try await request(base: base, path: "api/decisions?limit=\(max(1, min(limit, 50)))&offset=0",
                          method: "GET", token: token)
    }

    /// Render decisions as a compact grounding block: one line each, newest
    /// first, capped. Pure for testability.
    static func renderForGrounding(_ decisions: [LedgerDecision], cap: Int) -> String {
        var lines = ["Your team's logged decisions (newest first) — flag anything that reopens or contradicts one:"]
        var budget = max(400, cap) - lines[0].count
        for decision in decisions {
            let date = String((decision.decidedAt ?? decision.createdAt).prefix(10))
            var line = "• \(date) [\(decision.status)] \(decision.title)"
            if let statement = decision.statement, !statement.isEmpty {
                line += " — \(String(statement.prefix(140)))"
            }
            if let outcome = decision.outcome, !outcome.isEmpty {
                line += " (outcome: \(String(outcome.prefix(80))))"
            }
            // Charge the joining newline too. Budgeting only `line.count` while
            // rendering with `joined(separator:)` overshot the cap by one
            // character per decision — 2018 characters against a 2000 cap on a
            // long ledger. This string is prepended to prompts, so the cap is a
            // cost contract, not a hint.
            guard budget - (line.count + 1) > 0 else { break }
            budget -= line.count + 1
            lines.append(line)
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    enum LedgerError: LocalizedError {
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Ledger API error (\(code)): \(String(body.prefix(160)))"
            case .malformed: return "Ledger API returned an unexpected shape."
            }
        }
    }

    /// The team the app files decisions into: the persisted choice when it still
    /// exists server-side, else the user's first team, else a newly created
    /// "My Ledger". Persists the resolved id for next time.
    static func ensureTeam(base: String, token: String) async throws -> (id: String, name: String) {
        struct Team: Decodable { let id: String; let name: String }
        let teams: [Team] = try await request(base: base, path: "api/teams", method: "GET", token: token)

        let savedID = UserDefaults.standard.string(forKey: "ledger.teamId")
        if let saved = teams.first(where: { $0.id == savedID }) {
            return (saved.id, saved.name)
        }
        if let first = teams.first {
            UserDefaults.standard.set(first.id, forKey: "ledger.teamId")
            return (first.id, first.name)
        }
        let created: Team = try await request(base: base, path: "api/teams", method: "POST",
                                              token: token, body: ["name": "My Ledger"])
        UserDefaults.standard.set(created.id, forKey: "ledger.teamId")
        return (created.id, created.name)
    }

    /// File the decision. Returns the created ledger record's id.
    static func logDecision(_ decision: CapturedDecision, teamID: String,
                            base: String, token: String) async throws -> String {
        struct Created: Decodable { let id: String }
        var body: [String: Any] = [
            "teamId": teamID,
            "title": decision.title,
            "goalType": decision.goalType,
        ]
        if let v = decision.statement, !v.isEmpty { body["statement"] = v }
        if let v = decision.status { body["status"] = v }
        if let v = decision.rationale, !v.isEmpty { body["rationale"] = v }
        if let v = decision.optionsConsidered, !v.isEmpty { body["optionsConsidered"] = v }
        if let v = decision.risks, !v.isEmpty { body["risks"] = v }
        if let v = decision.stakeholders, !v.isEmpty { body["stakeholders"] = v }
        let created: Created = try await request(base: base, path: "api/decisions", method: "POST",
                                                 token: token, body: body)
        return created.id
    }

    private struct Envelope<D: Decodable>: Decodable { let success: Bool; let data: D }

    /// One call against the ledger's `{ success, data }` envelope.
    private static func request<T: Decodable>(base: String, path: String, method: String,
                                              token: String, body: [String: Any]? = nil) async throws -> T {
        let joined = base.hasSuffix("/") ? base + path : base + "/" + path
        guard let url = URL(string: joined) else { throw LedgerError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await BackendPinning.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LedgerError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(Envelope<T>.self, from: data), decoded.success else {
            throw LedgerError.malformed
        }
        return decoded.data
    }

}
