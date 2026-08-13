import Foundation

/// The domain of a call. Each theme carries a *skill pack* — a bundle of the
/// expertise that matters for that kind of meeting — which is layered onto the
/// base instructions (and any per-button `PromptSkill`) for every AI action in
/// that call. A sales call and a hiring interview should draw on different
/// experts; the theme is how that happens.
///
/// The active theme is inferred cheaply from the call goal + transcript (no
/// extra model call), or pinned by the user via `AppState.callThemeOverride`.
enum CallTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case sales, hiring, product, engineering, fundraising
    case customerSuccess, leadership, legal, strategy, standup
    case general

    var id: String { rawValue }

    /// Menu label for a future theme picker.
    var label: String {
        switch self {
        case .sales: return "Продажи / сделка"
        case .hiring: return "Найм / собеседование"
        case .product: return "Продукт / исследование"
        case .engineering: return "Технический разбор"
        case .fundraising: return "Инвестиции / инвестор"
        case .customerSuccess: return "Работа с клиентом"
        case .leadership: return "1:1 / coaching"
        case .legal: return "Юридическое / договор"
        case .strategy: return "Стратегия / планирование"
        case .standup: return "Планёрка / статус"
        case .general: return "Общий"
        }
    }

    var symbol: String {
        switch self {
        case .sales: return "dollarsign.circle"
        case .hiring: return "person.badge.plus"
        case .product: return "shippingbox"
        case .engineering: return "gearshape.2"
        case .fundraising: return "chart.line.uptrend.xyaxis"
        case .customerSuccess: return "heart.text.square"
        case .leadership: return "person.2"
        case .legal: return "checkmark.seal"
        case .strategy: return "map"
        case .standup: return "checklist.checked"
        case .general: return "bubble.left.and.bubble.right"
        }
    }

    /// The skill pack layered onto every AI action for a call of this theme.
    /// nil for `.general` (base instructions only).
    var guidance: String? {
        switch self {
        case .general:
            return nil
        case .sales:
            return """
            SKILL PACK — Sales & deal execution. Frame everything around advancing the deal.
            Qualify with MEDDIC (Metrics, Economic buyer, Decision criteria & process, Identify
            pain, Champion); surface and disarm objections early; convert interest into a
            concrete, dated next step and a mutual action plan. Watch for pricing, procurement,
            and competitor signals, and for single-threading. Bar: every output moves the deal
            toward a committed next step.
            """
        case .hiring:
            return """
            SKILL PACK — Hiring & interviewing. Run a structured, competency-based interview.
            Separate signal from noise; tie every judgment to observed evidence, not vibes; probe
            with behavioral follow-ups (situation → action → result); guard against halo and
            affinity bias. Bar: assessments are evidence-linked and role-relevant, and the next
            question fills the biggest evidence gap.
            """
        case .product:
            return """
            SKILL PACK — Product & discovery. Reason in jobs-to-be-done and opportunity → solution.
            Separate problems from solutions; validate the underlying need before scoping;
            prioritize with a clear rubric (impact vs. effort / RICE); name assumptions and the
            cheapest test. Bar: decisions trace back to a real user problem and a way to measure
            success.
            """
        case .engineering:
            return """
            SKILL PACK — Технический разбор. Evaluate designs on trade-offs, not preferences.
            Weigh scope, complexity, reliability, and cost; surface dependencies and failure
            modes; separate must-fix from nice-to-have; timebox spikes for unknowns. Bar:
            recommendations name the trade-off accepted and the riskiest assumption to validate.
            """
        case .fundraising:
            return """
            SKILL PACK — Fundraising & investor. Tell a metrics-backed narrative: problem,
            why-now, traction, market, and the ask. Lead with the numbers that matter (growth,
            retention, unit economics); pre-empt the obvious objections; keep the story tight and
            defensible. Bar: every claim is backed by a metric or a credible proof point.
            """
        case .customerSuccess:
            return """
            SKILL PACK — Работа с клиентом & renewal. Track value realization and account health.
            Surface adoption, sentiment, and risk signals; connect usage to the customer's
            outcomes; spot expansion and churn early; drive to a clear success plan. Bar: outputs
            tie the conversation to renewal/expansion risk and a next step that protects the
            account.
            """
        case .leadership:
            return """
            SKILL PACK — 1:1 & coaching. Use a GROW frame (Goal, Reality, Options, Will). Listen
            for growth, blockers, and morale; ask more than you tell; convert insight into an
            owned commitment; handle sensitive topics with candor and care. Bar: the person leaves
            with a clear next step they chose.
            """
        case .legal:
            return """
            SKILL PACK — Legal & contract review. Read for obligations, risk, and ambiguity.
            Identify who must do what by when; flag one-sided terms, undefined language, and
            liability/IP exposure; separate deal-breakers from negotiable redlines. This is
            analysis, not legal advice. Bar: each flag names the risk, the clause, and a suggested
            redline.
            """
        case .strategy:
            return """
            SKILL PACK — Strategy & planning. Think in objectives, trade-offs, and second-order
            effects. Separate goals from tactics; make the key bet and its assumptions explicit;
            consider what could go wrong and the counter-move. Bar: recommendations connect to the
            objective and name what you're deliberately NOT doing.
            """
        case .standup:
            return """
            SKILL PACK — Standup & status. Optimize for blockers and commitments. Separate
            progress from plan; surface each blocker with an owner and an unblock path; keep it
            terse. Bar: every blocker has an owner and a next step — no status theater.
            """
        }
    }

    /// Keywords that signal this theme (matched case-insensitively).
    private var keywords: [String] {
        switch self {
        case .general: return []
        case .sales:
            return ["deal", "pricing", "price", "discount", "prospect", "demo", "quota", "close",
                    "contract", "procurement", "renewal", "upsell", "pipeline", "budget", "buyer", "proposal",
                    "сделк", "цен", "скидк", "клиент", "продаж", "контракт", "закупк", "продлен", "бюджет"]
        case .hiring:
            return ["candidate", "interview", "hire", "hiring", "resume", "cv", "competency",
                    "onboarding", "offer", "recruiter", "screening", "role fit",
                    "кандидат", "интервью", "найм", "резюме", "компетенц", "онбординг", "рекрутер"]
        case .product:
            return ["user", "feature", "roadmap", "backlog", "mvp", "launch", "retention",
                    "activation", "churn", "persona", "usability", "requirement", "adoption", "ux",
                    "пользовател", "функци", "дорожн", "бэклог", "запуск", "удержан",
                    "активац", "персон", "требован", "продукт"]
        case .engineering:
            return ["architecture", "api", "database", "latency", "scaling", "deploy", "incident",
                    "bug", "refactor", "migration", "infra", "rollout", "tech debt", "sprint",
                    "архитектур", "баз данных", "задержк", "масштаб", "депло", "инцидент",
                    "баг", "рефактор", "миграц", "инфраструктур", "техдолг", "спринт"]
        case .fundraising:
            return ["investor", "raise", "round", "valuation", "cap table", "runway", "arr", "mrr",
                    "traction", "term sheet", "seed", "series", "pitch", "dilution",
                    "инвестор", "раунд", "оценк", "каптейбл", "взлетн", "выручк", "трекшн", "питч"]
        case .customerSuccess:
            return ["renewal", "churn", "adoption", "onboarding", "health", "escalation",
                    "success plan", "qbr", "account", "csat", "nps", "satisfaction",
                    "продлен", "отток", "внедрен", "онбординг", "эскалац", "аккаунт", "удовлетвор"]
        case .leadership:
            return ["1:1", "one-on-one", "feedback", "growth", "career", "promotion", "morale",
                    "coaching", "development", "check-in", "wellbeing", "performance review",
                    "обратн", "рост", "карьер", "повышен", "морал", "коучинг", "развит", "эффективност"]
        case .legal:
            return ["contract", "clause", "liability", "indemnity", "nda", "terms", "agreement",
                    "compliance", "gdpr", "warranty", "sla", "breach", "jurisdiction", "redline",
                    "договор", "пункт", "ответствен", "услов", "соглашен", "комплаенс",
                    "гарант", "нарушен", "юрисдикц"]
        case .strategy:
            return ["strategy", "okr", "objective", "roadmap", "planning", "quarter", "priorities",
                    "vision", "tradeoff", "allocation", "initiative", "north star",
                    "стратег", "цель", "дорожн", "планирован", "квартал", "приоритет",
                    "виден", "компромисс", "инициатив"]
        case .standup:
            return ["standup", "stand-up", "blocker", "yesterday", "today", "status update",
                    "sprint", "ticket", "in progress", "daily",
                    "стендап", "блокер", "вчера", "сегодня", "статус", "спринт", "тикет", "в работе"]
        }
    }

    /// The theme actually applied: an explicit override wins; otherwise infer.
    static func resolve(override: CallTheme?, goal: String, transcript: String) -> CallTheme {
        override ?? infer(goal: goal, transcript: transcript)
    }

    /// Cheap keyword inference from the goal (weighted) + the recent transcript.
    /// Falls back to `.general` unless a theme clears a small confidence floor.
    static func infer(goal: String, transcript: String) -> CallTheme {
        let haystack = (goal + " " + goal + " " + String(transcript.suffix(4000))).lowercased()
        guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty else { return .general }

        var best: (theme: CallTheme, score: Int) = (.general, 0)
        for theme in CallTheme.allCases where theme != .general {
            let score = theme.keywords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            if score > best.score { best = (theme, score) }
        }
        // Require at least two distinct signals so a stray word can't mislabel a call.
        return best.score >= 2 ? best.theme : .general
    }
}
