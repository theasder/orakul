import Foundation

/// Subscription tier. Gates which LLMs the user may select ("tariff
/// architecture"). Ordered free < pro < premium via `rank`.
///
/// For now the current tier is stored locally (`Config.currentTier`); the
/// backend will become the source of truth when the managed/proxy gateway
/// lands (see `LLMGateway`).
enum Tier: String, CaseIterable, Codable, Identifiable {
    case free, pro, premium, ultra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free:    return "Free"
        case .pro:     return "Pro"
        case .premium: return "Premium"
        case .ultra:   return "Ultra"
        }
    }

    /// Higher unlocks more. A model is available when `currentTier.rank >= model.minTier.rank`.
    var rank: Int {
        switch self {
        case .free:    return 0
        case .pro:     return 1
        case .premium: return 2
        case .ultra:   return 3
        }
    }
}

/// Which vendor serves a model — selects the concrete client in `LLMRouter`.
///
/// The Chinese providers (endpoints live-probed 2026-07: all speak the OpenAI
/// chat-completions dialect) exist for the ensemble/council mode: mixing US
/// frontier and Chinese models diversifies training corpora and worldviews in
/// the panel, so the synthesis isn't a monoculture.
enum LLMProvider: String, Codable, CaseIterable {
    case openAI, anthropic, google
    case deepSeek, qwen, zhipu, moonshot
    case yandexGPT

    var label: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google:    return "Google"
        case .deepSeek:  return "DeepSeek"
        case .qwen:      return "Qwen"
        case .zhipu:     return "Zhipu GLM"
        case .moonshot:  return "Moonshot"
        case .yandexGPT: return "YandexGPT"
        }
    }

    /// Where the provider is based — lets the user pick a single-jurisdiction
    /// council (US-only or China-only) instead of the mixed default panel.
    /// Второе поле, если ключа мало. Пока только у Яндекса: один ключ
    /// обслуживает несколько каталогов, и без идентификатора запрос уходит с
    /// моделью, которой сервис не знает.
    var secondaryPrompt: String? {
        switch self {
        case .yandexGPT: return "идентификатор каталога, например b1g12345678"
        default:         return nil
        }
    }

    var needsSecondary: Bool { secondaryPrompt != nil }

    enum Jurisdiction { case us, china, russia }
    var jurisdiction: Jurisdiction {
        switch self {
        case .openAI, .anthropic, .google:         return .us
        case .deepSeek, .qwen, .zhipu, .moonshot:  return .china
        // Единственный, у кого данные остаются в России. Ради этого он здесь и
        // есть: по замерам (docs/RESEARCH-AND-PLAN.md, §3) домашние модели не
        // выигрывают у зарубежных на практических задачах, и берут их не за
        // качество, а за то, где лежат данные.
        case .yandexGPT:                           return .russia
        }
    }

    /// A provider is offered in the UI only when it can actually serve:
    /// its key is baked in — or the managed backend holds the keys.
    /// Whether this provider's key is baked into THIS build (direct client
    /// usable). Council/ensemble runs on direct clients only — the backend
    /// gateway serves single-model chat, not multi-model panels — so council
    /// availability checks this, never the backend shortcut below.
    var hasDirectKey: Bool {
        switch self {
        case .openAI:    return !Config.openAIAPIKey.isEmpty
        case .anthropic: return !Config.anthropicAPIKey.isEmpty
        case .google:    return !Config.googleAIAPIKey.isEmpty
        default:         return !(openAIDialect?.key().isEmpty ?? true)
        }
    }

    var isConfigured: Bool {
        if Config.llmViaBackend { return true }   // keys live server-side
        return hasDirectKey
    }

    /// Config for providers served through the shared OpenAI-dialect client
    /// (nil for vendors with native clients). International endpoints.
    struct Dialect {
        let endpoint: URL
        let key: () -> String
        /// Как назвать модель в запросе. По умолчанию — как в каталоге.
        var modelID: (String) -> String = { $0 }
        /// Дополнительные заголовки, если провайдер их требует.
        var headers: () -> [String: String] = { [:] }
    }

    /// Где человек берёт ключ. Живёт рядом с адресом запроса намеренно.
    ///
    /// У трёх китайских провайдеров две площадки — китайская и международная,
    /// — и это РАЗНЫЕ сервисы с независимыми аккаунтами. Ключ одной на другой
    /// даёт 401. Пока подсказка лежала во вьюхе, а адрес здесь, они разошлись:
    /// запросы шли на международные адреса, а подсказка звала на китайскую
    /// консоль. Русский разработчик получал ключ, который не мог заработать,
    /// и три провайдера из брифа выглядели сломанными; вдобавок регистрация на
    /// китайских площадках обычно требует местного телефона.
    ///
    /// Теперь обе половины одного факта стоят рядом, и тест сверяет их.
    var keyConsoleHint: String {
        switch self {
        case .deepSeek:  return "platform.deepseek.com → API keys"
        case .qwen:      return "modelstudio.console.aliyun.com → API-KEY (регион Сингапур)"
        case .zhipu:     return "z.ai → ключи API"
        case .moonshot:  return "platform.moonshot.ai → API keys"
        case .openAI:    return "platform.openai.com → API keys"
        case .anthropic: return "console.anthropic.com → API keys"
        case .google:    return "aistudio.google.com → Get API key"
        case .yandexGPT: return "console.yandex.cloud → сервисный аккаунт, API-ключ; там же идентификатор каталога"
        }
    }

    var openAIDialect: Dialect? {
        switch self {
        case .openAI, .anthropic, .google:
            return nil
        case .deepSeek:
            return Dialect(endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                           key: { Config.deepSeekAPIKey })
        case .qwen:
            return Dialect(endpoint: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                           key: { Config.dashScopeAPIKey })
        case .zhipu:
            return Dialect(endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
                           key: { Config.zhipuAPIKey })
        case .moonshot:
            return Dialect(endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
                           key: { Config.moonshotAPIKey })
        case .yandexGPT:
            // Совместимый с OpenAI вход Яндекса. Модель называется иначе:
            // `gpt://<каталог>/<модель>/latest`, и каталог свой у каждого —
            // поэтому он хранится рядом с ключом и подставляется здесь.
            // Тот же идентификатор уходит ещё и заголовком.
            return Dialect(
                endpoint: URL(string: "https://llm.api.cloud.yandex.net/v1/chat/completions")!,
                key: { Config.yandexGPTAPIKey },
                modelID: { model in
                    let folder = ProviderKeyStore.current.secondary(for: .yandexGPT) ?? ""
                    return folder.isEmpty ? model : "gpt://\(folder)/\(model)/latest"
                },
                headers: {
                    guard let folder = ProviderKeyStore.current.secondary(for: .yandexGPT),
                          !folder.isEmpty else { return [:] }
                    return ["x-folder-id": folder]
                })
        }
    }
}

