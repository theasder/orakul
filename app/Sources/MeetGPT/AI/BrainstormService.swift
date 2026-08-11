import Foundation

/// Fetches blind-spot suggestions for the current call. Prefers the backend
/// (`/api/brainstorm`, which can enrich with server-held MCP/tools/data); falls
/// back to a direct LLM call when no `BACKEND_URL` is configured so the feature
/// works before the backend exists.
///
/// Credit burn (backend path, when the Co-pilot toggle is on): each successful
/// wake reserves compute credits by plan — Free 1, Pro 3, Premium 4, Ultra 5 —
/// before the provider call. Connected-app grounding has its own bounded cycle
/// allowance; large request bodies still use the documented input surcharge.
/// Turning the option off stops the loop and spend.
enum BrainstormService {
    static let maxTranscriptChars = 8000

    /// Granularity at which the transcript window's START is allowed to advance.
    /// A plain `suffix(cap)` slides its start forward on every scan once a call
    /// passes `cap`, which churns the byte-stable prefix the provider prompt
    /// cache keys on — so on a call longer than ~9 minutes the whole transcript
    /// re-bills at full price every scan (freemium finding 11). Snapping the
    /// start to `step`-aligned boundaries holds it fixed BETWEEN jumps, so the
    /// window is append-only there and the cache hits; it moves once per `step`
    /// chars of growth (~2 min), one miss then stable again.
    static let cacheWindowStep = 2000

