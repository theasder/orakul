import Foundation

/// "Auto" model = intelligent orchestration: each request is scored and served
/// by the most appropriate model — or combination of models — the user's plan
/// allows. Higher tiers unlock stronger combinations:
///
///   Free     light → GPT-5.4 mini · heavy → Gemini Flash
///   Pro      light → GPT-5.4 mini · heavy → Claude Sonnet 5
///   Premium  light → GPT-5.4 mini · medium → Claude Opus 5
///            hard  → the Council (US+CN panel + chairman synthesis)
///
/// When a concrete model is selected instead of "auto", it stays primary; in
/// direct-key mode only, a pre-output provider failure may use another vendor.
final class AutoOrchestrator: LLMGateway {
    typealias FallbackResolver = (_ primary: LLMModel, _ tier: Tier, _ hasImages: Bool) -> [LLMModel]

    private let inner: LLMGateway
    private let council: EnsembleGateway
    private let selectionProvider: () -> String
    private let tierProvider: () -> Tier
    private let directClientMode: () -> Bool
    private let fallbackResolver: FallbackResolver

    /// Provider callbacks are not actor-isolated and a gateway may invoke them
    /// from a URLSession delegate queue. Keep the retry barrier synchronized.
    private final class OutputObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var started: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func observe(_ delta: String) {
            guard !delta.isEmpty else { return }
            lock.lock(); value = true; lock.unlock()
        }
    }

    /// `inner` is whatever LLM_GATEWAY configured (direct router or the managed
    /// backend); the council is built lazily-cheap and only engaged on Premium.
    init(inner: LLMGateway,
         selectionProvider: @escaping () -> String = { Config.selectedModelID },
         tierProvider: @escaping () -> Tier = { Config.currentTier },
         directClientMode: @escaping () -> Bool = {
             !Config.llmViaBackend && !Config.llmViaEnsemble
         },
         fallbackResolver: @escaping FallbackResolver = {
             AutoOrchestrator.providerFallbackModels(
                 excluding: $0.provider, tier: $1, hasImages: $2)
         }) {
        self.inner = inner
        self.council = EnsembleGateway()
        self.selectionProvider = selectionProvider
        self.tierProvider = tierProvider
        self.directClientMode = directClientMode
        self.fallbackResolver = fallbackResolver
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: images, model: model,
                             maxOutputTokens: nil, onDelta: onDelta)
    }

    // This wrapper sits in front of EVERY gateway (LLMGatewayFactory.make), so
    // without an explicit forward the protocol's default would silently drop
    // the caller's ceiling and the long-output path would still truncate.
    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        // AppState attaches the picker value captured when the answer began.
        // Fall back to the provider for legacy/background callers that pass a
        // plain catalog model. Reading only the live provider here allowed a
        // mid-grounding Settings change to reroute the current answer.
        let selection = model.requestSelectionID ?? selectionProvider()
        let tier = tierProvider()
        // Price-tiered orchestration council (Auto's richer siblings): backend
        // mode runs it server-side (keyless launch — the councils live on the
        // server); direct-key mode runs the client EnsembleGateway with the
        // level's panel. The server enforces the tier gate; the picker only
        // OFFERS levels the tier allows.
        if let level = OrchestrationLevel.from(selection: selection) {
            if Config.llmViaBackend {
                return try await OrchestrateService.stream(
                    level: level.rawValue, system: system, user: user,
                    maxOutputTokens: maxOutputTokens, onDelta: onDelta)
            }
            let members = level.memberModelIDs.compactMap { id in
                LLMCatalog.model(id: id).map { EnsembleGateway.Member(provider: $0.provider, modelID: id) }
            }
            if members.count >= 2 {
                return try await EnsembleGateway(members: members)
                    .streamChat(system: system, user: user, images: images, model: model,
                                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
            }
            // Not enough providers configured — fall through to normal routing.
        }
        // Single-jurisdiction council: the user picked the US-only or China-only
        // panel — answer from just that jurisdiction's configured providers.
        if selection == LLMCatalog.councilUS || selection == LLMCatalog.councilCN {
            let jurisdiction: LLMProvider.Jurisdiction = selection == LLMCatalog.councilUS ? .us : .china
            let members = LLMCatalog.councilPanel(jurisdiction, for: Config.currentTier)
            if members.count >= 2 {
                return try await EnsembleGateway(members: members)
                    .streamChat(system: system, user: user, images: images, model: model,
                                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
            }
            // Not enough providers configured — fall through to normal routing.
        }
        // Provider-pinned Auto ("auto:<provider>"): orchestrate versions
        // WITHIN the chosen provider by request effort.
        if selection.hasPrefix("auto:"),
           let provider = LLMProvider(rawValue: String(selection.dropFirst("auto:".count))) {
            let effort = Self.effort(user: user, images: images)
            let routed = Self.route(effort, tier: tier, hasImages: !images.isEmpty, within: provider)
            return try await streamWithProviderFallback(
                system: system, user: user, images: images, model: routed, tier: tier,
                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }
        guard selection == LLMCatalog.autoID else {
            // A concrete selection stays primary, but direct-client mode may
            // recover on another configured vendor before output begins.
            return try await streamWithProviderFallback(
                system: system, user: user, images: images, model: model, tier: tier,
                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }

        let effort = Self.effort(user: user, images: images)

        // Premium + hard → the Council, when its providers are configured.
        if tier == .premium, effort == .hard, councilAvailable {
            return try await council.streamChat(system: system, user: user, images: images,
                                                model: Self.route(.hard, tier: tier, hasImages: !images.isEmpty),
                                                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }
        let routed = Self.route(effort, tier: tier, hasImages: !images.isEmpty)
        return try await streamWithProviderFallback(
            system: system, user: user, images: images, model: routed, tier: tier,
            maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }

    // MARK: - Direct-provider fallback

    /// Try configured vendors in turn when the direct provider fails before it
    /// emits text. Once any non-empty delta is visible, retrying would duplicate
    /// or splice answers, so that error is returned without another attempt.
    /// Managed Backend/Orchestrate errors never enter this path: their 401 is a
    /// Cruxwing session problem and their 429 is the user's compute-credit cap.
    private func streamWithProviderFallback(system: String, user: String, images: [Data],
                                            model: LLMModel, tier: Tier,
                                            maxOutputTokens: Int? = nil,
                                            onDelta: @escaping (String) -> Void) async throws -> String {
        let primaryOutput = OutputObservation()
        do {
            return try await inner.streamChat(system: system, user: user, images: images,
                                              model: model, maxOutputTokens: maxOutputTokens,
                                              onDelta: { delta in
                primaryOutput.observe(delta)
                onDelta(delta)
            })
        } catch {
            // Backend errors belong to the Cruxwing account/session and must
            // preserve their actionable body. Direct-provider bodies are not
            // safe to surface: vendor auth/quota responses can contain account
            // identifiers or credential suffixes, including after a partial
            // stream or when no alternate key is configured.
            if Self.isCancellation(error) || Self.isBackendOwned(error) { throw error }
            guard directClientMode() else { throw error }
            if primaryOutput.started {
                guard Self.isProviderOwned(error, by: model.provider) else { throw error }
                throw ProviderFailoverError(
                    attempts: [.init(
                        provider: model.provider,
                        category: Self.failureCategory(for: error, provider: model.provider))],
                    outputStarted: true)
            }
            guard let category = Self.failoverCategory(
                for: error, provider: model.provider)
            else {
                guard Self.isProviderOwned(error, by: model.provider) else { throw error }
                throw ProviderFailoverError(
                    attempts: [.init(
                        provider: model.provider,
                        category: Self.failureCategory(for: error, provider: model.provider))],
                    outputStarted: false)
            }

            var failures = [ProviderAttemptFailure(provider: model.provider, category: category)]
            var attempted = Set([model.provider])
            let candidates = fallbackResolver(model, tier, !images.isEmpty)
            let estimatedInputTokens = max(
                1, (system.utf16.count + user.utf16.count + 3) / 4)
            let primaryCreditCeiling = CreditCostEstimate.credits(
                model: model.id,
                inputTokens: estimatedInputTokens,
                imageCount: images.count,
                maxOutputTokens: maxOutputTokens)

            for fallback in candidates
            where !attempted.contains(fallback.provider)
                && fallback.isAvailable(for: tier)
                && (images.isEmpty || fallback.supportsVision)
                && CreditCostEstimate.credits(
                    model: fallback.id,
                    inputTokens: estimatedInputTokens,
                    imageCount: images.count,
                    maxOutputTokens: maxOutputTokens) <= primaryCreditCeiling {
                attempted.insert(fallback.provider)
                let previous = failures[failures.count - 1]
                Log.general.notice(
                    "LLM \(previous.category.rawValue, privacy: .public) on \(previous.provider.rawValue, privacy: .public) — retrying via \(fallback.provider.rawValue, privacy: .public)"
                )
                let fallbackOutput = OutputObservation()
                do {
                    return try await inner.streamChat(
                        system: system, user: user, images: images, model: fallback,
                        maxOutputTokens: maxOutputTokens, onDelta: { delta in
                            fallbackOutput.observe(delta)
                            onDelta(delta)
                        })
                } catch {
                    if Self.isCancellation(error) || Self.isBackendOwned(error) { throw error }
                    let nextCategory = Self.failureCategory(for: error, provider: fallback.provider)
                    failures.append(.init(provider: fallback.provider, category: nextCategory))
                    if fallbackOutput.started {
                        throw ProviderFailoverError(attempts: failures, outputStarted: true)
                    }
                    // A request-level rejection (for example HTTP 400) will be
                    // shared by every vendor; only provider-local failures are
                    // safe to continue past.
                    guard Self.failoverCategory(for: error, provider: fallback.provider) != nil else {
                        throw ProviderFailoverError(attempts: failures, outputStarted: false)
                    }
                }
            }

            // Even a one-attempt exhaustion uses the bounded error: the raw
            // provider body is never an actionable or privacy-safe UI message.
            throw ProviderFailoverError(attempts: failures, outputStarted: false)
        }
    }

    enum ProviderFailureCategory: String, Equatable {
        case configuration, authentication, funding, rateLimited
        case timeout, transient, unavailable, invalidResponse, rejected, unexpected
    }

    struct ProviderAttemptFailure: Equatable {
        let provider: LLMProvider
        let category: ProviderFailureCategory
    }

    struct ProviderFailoverError: LocalizedError {
        let attempts: [ProviderAttemptFailure]
        let outputStarted: Bool

        var errorDescription: String? {
            let summary = attempts.prefix(8).map {
                "\($0.provider.label) (\($0.category.rawValue))"
            }.joined(separator: ", ")
            if outputStarted {
                return "The AI response was interrupted after output began, so it was not retried again. Providers attempted: \(summary)."
            }
            return "The configured AI providers could not complete this request. Providers attempted: \(summary)."
        }
    }

    /// True for errors that mean a direct provider's key is wrong/absent.
    /// Backend and orchestration-service 401s are deliberately excluded.
    static func isProviderAuthFailure(_ error: Error) -> Bool {
        if case LLMError.missingKey(let source) = error {
            return !isBackendSource(source)
        }
        if case LLMError.http(let provider, let code, _) = error,
           !isBackendSource(provider), code == 401 { return true }
        return false
    }

    /// A closed classification used both for retry policy and privacy-safe
    /// aggregate errors. Raw response bodies never leave this method.
    static func failoverCategory(for error: Error,
                                 provider: LLMProvider) -> ProviderFailureCategory? {
        if isCancellation(error) || isBackendOwned(error) { return nil }
        if case LLMError.missingKey(let source) = error {
            return sourceMatches(source, provider: provider) ? .configuration : nil
        }
        if case LLMError.badResponse(let source) = error {
            return sourceMatches(source, provider: provider) ? .invalidResponse : nil
        }
        if case LLMError.http(let source, let code, let body) = error {
            guard sourceMatches(source, provider: provider) else { return nil }
            switch code {
            case 401: return .authentication
            case 402: return .funding
            case 403: return .unavailable
            case 408: return .timeout
            case 409, 425: return .transient
            case 429: return isFundingBody(body) ? .funding : .rateLimited
            case 500...599: return .unavailable
            default: return nil
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
                 .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
                 .backgroundSessionWasDisconnected:
                return .transient
            default: return nil
            }
        }
        return nil
    }

    private static func failureCategory(for error: Error,
                                        provider: LLMProvider) -> ProviderFailureCategory {
        if let category = failoverCategory(for: error, provider: provider) { return category }
        if case LLMError.http(let source, _, _) = error,
           sourceMatches(source, provider: provider) { return .rejected }
        return .unexpected
    }

    /// Whether an error originated at this direct transport. This deliberately
    /// excludes Backend/Orchestrate errors, whose bodies describe the user's
    /// Cruxwing session or credit allowance and remain actionable.
    private static func isProviderOwned(_ error: Error,
                                        by provider: LLMProvider) -> Bool {
        switch error {
        case LLMError.http(let source, _, _),
             LLMError.badResponse(let source),
             LLMError.missingKey(let source):
            return sourceMatches(source, provider: provider)
        default:
            return error is URLError
        }
    }

    private static let backendSources: Set<String> = [
        "backend", "orchestrate", "ensemble", "brainstorm", "fact check",
    ]

    private static func isBackendOwned(_ error: Error) -> Bool {
        switch error {
        case LLMError.http(let source, _, _),
             LLMError.badResponse(let source),
             LLMError.missingKey(let source):
            return isBackendSource(source)
        default:
            return false
        }
    }

    private static func isBackendSource(_ source: String) -> Bool {
        let normalized = source.lowercased()
        return backendSources.contains(normalized) || normalized.hasPrefix("backend ")
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func sourceMatches(_ source: String, provider: LLMProvider) -> Bool {
        let normalized = source.lowercased()
        switch provider {
        case .openAI: return normalized == "openai"
        case .anthropic: return normalized == "anthropic"
        case .google: return normalized == "google" || normalized == "gemini"
        case .deepSeek: return normalized == "deepseek"
        case .qwen: return normalized == "qwen"
        case .zhipu: return normalized == "zhipu" || normalized == "zhipu glm"
        case .moonshot: return normalized == "moonshot"
        }
    }

    private static func isFundingBody(_ body: String) -> Bool {
        let value = body.lowercased()
        let markers = [
            "insufficient_quota", "billing_hard_limit_reached",
            "credit balance is too low", "insufficient credit", "insufficient funds",
            "not enough credit", "not enough funds", "quota exceeded",
            "quota has been exceeded", "exceeded your current quota",
            "out of credits", "payment required",
        ]
        return markers.contains { value.contains($0) }
    }

    /// The strongest tier-allowed model from a different configured provider,
    /// or nil when there is no direct-key alternate.
    static func authFallbackModel(excluding provider: LLMProvider, tier: Tier) -> LLMModel? {
        providerFallbackModels(excluding: provider, tier: tier, hasImages: false).first
    }

    /// At most one strongest tier-allowed model per alternate provider.
    /// Capability rank orders vendors without relying on catalog display order.
    static func providerFallbackModels(
        excluding provider: LLMProvider,
        tier: Tier,
        hasImages: Bool,
        isConfigured: (LLMProvider) -> Bool = { $0.hasDirectKey }
    ) -> [LLMModel] {
        let pool = LLMCatalog.available(for: tier)
            .filter { $0.provider != provider && isConfigured($0.provider) }
            .filter { hasImages ? $0.supportsVision : true }
        var candidates: [LLMModel] = []
        for candidateProvider in Set(pool.map(\.provider)) {
            let providerPool = pool.filter { $0.provider == candidateProvider }
            if let strongest = LLMCatalog.strongest(in: providerPool) {
                candidates.append(strongest)
            }
        }
        return candidates.sorted {
            let lhsRank = LLMCatalog.rank(of: $0)
            let rhsRank = LLMCatalog.rank(of: $1)
            return lhsRank == rhsRank
                ? $0.provider.rawValue < $1.provider.rawValue
                : lhsRank < rhsRank
        }
    }

    // MARK: - Scoring + routing

    enum Effort { case light, medium, hard }

    /// Heuristic: `user` is the full built message (transcript + context +
    /// request), so its size tracks real reasoning load; analysis-style asks
    /// and images push effort up.
    static func effort(user: String, images: [Data]) -> Effort {
        let length = user.count
        let heavyAsk = ["analy", "compare", "strateg", "risk", "negotiat", "architect",
                        "почему", "сравн", "анализ", "стратег"]
            .contains { user.lowercased().contains($0) }
        if !images.isEmpty || length > 12_000 || (heavyAsk && length > 4_000) { return .hard }
        if length > 4_000 || heavyAsk { return .medium }
        return .light
    }

    /// Best model for the effort within the tier (falls back down-catalog when
    /// a vision request needs a vision-capable pick). Only CONFIGURED providers
    /// are routed to — orchestration never picks a model that can't serve.
    static func route(_ effort: Effort, tier: Tier, hasImages: Bool,
                      within provider: LLMProvider? = nil) -> LLMModel {
        var pool = LLMCatalog.available(for: tier)
            .filter { $0.provider.isConfigured }
            .filter { hasImages ? $0.supportsVision : true }
        if let provider {
            let pinned = pool.filter { $0.provider == provider }
            if !pinned.isEmpty { pool = pinned }
        }
        guard !pool.isEmpty else { return LLMCatalog.defaultModel(for: tier) }

        switch effort {
        case .light:
            return pool.first { $0.minTier == .free } ?? pool[0]
        case .medium:
            // Strongest non-premium pick the tier allows, else its best.
            let affordable = pool.filter { $0.minTier.rank <= Tier.pro.rank }
            return LLMCatalog.strongest(in: affordable)
                ?? LLMCatalog.strongest(in: pool)
                ?? pool[pool.count - 1]
        case .hard:
            // Ranked, NOT positional. The catalog array is grouped by tier and
            // vendor, so its last element is just the last vendor declared —
            // taking it handed hard work to GLM-5.2 instead of the flagship.
            return LLMCatalog.strongest(in: pool) ?? pool[pool.count - 1]
        }
    }

    /// Council needs at least two panel providers configured with keys.
    private var councilAvailable: Bool {
        let members = Config.ensemblePanel.split(separator: ",")
            .compactMap { EnsembleGateway.Member(spec: String($0)) }
        let ready = members.filter { member in
            switch member.provider {
            case .openAI:    return !Config.openAIAPIKey.isEmpty
            case .anthropic: return !Config.anthropicAPIKey.isEmpty
            case .google:    return !Config.googleAIAPIKey.isEmpty
            default:         return !(member.provider.openAIDialect?.key().isEmpty ?? true)
            }
        }
        return ready.count >= 2
    }
}
