import Foundation

/// An expert methodology attached to a quick-prompt button. Where a
/// `QuickPrompt.prompt` says *what* to produce, its `PromptSkill` primes the
/// model with *how an expert approaches it* and the quality bar to clear —
/// exactly the role of an Agent Skill (`SKILL.md`): task-specific expertise
/// layered onto the base system prompt.
///
/// These guidances were optimized by an assessment that harvested 300+
/// MIT-licensed Agent Skills across product/sales/marketing/ops/development and
/// mapped the best methodology onto each category (see
/// `docs/mit-skills-assessment.md`). The distilled skills are also vendored in
/// full under `Resources/Skills/` (meeting-analyzer, product-discovery,
/// challenge, stress-test, capture, research-summarizer) and loaded by
/// `BundledSkillLibrary`. At runtime `BundledSkillRouter` also layers a capped
/// open-source SKILL.md body (Apache-2.0 / MIT) onto matching buttons.
///
/// References to connected-app material ("prior transcript", "linked doc",
/// "tracker state") are phrased conditionally — the model uses them only when
/// that context is present (e.g. after the Co-pilot "Research" pull). Skills are
/// bundled data keyed by the built-in prompt's `id`; custom prompts (`custom-…`)
/// have no skill and fall back to the base instructions.
struct PromptSkill: Identifiable, Equatable, Sendable {
    let id: String        // == the QuickPrompt id it augments
    let name: String      // short label, e.g. "Ведение звонка"
    let guidance: String  // appended to SystemInstructions.base when this button runs
}

enum PromptSkills {
    /// Guidance for a prompt button, or nil (base instructions only).
    static func guidance(for promptID: String) -> String? {
        byID[promptID]?.guidance
    }

    static func skill(for promptID: String) -> PromptSkill? {
        byID[promptID]
    }

    static let all: [PromptSkill] = [
        agenda, brainstorm, unresolved, whatToAsk, factCheck, rhetoric,
        answer, dispute, risks, advice, tasks, summary, logDecision,
        steelman, commitments
    ]

    private static let byID: [String: PromptSkill] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    // MARK: - The twelve skills (one per built-in button)

    static let agenda = PromptSkill(
        id: "agenda", name: "Ведение звонка",
        guidance: """
        SKILL — Ведение звонка. Maintain a live, outcome-first agenda. Give each block an
        owner, a type (decide / inform / explore), a timebox with buffer, and one exit condition —
        the decision or artifact that must land before advancing. Seed blocks from prior-meeting
        unresolved items, open commitments, and any linked agenda doc when that context is present,
        marking carry-overs explicitly. Flag time drift, one-speaker dominance, and any block
        closing with its exit unmet. Park off-goal threads to a visible owned list — never drop them
        silently. Bar: every block leaves with a named decision or next step, and no committed item
        is lost across meetings.
        """)

    static let brainstorm = PromptSkill(
        id: "brainstorm", name: "Генерация идей по дизайн-мышлению",
        guidance: """
        SKILL — Ideation. Before diverging, name the one measurable outcome and the opportunity or
        pain each idea must serve — hang ideas off opportunities, not vibes. Diverge wide, then
        converge into Quick Wins / Experiments / Bold Bets, scoring effort × impact against real team
        capacity and evidence certainty. When the room stalls, seed 3–5 ideas that fit the product's
        stage, each with a one-line implementation note. Pressure-test every Bold Bet: a one-line
        steelman plus its sharpest kill-risk. Build on parked ideas from prior context and never
        re-suggest already-committed work. Bar: each idea ships with the cheapest validating
        experiment and the single metric that must move.
        """)

    static let unresolved = PromptSkill(
        id: "unresolved", name: "Аудит незакрытых вопросов (RAID+)",
        guidance: """
        SKILL — Open-loops auditor. Extract every unresolved item and tag each {decision-pending |
        blocked-external | question-unanswered | owner-unassigned}, keeping truly blocked separate
        from parked. Score each by impact × certainty and rank — surface the highest-risk loop first,
        never a flat list. Run one latent-dependency pass to name open dependencies nobody flagged
        aloud. Every item ships owner + next step + trigger; if any is missing, flag the gap rather
        than invent it. Cross-check committed topics against prior context — a loop reopened across
        sessions escalates.
        """)

