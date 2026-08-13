import Foundation

struct QuickPrompt: Identifiable, Equatable, Codable {
    let id: String
    let icon: String
    let title: String
    let tooltip: String
    let prompt: String

    /// Build a user-defined prompt. Tooltip is a snippet of the body so hover
    /// previews what it does.
    static func custom(id: String = "custom-" + UUID().uuidString,
                       icon: String, title: String, prompt: String) -> QuickPrompt {
        QuickPrompt(
            id: id,
            icon: icon.isEmpty ? "✨" : icon,
            title: title.isEmpty ? "Без названия" : title,
            tooltip: String(prompt.prefix(80)),
            prompt: prompt
        )
    }

    var isCustom: Bool { id.hasPrefix("custom-") }
}

enum QuickPrompts {
    // Ported 1:1 from the Chrome extension (content.js:149).
    static let all: [QuickPrompt] = [
        .init(id: "agenda",
              icon: "🗓️",
              title: "Текущая повестка",
              tooltip: "Повестка по времени: кто ведёт и что откладываем",
              prompt: "From the call name, provided context, live background, and the first minutes of this transcript, infer the meeting type and goals. Propose a time-boxed agenda with: sections, owner per section, desired outcome (the exit condition for the block), and a 'parking lot'. Mark carry-overs from prior meetings explicitly when background shows them. If duration is unclear, assume 45 min. Return in markdown with headings."),
        .init(id: "brainstorm",
              icon: "💡",
              title: "Мозговой штурм",
              tooltip: "Собрать идеи с обоснованием и следующими шагами",
              prompt: "Analyze the transcript so far and the past context to infer our goals and constraints. Generate 5–7 ideas grouped as Quick Wins / Experiments / Bold Bets. For each: one-line rationale, expected impact metric, and the very next step. Avoid duplicates of past ideas. Add transcript timestamp(s) that inspired each idea if available."),
        .init(id: "unresolved",
              icon: "❓",
              title: "Нерешённые вопросы",
              tooltip: "Что осталось открытым: кто отвечает и к какому сроку",
              prompt: "Identify topics that remain open, were parked, or need follow-up. If the provided context or prior-meeting background lists committed topics that were never discussed, surface those explicitly too. Return a ranked list (highest-risk loop first): Issue • status {decision-pending | blocked-external | question-unanswered | owner-unassigned} • owner (or 'TBD') • next step • target date • related timestamp(s). End with a suggested mini-agenda for a follow-up meeting."),
        .init(id: "whattoask",
              icon: "🎯",
              title: "Что спросить",
              tooltip: "Что не обсудили или обошли — с готовыми вопросами",
              prompt: "Act as a sharp meeting coach. Cross-reference the live transcript against the provided context (files + notes, incl. agenda, briefs, prior decisions, stakeholders, metrics). Produce ready-to-ask questions I can voice in the next 1–3 minutes, grouped into exactly four buckets:\n• Clarify — vague, ambiguous, or jargon-heavy statements that need disambiguation. Quote the moment (speaker + timestamp if available) and give a one-sentence clarifying question.\n• Probe deeper — topics that were raised but only skimmed (1–2 lines). Name the topic, say why it matters, and give a probing follow-up question.\n• Gap fill — important topics from the context (agenda items, stakeholders, risks, dependencies, metrics, commitments) that have NOT come up yet in the transcript. Name the topic, suggested phrasing, and why it should be raised now.\n• Pressure test — confident claims, numbers, dates, or commitments asserted without evidence. Quote the claim + timestamp, state what would confirm or falsify it, and propose a polite challenge question.\n\nFor every question:\n- keep it under 25 words\n- open-ended when the goal is discovery, closed (yes/no) when a decision is needed\n- add a short 'Why:' tag (≤ 8 words) explaining the value of asking it\n- cite the transcript timestamp OR the source file name from context whenever possible\n- phrase it neutrally so it doesn't sound accusatory\n\nLead the answer with a single line: 'Top 3 to ask next →' with the three highest-leverage questions, then the four grouped sections. If a bucket has nothing worth raising, write '— nothing notable —' for that bucket. Prefer 3–5 sharp questions per bucket over long lists. Return markdown with headings."),
        .init(id: "factcheck",
              icon: "🔎",
              title: "Проверка фактов",
              tooltip: "Проверить прозвучавшие факты и отметить, что подтвердилось",
              prompt: "Extract factual claims or stats from the latest portion of the transcript. For each claim: quote/summary • speaker/timestamp • status = Verified / Disputed / Needs external source • brief explanation • source or internal reference if available. If no reliable source is accessible, mark 'Needs external verification' and suggest what evidence is required."),
        .init(id: "rhetoric",
              icon: "🎭",
              title: "Риторические приёмы",
              tooltip: "Найти подмены, давление и вопросы с подвохом",
              prompt: "Analyze the latest portion of the transcript for persuasion quality. Identify: logical fallacies (name them), emotional appeals (pathos), authority/credibility appeals (ethos), reasoning/structure (logos), and unsupported or loaded framing. For each: quote the moment (speaker/timestamp if available), name the technique, and note whether it strengthens or weakens the argument. Then give 2–3 concrete ways to respond or tighten the reasoning. Neutral tone; no partisan or ideological labels. Return markdown."),
        .init(id: "answer",
              icon: "🙋",
              title: "Ответ на вопрос",
              tooltip: "Ответить на последний вопрос, заданный вам",
              prompt: "Find the most recent question likely directed at me (by name, role, or context). Lead with the direct answer in one sentence, then at most two supporting lines (quotes + timestamps when they help), then the question you answered in parentheses. Use only meeting context and provided background. If the answer hinges on missing info, say so plainly and end with exactly one clarifying question."),
        .init(id: "dispute",
              icon: "🤝",
              title: "Разрешить спор",
              tooltip: "В чём спор и какие есть варианты решения",
              prompt: "Detect the current disagreement using the transcript. First anchor the facts: use provided context and background to settle any dispute about what was previously agreed. Then produce a recommended option with rationale and 2–3 decision options (A/B/C) with pros/cons, plus a neutral summary of Side A / Side B, key trade-offs, and the minimal data needed if a quick test beats deciding now. Cite relevant timestamps."),
        .init(id: "risks",
              icon: "⚠️",
              title: "Оценка рисков",
              tooltip: "Список рисков: вероятность и последствия",
              prompt: "Scan the discussion and provided context for explicit or implied risks. Separate issues (already happening — list first) from risks (not yet real). Return a register as a bulleted list, one item per entry: Axis (market/execution/customer/competitive/financial/dependency) • Description • Likelihood (calibrated %, note the base rate or comparable it rests on) • Impact (SEV1 critical → SEV4 minor) • Exposure note • Early warning signal • Mitigation • Owner • Next step • Timestamp(s). Avoid table formatting or long runs of '-' characters."),
        .init(id: "advice",
              icon: "🧭",
              title: "Дать совет",
              tooltip: "Что делать дальше — с оглядкой на вашу роль",
              prompt: "As a domain expert, infer the primary objective from this call and past context. Provide Top 3 recommendations with: why it matters, expected impact metric, effort (Low/Med/High), and the first concrete step. If participant roles are detectable, add role-specific tips (PM/Eng/Design/etc.). Keep it actionable."),
        .init(id: "tasks",
              icon: "📋",
              title: "Задачи по итогам",
              tooltip: "Раздать задачи и собрать список действий",
              prompt: "From decisions and requests in the transcript, produce:\nA) DACI per decision (Driver, Approver, Contributors, Informed) and\nB) Action list: Task • Owner (stated, else [OWNER?]) • Due (stated, else [DUE?]; append '(suggest: …)' only when a date is clearly implied) • Done-check (Given/When/Then) • Dependency • Related decision/timestamp.\nMark tasks already present in tracker background as TRACKED instead of duplicating them. Finish with a Slack/Teams-ready summary (one paragraph)."),
        .init(id: "logdecision",
              icon: "📌",
              title: "Записать решение",
              tooltip: "Записать принятое решение в журнал",
              prompt: "Capture the most recent concrete decision made on this call — quote-faithful statement, rationale (including voiced dissent), options considered, risks, stakeholders — and file it into the Decision Ledger."),
        .init(id: "summary",
              icon: "📝",
              title: "Резюме звонка",
              tooltip: "Разложить звонок по пунктам",
              prompt: "Summarize this meeting so far in this structure: TL;DR (3 bullets) • Decisions (each with a short verbatim quote + speaker) • Action Items (owner & due, or OPEN when unstated) • Open Questions • Risks • Continuity (prior commitments kept / slipped / reopened — only when prior-meeting background is provided) • Parking Lot • Next Meeting (proposed agenda & date). Add speaker labels and timestamps where possible. Keep it concise and scannable."),
        .init(id: "steelman",
              icon: "⚔️",
              title: "Аргументы против",
              tooltip: "Сильнейший довод против того, о чём договорились",
              prompt: "Identify what this call has just converged on — the decision, plan, or assumption the room now treats as settled. Then argue the STRONGEST honest case against it, as its most capable opponent would: state the position fairly first (no strawman), then give the 3–5 best objections ranked by how much damage each does if true. For each: the concrete failure it predicts, the evidence from this transcript or context that supports it, and the cheapest test that would settle it before committing. End with the single condition under which you would abandon the objection. Do not hedge, and do not manufacture disagreement if the position is genuinely sound — say so and name what makes it robust."),
        .init(id: "commitments",
              icon: "🔗",
              title: "Договорённости",
              tooltip: "Что обещали раньше и закрыл ли это звонок",
              prompt: "Using prior-meeting background, the decision ledger, and connected trackers when present, list the commitments made BEFORE this call that are still outstanding. For each: what was promised, who owns it, when it was due or last discussed, current state from the tracker if known, and whether anything said on THIS call resolves, re-commits, or silently drops it. Flag any item being dropped without acknowledgement — that is the failure this exists to catch. Mark items you cannot verify as UNCONFIRMED rather than assuming progress. If no prior context is available, say so plainly instead of inventing history."),
        // Cross-meeting recall has been reachable since F1 shipped, but only if
        // the user guessed the phrasing the intent gate matches. A capability
        // nobody knows about is barely better than one that does not work, so
        // the chip says it out loud. Its text deliberately opens with "what did
        // we decide", which is exactly what DecisionRecallContext looks for —
        // pressing the button loads the prior-meeting record into the request.
        .init(id: "recall",
              icon: "🧠",
              title: "Что мы решили",
              tooltip: "Ответ из прошлых звонков — с цитатой и названием",
              prompt: "What did we decide about the subject of this conversation in earlier meetings? Answer FROM the prior-meeting record supplied above: name the meeting and its date, quote the words the decision was recorded in rather than paraphrasing them, and say what has changed since if the record shows it. If the record does not cover it, say plainly that nothing was found and do not reconstruct a decision from the live transcript — a confidently invented history is how the same argument gets had a third time.")
    ]
}