/// A selectable model in the tier-gated chooser.
struct LLMModel: Identifiable, Hashable {
    /// API model identifier sent to the provider, e.g. "gpt-4o".
    let id: String
    let label: String
    let provider: LLMProvider
    /// Lowest tier that may select this model.
    let minTier: Tier
    let supportsVision: Bool

    /// Verified input context window, or nil when it has not been verified.
    ///
    /// Gates opt-in full-context mode (backlog item 12). `nil` means NOT
    /// OFFERED rather than unknown-so-try: guessing a window would sell credits
    /// for a request the provider then rejects for exceeding it. Mirrors
    /// `contextTokens` in cruxwing-api/functions/models.js, carried across in
    /// the shared contract.
    let contextTokens: Int?

    /// Immutable picker selection captured for this request. This differs from
    /// `id` for Auto/provider/council sentinels and prevents a Settings change
    /// during grounding from rerouting an already-started answer.
    let requestSelectionID: String?

    init(id: String, label: String, provider: LLMProvider, minTier: Tier,
         supportsVision: Bool, contextTokens: Int? = nil,
         requestSelectionID: String? = nil) {
        self.contextTokens = contextTokens
        self.id = id
        self.label = label
        self.provider = provider
        self.minTier = minTier
        self.supportsVision = supportsVision
        self.requestSelectionID = requestSelectionID
    }

    func snapshottingSelection(_ selectionID: String? = nil) -> LLMModel {
        LLMModel(
            id: id, label: label, provider: provider, minTier: minTier,
            supportsVision: supportsVision,
            requestSelectionID: selectionID ?? id)
    }