    static func managedRequest(url: URL,
                               accessToken: String?,
                               devTierOverride: Tier? = Config.devTierOverride) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = ManagedBackendRequestPolicy.backgroundRequestTimeout
        ManagedBackendRequestPolicy.apply(
            to: &request,
            bearerToken: accessToken,
            devTierOverride: devTierOverride)
        return request
    }

    /// Safe execution evidence returned by the managed backend. It contains no
    /// prompt, transcript, provider response body, account data, or credential.
    struct ExecutionTrace: Decodable, Equatable, Sendable {
        struct ProviderAttempt: Codable, Equatable, Sendable {
            private enum CodingKeys: String, CodingKey {
                case provider, model, reason
            }

            let provider: String
            let model: String
            let reason: String

            private static let allowedReasons: Set<String> = [
                "funds exhausted", "rate limited", "credentials rejected",
                "timed out", "not configured", "temporarily unavailable",
                "network failure", "empty response", "request failed",
            ]

            init(provider: String, model: String, reason: String) {
                self.provider = Self.identifier(provider, limit: 64)
                self.model = Self.identifier(model, limit: 128)
                self.reason = Self.allowedReasons.contains(reason) ? reason : "request failed"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                self.init(
                    provider: try values.decodeIfPresent(String.self, forKey: .provider) ?? "unknown",
                    model: try values.decodeIfPresent(String.self, forKey: .model) ?? "unknown",
                    reason: try values.decodeIfPresent(String.self, forKey: .reason) ?? "request failed")
            }

            private static func identifier(_ value: String, limit: Int) -> String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(limit))
            }
        }

        let correlationId: String
        let provider: String?
        let model: String?
        let latencyMs: Int?
        let chargedCredits: Int?
        let cacheHit: Bool?
        let attemptCount: Int?
        let attempts: [ProviderAttempt]?
    }

    struct SuggestionResult: Equatable {
        let suggestions: [Suggestion]
        let execution: ExecutionTrace?
        /// The connector search query the scan asked for (item 10, design #2), or
        /// nil. Present only when the request opted in with `canProbe` AND the
        /// transcript held a checkable claim. The caller runs it against the
        /// connectors it already has and folds the result into the next scan.
        let probeQuery: String?

        init(suggestions: [Suggestion], execution: ExecutionTrace?, probeQuery: String? = nil) {
            self.suggestions = suggestions
            self.execution = execution
            self.probeQuery = probeQuery
        }
    }

    /// - Parameter context: attached docs/notes/connector research (all tiers; Free gets a smaller backend budget).
    /// - Parameter probe: workflow lens id (whattoask / risks / …) for paid rotation.
    /// - Parameter grounded: true when connector apps contributed context from
    ///   the separately bounded grounded-cycle allowance.
    /// - Parameter extraGuidance: skill layers (call theme + user role) so the
    ///   brainstormer frames suggestions for this call's domain and the user's
    ///   job — forwarded to the backend as `guidance`, appended locally.
    /// - Parameter theme: the call's field (`CallTheme.rawValue`). Sent as a
    ///   first-class parameter, NOT folded into `extraGuidance`: the backend
    ///   receives guidance as "advisory only", so a field shipped that way was
    ///   demoted to styling and the domain expertise never reached the scan.
    static func suggestions(goal: String,
                            transcript: String,
                            priorTitles: [String],
                            accessToken: String? = nil,
                            extraGuidance: String? = nil,
                            context: String? = nil,
                            probe: String? = nil,
                            theme: String? = nil,
                            grounded: Bool = false,
                            canProbe: Bool = false) async throws -> [Suggestion] {
        try await suggestionsWithExecution(
            goal: goal, transcript: transcript, priorTitles: priorTitles,
            accessToken: accessToken, extraGuidance: extraGuidance,
            context: context, probe: probe, theme: theme, grounded: grounded,
            canProbe: canProbe
        ).suggestions
    }

    static func suggestionsWithExecution(goal: String,
                                         transcript: String,
                                         priorTitles: [String],
                                         accessToken: String? = nil,
                                         extraGuidance: String? = nil,
                                         context: String? = nil,
                                         probe: String? = nil,
                                         theme: String? = nil,
                                         grounded: Bool = false,
                                         canProbe: Bool = false) async throws -> SuggestionResult {
        let clip = cacheStableWindow(transcript)
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return try await fromBackend(base: base, goal: goal, transcript: clip,
                                         priorTitles: priorTitles, accessToken: accessToken,
                                         extraGuidance: extraGuidance, context: context,
                                         probe: probe, theme: theme, grounded: grounded,
                                         canProbe: canProbe)
        }
        return try await fromLLM(goal: goal, transcript: clip, priorTitles: priorTitles,
                                 extraGuidance: extraGuidance, context: context, probe: probe)
    }

    /// The transcript slice to scan, windowed so the provider prompt cache keeps
    /// hitting across a long call.
    ///
    /// A plain `transcript.suffix(cap)` sends the most-recent `cap` chars, which
    /// is correct content but a moving target: once the call exceeds `cap`, the
    /// window's START advances every scan, the transcript stops being a stable
    /// prefix, and the cache re-bills all of it (finding 11). This snaps the start
    /// DOWN to a `step` boundary, so it only advances once per `step` chars of
    /// growth and stays fixed — append-only — in between.
    ///
    /// The result is a **superset** of `suffix(cap)`: it always contains the most
    /// recent `cap` chars (so evidence quotes are never dropped) plus up to `step`
    /// more of older context, which the scan uses only as background. Quality can
    /// only be equal or better; the cache is what improves.
    static func cacheStableWindow(_ transcript: String,
                                  cap: Int = maxTranscriptChars,
                                  step: Int = cacheWindowStep) -> String {
        let count = transcript.count
        guard count > cap else { return transcript }   // whole transcript — already append-only
        guard step > 0 else { return String(transcript.suffix(cap)) }
        let minStart = count - cap                      // where suffix(cap) would begin
        let anchoredStart = (minStart / step) * step    // snap DOWN to a step boundary (≤ minStart)
        let start = transcript.index(transcript.startIndex, offsetBy: anchoredStart)
        return String(transcript[start...])
    }

    // MARK: Backend

    /// Internal, not private, so the mapping below can be tested directly. It
    /// holds the client-side demotion that guards against a malformed hypothesis
    /// reaching a card, and that guard is worth asserting rather than trusting.
    struct BackendResponse: Decodable {
        struct Item: Decodable {
            let title: String?
            let detail: String?
            let kind: String?
            let evidence: String?
            // Present only on kind == "hypothesis".
            let claim: String?
            let cheapTest: String?
            let costOfMissing: String?
        }
        let suggestions: [Item]?
        let execution: ExecutionTrace?
        let probeQuery: String?
    }

    private struct ErrorResponse: Decodable {
        let execution: ExecutionTrace?
    }

    /// Preserve the backend's safe failure trace while the ordinary LLMError
    /// continues to carry HTTP 429 semantics for the shared quota latch.
    static func executionTrace(from error: Error) -> ExecutionTrace? {
        guard case LLMError.http(_, _, let body) = error,
              let data = body.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return nil
        }
        return decoded.execution
    }

    /// The request body for `/api/brainstorm`. Internal, not private, so the wire
    /// contract is testable: optional fields are OMITTED rather than sent empty,
    /// and `canProbe` is sent only when true — a user without connectors sends a
    /// body byte-identical to the pre-probeQuery one (item 10, design #2).
    static func backendPayload(goal: String, transcript: String, priorTitles: [String],
                               extraGuidance: String?, context: String?, probe: String?,
                               theme: String?, grounded: Bool, canProbe: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "goal": goal,
            "transcript": transcript,
            "priorSuggestions": priorTitles,
            "grounded": grounded,
        ]
        if let extraGuidance, !extraGuidance.isEmpty { payload["guidance"] = extraGuidance }
        if let context, !context.isEmpty { payload["context"] = context }
        if let probe, !probe.isEmpty { payload["probe"] = probe }
        if let theme, !theme.isEmpty { payload["theme"] = theme }
        if canProbe { payload["canProbe"] = true }
        return payload
    }

    private static func fromBackend(base: String, goal: String, transcript: String,
                                    priorTitles: [String], accessToken: String?,
                                    extraGuidance: String? = nil,
                                    context: String? = nil,
                                    probe: String? = nil,
                                    theme: String? = nil,
                                    grounded: Bool = false,
                                    canProbe: Bool = false) async throws -> SuggestionResult {
        guard let url = URL(string: base.hasSuffix("/") ? "\(base)api/brainstorm" : "\(base)/api/brainstorm") else {
            throw LLMError.badResponse("Brainstorm")
        }
        var request = managedRequest(url: url, accessToken: accessToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: backendPayload(
            goal: goal, transcript: transcript, priorTitles: priorTitles,
            extraGuidance: extraGuidance, context: context, probe: probe,
            theme: theme, grounded: grounded, canProbe: canProbe))

        let (data, response) = try await BackendPinning.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Brainstorm", http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(BackendResponse.self, from: data)
        let probeQuery = decoded.probeQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SuggestionResult(
            suggestions: (decoded.suggestions ?? []).compactMap {
                map($0, transcript: transcript)
            },
            execution: decoded.execution,
            probeQuery: (probeQuery?.isEmpty ?? true) ? nil : probeQuery)
    }

    // MARK: LLM fallback

    private static func fromLLM(goal: String, transcript: String,
                                priorTitles: [String],
                                extraGuidance: String? = nil,
                                context: String? = nil,
                                probe: String? = nil) async throws -> SuggestionResult {
        let maxSuggestions = Config.currentTier.rank >= Tier.pro.rank ? 5 : 3
        let prior = priorTitles.isEmpty ? "" :
            "\n\nAlready surfaced — do NOT repeat:\n- " + priorTitles.suffix(40).joined(separator: "\n- ")
        let lens = (probe?.isEmpty == false)
            ? "\n\(BlindSpotProbeRotation.lensBrief(for: probe!))\n"
            : ""
        var system = """
        You are a silent co-pilot on a live call. The user's ONLY stated goal is:
        "\(goal)".\(lens)
        Run ONE multi-lens scan: missing information, risk, counterargument, goal drift, \
        unsupported claim, and unresolved decision. From all lenses together, surface at most \
        \(maxSuggestions) NEW, high-signal blind spots that move the user toward that goal. \
        Write in the same language as the transcript. Every item MUST include an exact 4-20 word \
        quote copied from the transcript as evidence. Be specific to what was said — no generic tips. If \
        nothing is genuinely new, return an empty list. Return ONLY JSON:
        {"suggestions":[{"title":"<=8 words","detail":"1-2 sentences","kind":"question|risk|missing_info|advice","evidence":"exact transcript quote"}]}\(prior)
        """
        if let context, !context.isEmpty {
            system += """


            Attached call context (advisory). Evidence quotes MUST still come from the transcript:
            \(String(context.prefix(6_000)))
            """
        }
        if let extraGuidance, !extraGuidance.isEmpty { system += "\n\n" + extraGuidance }
        let user = transcript.isEmpty ? "No transcript yet." : "Transcript so far:\n\(transcript)"

        let startedAt = Date()
        let model = Config.selectedModel
        let text = try await LLMGatewayFactory.make().streamChat(
            system: system, user: user, model: model) { _ in }
        guard let json = JSONExtraction.firstObject(in: text),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BackendResponse.self, from: data) else {
            return SuggestionResult(
                suggestions: [],
                execution: ExecutionTrace(
                    correlationId: UUID().uuidString, provider: "direct",
                    model: model.id,
                    latencyMs: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                    chargedCredits: nil, cacheHit: false, attemptCount: 1,
                    attempts: nil))
        }
        return SuggestionResult(
            suggestions: (decoded.suggestions ?? []).compactMap {
                map($0, transcript: transcript)
            },
            execution: ExecutionTrace(
                correlationId: UUID().uuidString, provider: "direct",
                model: model.id,
                latencyMs: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
                chargedCredits: nil, cacheHit: false, attemptCount: 1,
                attempts: nil))
    }

    // MARK: Helpers

    static func map(_ item: BackendResponse.Item, transcript: String) -> Suggestion? {
        guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        guard SuggestionGrounding.contains(evidence: item.evidence, in: transcript) else { return nil }
        let kind = SuggestionKind(rawValue: item.kind ?? "advice") ?? .advice
        let blank = { (value: String?) -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        // A hypothesis with nothing to test is a hunch the user cannot act on.
        // The server already demotes those, but a client that trusted the kind
        // alone would render an empty card if that ever regressed — so the
        // demotion is enforced here too rather than assumed upstream.
        let claim = blank(item.claim)
        let cheapTest = blank(item.cheapTest)
        let resolvedKind: SuggestionKind = (kind == .hypothesis && (claim == nil || cheapTest == nil))
            ? .advice : kind
        return Suggestion(title: title, detail: item.detail ?? "", kind: resolvedKind,
                          evidence: blank(item.evidence),
                          claim: resolvedKind == .hypothesis ? claim : nil,
                          cheapTest: resolvedKind == .hypothesis ? cheapTest : nil,
                          costOfMissing: resolvedKind == .hypothesis ? blank(item.costOfMissing) : nil)
    }

    /// Pull the first `{ … }` object out of a model reply (handles code fences).
}
