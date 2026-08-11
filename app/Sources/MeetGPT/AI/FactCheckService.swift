import Foundation

/// Fact-checks the recent transcript against the call's user-provided context.
/// Prefers the backend (`/api/factcheck`, which can additionally ground in MCP
/// resources server-side); falls back to a direct LLM call grounded in the same
/// context when no `BACKEND_URL` is configured.
enum FactCheckService {
    private static let maxTranscriptChars = 8000
    private static let maxContextChars = 16000

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

    /// - Parameter extraGuidance: optional skill layers (call theme + user role)
    ///   appended to the checker's system prompt to steer claim *selection* and
    ///   framing. The strict JSON output contract stays authoritative, so the
    ///   full factcheck PromptSkill (confidence levels, counter-questions) is
    ///   deliberately NOT passed — FactClaim has no fields for it. Applies to
    ///   the direct-LLM path only; the backend owns its own prompt.
    static func check(transcript: String, context: String,
                      accessToken: String? = nil,
                      extraGuidance: String? = nil,
                      model: LLMModel = Config.selectedRequestModel) async throws -> [FactClaim] {
        try await checkWithSearch(
            transcript: transcript, context: context, accessToken: accessToken,
            extraGuidance: extraGuidance, model: model, searchWeb: false).claims
    }

    /// What the web lane did for one check (item 11). `ran == false` with a
    /// reason is an answer too — "web search is not configured on this server"
    /// must reach the user, not vanish into a silently plain result.
    struct WebSearchOutcome: Decodable, Equatable {
        struct Source: Decodable, Equatable {
            let url: String?
            let title: String?
        }
        let ran: Bool?
        let reason: String?
        let sources: [Source]?
        let credits: Int?
    }