    func isAvailable(for tier: Tier) -> Bool { tier.rank >= minTier.rank }
}

/// The catalog of models offered across tiers. Editing this table is how you
/// shape the tariff. Keep IDs in sync with each provider's current API names.
enum LLMCatalog {
    /// The "Auto" pseudo-model: intelligent orchestration picks (and combines)
    /// real models per request — recommended default. See AutoOrchestrator.
    static let autoID = "auto"
    static let auto = LLMModel(id: autoID, label: "Auto", provider: .openAI,
                               minTier: .free, supportsVision: true)

    /// The offline fallback table. `all` reads the backend-hydrated catalog when
    /// present (M6b), else this — so a fresh install / offline launch still works.
    static let fallback: [LLMModel] = [
        // Free
        LLMModel(id: "gpt-5.4-mini",       label: "GPT-5.4 mini",   provider: .openAI,    minTier: .free,    supportsVision: true, contextTokens: 400000),
        LLMModel(id: "gemini-3.5-flash",   label: "Gemini Flash",   provider: .google,    minTier: .free,    supportsVision: true, contextTokens: 1000000),
        // Pro
        LLMModel(id: "gpt-5.4",            label: "GPT-5.4",        provider: .openAI,    minTier: .pro,     supportsVision: true, contextTokens: 400000),
        LLMModel(id: "claude-sonnet-5",    label: "Claude Sonnet",  provider: .anthropic, minTier: .pro,     supportsVision: true, contextTokens: 200000),
        LLMModel(id: "kimi-k2.6",          label: "Kimi K2.6",      provider: .moonshot,  minTier: .pro,     supportsVision: false),
        // Premium
        LLMModel(id: "gpt-5.5",            label: "GPT-5.5",        provider: .openAI,    minTier: .premium, supportsVision: true, contextTokens: 400000),
        LLMModel(id: "gpt-5.6-sol",        label: "GPT-5.6 Sol",    provider: .openAI,    minTier: .premium, supportsVision: true, contextTokens: 400000),
        LLMModel(id: "claude-opus-5",    label: "Claude Opus 5", provider: .anthropic, minTier: .premium, supportsVision: true, contextTokens: 200000),
        LLMModel(id: "gemini-3.1-pro-preview", label: "Gemini Pro", provider: .google,    minTier: .premium, supportsVision: true, contextTokens: 1000000),
        LLMModel(id: "deepseek-v4-pro",    label: "DeepSeek V4 Pro", provider: .deepSeek, minTier: .premium, supportsVision: false),
        LLMModel(id: "qwen3.7-max",        label: "Qwen 3.7 Max",   provider: .qwen,      minTier: .premium, supportsVision: false),
        LLMModel(id: "glm-5.2",            label: "GLM-5.2",        provider: .zhipu,     minTier: .premium, supportsVision: false),
        // Российский путь. Идентификаторы — те, что Яндекс принимает в
        // `gpt://<каталог>/<модель>/latest`; каталог подставляется из настроек.
        // Здесь он не нужен и не может быть: он свой у каждого пользователя.
        LLMModel(id: "yandexgpt-lite",     label: "YandexGPT Lite", provider: .yandexGPT, minTier: .free,    supportsVision: false),
        LLMModel(id: "yandexgpt",          label: "YandexGPT Pro",  provider: .yandexGPT, minTier: .free,    supportsVision: false),
    ]

    // M6b — the live catalog: the backend (GET /api/llm/models) is the single
    // source of truth for WHICH models exist + their tier/vision; `all` reads it
    // when hydrated, else the offline `fallback`. Every call site uses `all`, so
    // the whole app follows the backend without per-site changes.
    nonisolated(unsafe) private static var hydratedModels: [LLMModel]?
    static var all: [LLMModel] { hydratedModels ?? fallback }

    /// A backend catalog entry — GET /api/llm/models → `{ models: [...] }`.
    struct CatalogEntry: Decodable {
        let id: String
        let provider: String
        let minTier: String
        let supportsVision: Bool
    }