    static let whatToAsk = PromptSkill(
        id: "whattoask", name: "Сократический разбор (сначала допущения)",
        guidance: """
        SKILL — Socratic discovery. Behind every candidate question, silently extract the assumption
        it targets and map it across risk axes (desirability / viability / feasibility / usability,
        or market / execution / customer / competitive / dependency), scoring by impact ×
        uncertainty. Keep only questions aimed at high-scoring, still-unvalidated assumptions —
        skip anything already settled in prior context — and phrase each falsifiably, so the answer
        can confirm or kill its assumption. Rank the requested 'Top 3' strictly by that score. Bar:
        every question under 25 words, open not leading, aimed at a scored unknown — never a generic
        'tell me more.'
        """)

    static let factCheck = PromptSkill(
        id: "factcheck", name: "Проверка утверждений на опровержение",
        guidance: """
        SKILL — Verification. Isolate each checkable claim and restate it as one falsifiable
        statement. Verify against sources in hand — provided docs, prior transcripts, and any live
        app state in context — never from memory, and actively seek counter-evidence and base rates,
        not just confirmation. For numeric claims, test the figure against sample size and whether it
        is statistically vs practically meaningful. Return Verified / Disputed / Needs-source, each
        with a cited source location, a confidence level, and the single sharpest counter-question to
        ask. Never fabricate a citation; if nothing backs it, say Needs-source.
        """)

    static let rhetoric = PromptSkill(
        id: "rhetoric", name: "Разбор аргументации",
        guidance: """
        SKILL — Rhetoric analysis. Decompose the argument via Toulmin (claim, grounds, warrant,
        qualifier, rebuttal), then stress-test the warrant: restate it as one falsifiable proposition
        and surface the base rate, counter-example, or comparable failure that most threatens it.
        Scan for fallacies and ethos / pathos / logos imbalance, plus delivery tells — hedging,
        filler, avoidance — as credibility leaks. Anchor every call to an exact transcript quote with
        a High / Medium / Low confidence tag; never fabricate what was said. Deliver two moves:
        tighten (repair the weakest link) and counter (the sharpest rebuttal to the strongest
        version). Steelman before you strike.
        """)

    static let answer = PromptSkill(
        id: "answer", name: "Ответ для руководителя (BLUF, со ссылками)",
        guidance: """
        SKILL — Executive answer. Lead with the direct answer in one sentence (BLUF), then at most
        two supporting lines. Before answering, retrieve the fact from context — transcript, linked
        doc, ticket, or CRM when present — and tag the source inline. If the fact isn't in what you
        have, say so plainly and ask exactly one clarifying question; never invent. Strip hedging,
        filler, and executive-speak so it reads human. Bar: answer-first, sourced, zero fabrication,
        ~40 words unless more detail is asked, clarifying question only when truly ambiguous.
        """)

    static let dispute = PromptSkill(
        id: "dispute", name: "Медиация по интересам сторон",
        guidance: """
        SKILL — Mediation. First anchor facts: use the prior transcript, decision doc, or ticket in
        context to settle any 'we agreed X vs Y' before touching interests. Gate on reversibility —
        if the call is cheap to reverse, propose a time-boxed trial with a review date instead of
        full mediation. Otherwise separate positions from interests, name the hedged or avoided
        objection from what is NOT being said, and converge on one shared objective criterion. Offer
        2–3 options that meet both parties' interests, then recommend one; when interests truly
        conflict, break the tie with regret-minimization (10-minute / 10-month / 10-year), not forced
        harmony. Bar: every 'what was agreed' cites a source, and no real conflict gets papered over.
        """)

    static let risks = PromptSkill(
        id: "risks", name: "Управление рисками (допущение → severity)",
        guidance: """
        SKILL — Risk assessment. First extract the plan's core assumptions across market, execution,
        customer, competitive, financial, and dependency — each unquestioned assumption plus its
        failure path is a candidate risk; map dependencies to catch second-order risks. Score each
        likelihood × impact, sizing impact with SEV1–4 tiers rather than vague high/med/low. For any
        high-stakes number, restate it falsifiably and calibrate likelihood against base rates and
        comparable failures. Separate risks (not yet real) from issues (already real — use open
        incidents or blockers in context to draw the line, and run 5 Whys on anything that already
        fired). Every risk ships an early-warning signal, a mitigation, and a named owner — never a
        bare probability.
        """)