    /// The full check, with the explicit per-request web opt-in. `searchWeb` is
    /// the never-silent rule made API: only a deliberate caller — the sheet's
    /// button, never the background cadence loop — passes true, and only then
    /// does meeting content reach a search provider.
    static func checkWithSearch(transcript: String, context: String,
                                accessToken: String? = nil,
                                extraGuidance: String? = nil,
                                model: LLMModel = Config.selectedRequestModel,
                                searchWeb: Bool = false)
        async throws -> (claims: [FactClaim], search: WebSearchOutcome?) {
        let clip = String(transcript.suffix(maxTranscriptChars))
        guard !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ([], nil) }
        let ctx = String(context.prefix(maxContextChars))
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return try await fromBackend(base: base, transcript: clip, context: ctx,
                                         accessToken: accessToken, extraGuidance: extraGuidance,
                                         searchWeb: searchWeb)
        }
        // The direct-LLM fallback has no search provider; the lane simply does
        // not exist there, which is different from "asked and unavailable".
        return (try await fromLLM(
            transcript: clip, context: ctx, extraGuidance: extraGuidance, model: model), nil)
    }

    /// The request body for `/api/factcheck`. Internal so the wire contract is
    /// testable: `searchWeb` rides the body ONLY when true — the backend treats
    /// anything else as false, and a client that always sent the key would make
    /// the metered opt-in look ambient.
    static func backendPayload(transcript: String, context: String,
                               extraGuidance: String?, searchWeb: Bool) -> [String: Any] {
        var payload: [String: Any] = ["transcript": transcript, "context": context]
        if let extraGuidance, !extraGuidance.isEmpty { payload["guidance"] = extraGuidance }
        if searchWeb { payload["searchWeb"] = true }
        return payload
    }

    /// Internal, not private, so the wire decode is testable directly.
    struct Response: Decodable {
        struct Item: Decodable {
            let claim: String?
            let status: String?
            let explanation: String?
            let source: String?
            let confidence: String?       // high|medium|low (optional; legacy backends omit)
            let counterQuestion: String?  // sharpest confirm/falsify question
            // Web lane (item 11): where the verdict's evidence came from, and
            // the retrieved page behind a web-checked one.
            let provenance: String?
            let sourceUrl: String?
            let sourceTitle: String?
        }
        let claims: [Item]?
        let search: WebSearchOutcome?
    }

    // MARK: Backend

    private static func fromBackend(base: String, transcript: String, context: String,
                                    accessToken: String?, extraGuidance: String? = nil,
                                    searchWeb: Bool = false)
        async throws -> (claims: [FactClaim], search: WebSearchOutcome?) {
        let path = base.hasSuffix("/") ? "\(base)api/factcheck" : "\(base)/api/factcheck"
        guard let url = URL(string: path) else { throw LLMError.badResponse("Fact check") }
        var request = managedRequest(url: url, accessToken: accessToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: backendPayload(
            transcript: transcript, context: context,
            extraGuidance: extraGuidance, searchWeb: searchWeb))

        let (data, response) = try await BackendPinning.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http("Fact check", http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return ((decoded.claims ?? []).compactMap(map), decoded.search)
    }

    // MARK: LLM fallback (grounded in the provided context only)

    private static func fromLLM(transcript: String, context: String,
                                extraGuidance: String? = nil,
                                model: LLMModel) async throws -> [FactClaim] {
        var system = """
        You are a fact-checker for a live meeting. You are given the meeting CONTEXT (documents and \
        notes the user attached for this call) and the recent TRANSCRIPT. Extract the concrete \
        factual claims/stats stated in the transcript and verify EACH ONLY against the CONTEXT — do \
        NOT use outside knowledge. status: "verified" (context supports it), "contradicted" (context \
        contradicts it), "needs_context" (checkable but context doesn't cover it), "unverifiable" \
        (opinion/prediction/too vague). Quote the context snippet in "source" for verified or \
        contradicted, else null. If the context is empty, checkable claims are "needs_context". Do \
        NOT invent sources.

        SEPARATELY, check the NUMBERS in the transcript against EACH OTHER — this needs no context \
        and must run even when the context is empty. Use status "inconsistent" when the call \
        contradicts itself: the same quantity given two different values ("ARR is 4 million" then \
        "ARR is 5.2 million"), a percentage or total that does not follow from the figures stated \
        ("2M revenue, 900k costs, so 70% margin"), a rate that conflicts with its own period, or a \
        date/duration that cannot hold. For "inconsistent", set "source" to the EARLIER conflicting \
        figure quoted verbatim FROM THE TRANSCRIPT (not from the context), and make the explanation \
        name both figures so the reader can see the conflict without re-reading. Only flag \
        arithmetic you can actually carry out from stated numbers; do not infer missing operands, \
        and treat an explicitly revised figure ("sorry, 5.2 not 4") as a correction, not a conflict. \
        Rate each verdict's confidence from the strength and directness of its \
        evidence (a verbatim match = high; an inference across snippets = medium; thin/ambiguous \
        coverage = low). For checkable claims also give counterQuestion: the single sharpest, \
        neutral question (<=25 words) that would confirm or falsify the claim; null for \
        unverifiable ones. Return ONLY JSON:
        {"claims":[{"claim":"<=20 words","status":"verified|contradicted|needs_context|unverifiable|inconsistent","explanation":"1 sentence","source":"snippet or null","confidence":"high|medium|low","counterQuestion":"<=25 words or null"}]}
        """
        if let extraGuidance, !extraGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Theme/role layers steer which claims matter; the JSON contract above stays authoritative.
            system += "\n\n" + extraGuidance
        }
        // The context block is the same on every pass of a call — it is the
        // attached documents — while the transcript grows between passes. Split
        // there so a provider with explicit caching can reuse the half that
        // repeats. Concatenated, these are byte-identical to the single string
        // this used to send.
        let cachedPrefix = "CONTEXT (the only source of truth for external verification):\n"
            + (context.isEmpty ? "(none provided)" : context) + "\n\n"
        let volatileSuffix = "TRANSCRIPT to check:\n\(transcript)"

        let text = try await LLMGatewayFactory.make().streamChat(
            system: system, cachedPrefix: cachedPrefix,
            volatileSuffix: volatileSuffix, images: [], model: model,
            maxOutputTokens: nil, onUsage: nil) { _ in }
        guard let json = JSONExtraction.firstObject(in: text),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return (decoded.claims ?? []).compactMap(map)
    }

    // MARK: Helpers

    /// Internal, not private, so the provenance mapping is testable directly.
    static func map(_ item: Response.Item) -> FactClaim? {
        guard let text = item.claim?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let status = FactClaim.Status(rawValue: item.status ?? "unverifiable") ?? .unverifiable
        let source = item.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = item.counterQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blank = { (value: String?) -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        // A web sourceUrl must be http(s): the snippet it came from is
        // attacker-influenceable web content, and a javascript:/data: link in a
        // claim card would hand that content a click.
        let sourceUrl = blank(item.sourceUrl).flatMap { raw -> String? in
            raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://")
                ? raw : nil
        }
        return FactClaim(text: text, status: status, explanation: item.explanation ?? "",
                         source: (source?.isEmpty ?? true) ? nil : source,
                         confidence: item.confidence.flatMap { FactClaim.Confidence(rawValue: $0.lowercased()) },
                         counterQuestion: (question?.isEmpty ?? true) ? nil : question,
                         provenance: blank(item.provenance),
                         sourceUrl: sourceUrl,
                         sourceTitle: blank(item.sourceTitle))
    }

}