    /// Map backend entries → models. The label comes from the known static table
    /// (so the UI stays polished) or falls back to the id for a model this build
    /// doesn't recognize. An entry with an unmappable provider or tier is dropped —
    /// the client can't route it. Order (weak→strong) is preserved.
    static func models(from entries: [CatalogEntry]) -> [LLMModel] {
        entries.compactMap { e in
            guard let provider = providerID(e.provider), let tier = Tier(rawValue: e.minTier) else { return nil }
            let label = fallback.first { $0.id == e.id }?.label ?? e.id
            return LLMModel(id: e.id, label: label, provider: provider, minTier: tier, supportsVision: e.supportsVision)
        }
    }

    /// Replace the live catalog. Ignored if the mapped set is empty, so a bad or
    /// truncated response can never blank the model picker.
    static func applyHydration(_ entries: [CatalogEntry]) {
        let models = models(from: entries)
        guard !models.isEmpty else { return }
        hydratedModels = models
    }

    /// Revert to the offline fallback (also used to isolate tests).
    static func resetHydration() { hydratedModels = nil }

    /// Fetch the live catalog and hydrate. Best-effort: any failure (offline, bad
    /// response) leaves the fallback in place. Call once at launch.
    static func hydrate(baseURL: String = Config.backendBaseURL,
                        session: URLSession = BackendPinning.shared) async {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: root + "/api/llm/models") else { return }
        struct Payload: Decodable { let models: [CatalogEntry] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            applyHydration(payload.models)
        } catch {
            // Offline / malformed → keep the static fallback.
        }
    }

    private static func providerID(_ s: String) -> LLMProvider? {
        switch s.lowercased() {
        case "openai":    return .openAI
        case "anthropic": return .anthropic
        case "google":    return .google
        case "deepseek":  return .deepSeek
        case "qwen":      return .qwen
        case "zhipu":     return .zhipu
        case "moonshot":  return .moonshot
        default:          return nil
        }
    }

    static func model(id: String) -> LLMModel? { all.first { $0.id == id } }

    /// Fast, cheap models per provider — used for mechanical second passes
    /// (refine audits) where turnaround beats depth.
    private static let fastIDByProvider: [LLMProvider: String] = [
        .openAI: "gpt-5.4-mini",
        .google: "gemini-3.5-flash",
    ]

    /// The model to run audit/refine passes on: the same provider's fast tier
    /// when the catalog has one (no extra key needed), else the model itself.
    /// Auto/council pseudo-selections fall back to the cheapest fast model so an
    /// audit never fans out to a whole panel.
    static func fastAudit(for model: LLMModel,
                          managed: Bool = Config.llmViaBackend) -> LLMModel {
        let selected: LLMModel
        if managed,
           let mini = LLMCatalog.model(id: "gpt-5.4-mini") {
            selected = mini
        } else if model.id == autoID || model.id.hasPrefix("council:") {
            selected = LLMCatalog.model(id: "gpt-5.4-mini") ?? model
        } else if let fastID = fastIDByProvider[model.provider],
                  let fast = LLMCatalog.model(id: fastID) {
            selected = fast
        } else {
            selected = model
        }
        // This helper has already made the routing decision. Pin the concrete
        // result so AutoOrchestrator cannot discard it by consulting a picker
        // value changed while the background/audit task was waiting to run.
        return selected.snapshottingSelection()
    }

    /// Automatic watches must not inherit a user's flagship selection. The
    /// managed gateway always has the global mini model available; direct-key
    /// builds preserve provider affinity so a one-key setup keeps working.
    static func background(for model: LLMModel,
                           managed: Bool = Config.llmViaBackend) -> LLMModel {
        return fastAudit(for: model, managed: managed)
    }

    /// Models a tier is allowed to use.
    static func available(for tier: Tier) -> [LLMModel] { all.filter { $0.isAvailable(for: tier) } }

    /// A safe default for a tier — the first model it can use.
    static func defaultModel(for tier: Tier) -> LLMModel {
        available(for: tier).first ?? all[0]
    }

    // MARK: Two-tier selection (Provider → Version)

    /// Providers worth showing: configured AND serving at least one model the
    /// tier allows. Unconfigured providers are hidden entirely — no dead
    /// options, no key prompts.
    static func configuredProviders(for tier: Tier) -> [LLMProvider] {
        var seen: [LLMProvider] = []
        for model in available(for: tier) where model.provider.isConfigured {
            if !seen.contains(model.provider) { seen.append(model.provider) }
        }
        return seen
    }

    /// Versions of one provider the tier allows (catalog order = weak→strong).
    static func versions(of provider: LLMProvider, for tier: Tier) -> [LLMModel] {
        available(for: tier).filter { $0.provider == provider }
    }

    /// "Auto" version within a provider: the strongest stable version the tier
    /// allows (routing by request effort happens in AutoOrchestrator).
    static func autoVersion(of provider: LLMProvider, for tier: Tier) -> LLMModel? {
        // Safe positionally: WITHIN one provider the catalog really is ordered
        // weakest → strongest. Across providers it is not — see capabilityOrder.
        versions(of: provider, for: tier).last
    }

    /// Explicit "give me your best" ranking, strongest first.
    ///
    /// The catalog ARRAY is a display order — grouped by tier, then by vendor —
    /// but `route(.hard)` read it as weakest → strongest and took the last
    /// element. Across providers that is simply the last vendor declared, so a
    /// Premium user on Auto with a hard task was routed to GLM-5.2 rather than
    /// the strongest model available to them. Ranking capability is a product
    /// judgement and belongs in one visible list, not in array position.
    static let capabilityOrder: [String] = [
        "gpt-5.6-sol",
        "claude-opus-5",
        "gpt-5.5",
        "gemini-3.1-pro-preview",
        "deepseek-v4-pro",
        "qwen3.7-max",
        "glm-5.2",
        "gpt-5.4",
        "claude-sonnet-5",
        "kimi-k2.6",
        // Российские модели стоят здесь не по бенчмарку, а по сравнению на
        // практических задачах: в замере 2026-07 (docs/RESEARCH-AND-PLAN.md,
        // §3) GigaChat и YandexGPT не выиграли ни одной из двенадцати, хотя на
        // MERA GigaChat обходит GPT-5.2. Ставить их выше по одной табличной
        // победе значило бы повторить ошибку, из-за которой этот список вообще
        // появился. Выбирают их за то, где остаются данные, а не за силу.
        "gemini-3.5-flash",
        "gpt-5.4-mini",
        "yandexgpt",
        "yandexgpt-lite",
    ]

    /// The most capable model in `pool`. Unranked models (a newly added id that
    /// nobody has placed yet) sort last rather than silently winning.
    static func strongest(in pool: [LLMModel]) -> LLMModel? {
        pool.min { a, b in rank(of: a) < rank(of: b) }
    }

    static func rank(of model: LLMModel) -> Int {
        capabilityOrder.firstIndex(of: model.id) ?? Int.max
    }

    // MARK: Single-jurisdiction councils (US-only / China-only ensembles)

    static let councilUS = "council:us"
    static let councilCN = "council:cn"

    /// The panel for a jurisdiction's council: the strongest tier-allowed model
    /// of each CONFIGURED provider based there. Built from the live catalog so
    /// the model ids are always valid and only configured providers take part.
    static func councilPanel(_ jurisdiction: LLMProvider.Jurisdiction, for tier: Tier) -> [EnsembleGateway.Member] {
        // hasDirectKey, not isConfigured: in a keyless backend-gateway build the
        // picker must not offer a Council that EnsembleGateway cannot serve
        // (launch loop M3e — it was guaranteed-broken in the dist config).
        configuredProviders(for: tier)
            .filter { $0.jurisdiction == jurisdiction && $0.hasDirectKey }
            .compactMap { provider in
                autoVersion(of: provider, for: tier)
                    .map { EnsembleGateway.Member(provider: provider, modelID: $0.id) }
            }
    }

    /// Offer a council only when it has a real panel (≥2 configured providers).
    /// Both jurisdictions (US and China) are offered symmetrically once enough
    /// of their providers have direct keys (product decision revised 2026-07,
    /// see launch/DECISIONS.md D11 — the earlier China-off decision is reversed).
    static func councilAvailable(_ jurisdiction: LLMProvider.Jurisdiction, for tier: Tier) -> Bool {
        return councilPanel(jurisdiction, for: tier).count >= 2
    }
}