    static let advice = PromptSkill(
        id: "advice", name: "Стратегический совет (режим решения)",
        guidance: """
        SKILL — Strategic advisory. Infer the real objective; lead with two or three high-leverage
        moves, each with why-it-matters, an impact metric, effort, the first concrete step, and the
        one assumption it bets on. When the ask is a decision (not a task), first classify it one-way
        vs two-way door — that sets how sure you must be — then pick the least-regret option across a
        short- and long-horizon lens. Tailor tips to detectable roles; anchor the first step to an
        open ticket or prior-meeting commitment when available. Strip hedging, reflexive lists, and
        empty phrases — advise like a sharp human, not a framework. Bar: specific to this call,
        actionable now, never generic best practice.
        """)

    static let tasks = PromptSkill(
        id: "tasks", name: "Поставка и управление (захват задач + INVEST)",
        guidance: """
        SKILL — Delivery management. Log a DACI per decision. Extract action items in the speaker's
        own wording; never invent an owner or due — flag [OWNER?] / [DUE?] when unstated. Gate each
        task through INVEST, split compound items, and attach a Given/When/Then done-check. For
        continuity, reconcile against prior-meeting commitments and any tracker state in context to
        dedupe, linking back where possible. Output an owner-tagged, Slack-ready summary. Bar: every
        task atomic, owned-or-flagged, dated-or-flagged, verifiable, traced to a decision — zero
        fabricated owners/dates, zero duplicate tickets.
        """)

    static let logDecision = PromptSkill(
        id: "logdecision", name: "Запись решений",
        guidance: """
        SKILL — Запись решений. A ledger entry must survive scrutiny months later. Capture the
        decision as it was actually made: a quote-faithful statement, the stated rationale
        (including dissent — 'decided over X's objection that …'), the options genuinely raised
        (marking rejected ones), voiced risks, and the people involved. Distinguish decided (the
        group committed) from proposed (still needs sign-off). Never upgrade discussion into
        decision, never invent consensus, and prefer reporting 'no decision was made' over logging
        noise. Bar: someone absent from the call could reconstruct what was decided and why.
        """)

    static let summary = PromptSkill(
        id: "summary", name: "Протокол для руководителя (со ссылками на источник)",
        guidance: """
        SKILL — Executive minutes. Normalize the transcript to speaker + timestamp, then produce a
        3-bullet TL;DR plus Decisions / Actions / Questions / Risks / Continuity / Next agenda.
        Attach a short verbatim quote + speaker to every Decision and Risk; give each Action an owner
        and due, or tag it OPEN when unstated. Reconcile prior-meeting commitments as kept / slipped
        / reopened in the Continuity line when that context is available, and mark each Action NEW or
        TRACKED against known tracker state. Bar: every line traceable to the transcript — quote
        numbers verbatim, never invent a decision, owner, or conclusion.
        """)

    static let steelman = PromptSkill(
        id: "steelman", name: "Разбор с позиции оппонента (steelman)",
        guidance: """
        SKILL — Steelmanning. The value here is disagreement the room can trust, so the position
        must be stated at its strongest BEFORE it is attacked — if the restatement is one its
        advocates would not endorse, the critique that follows is worthless. Rank objections by
        expected damage, not by how easy they are to voice: an unlikely objection that would sink
        the plan outranks a likely one that costs a week. Anchor each in something actually said or
        provided, not in generic risk language, and pair it with the cheapest test that would settle
        it before commitment. State your own falsification condition — what would make you drop the
        objection. Manufactured dissent is the failure mode: if the position is sound, say so and
        name what makes it robust. Bar: the strongest advocate in the room would concede each
        objection is worth answering.
        """)

    static let commitments = PromptSkill(
        id: "commitments", name: "Контроль исполнения",
        guidance: """
        SKILL — Follow-through. Teams rarely fail to decide; they fail to notice a commitment
        quietly dying. Work backwards from what was promised previously, not forwards from what is
        being discussed now. For each open commitment give owner, age, last-discussed moment, and
        tracker state where it is known, then classify what THIS call does to it: resolved,
        re-committed with a new date, explicitly dropped, or — the one that matters — passed over in
        silence. Silent drops are the headline, not a footnote. Never infer progress from absence of
        mention, and mark anything unverifiable as UNCONFIRMED rather than assuming. When no prior
        context is loaded, say that plainly instead of reconstructing plausible history. Bar: every
        item traces to a prior statement, ledger entry, or tracker record — never to inference.
        """)
}
