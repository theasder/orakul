import Foundation

/// A bundled Agent Skill: distilled guidance that shapes how the model turns a
/// live-call transcript into a specific work artifact (a recap deck, minutes, an
/// action-item sheet).
///
/// This is the native, offline-friendly stand-in for a remote skills registry.
/// The `claude-skills-mcp` bridge that once served skills over MCP is deprecated
/// (skills are now first-class in every major agent), and skills are *data*, not
/// a service — a `SKILL.md` is guidance text plus an output contract. So they
/// ship inside the app: nothing is fetched or spawned mid-call, and the feature
/// works with no network beyond the model call itself (fits the "private by
/// default" posture).
///
/// Adding a skill = adding a `MeetingSkill` value. `SkillLibrary` is deliberately
/// a plain source so a future `SkillSource` — bundled `anthropics/skills`
/// SKILL.md files, or a live registry — can populate it without touching callers.
struct MeetingSkill: Identifiable, Equatable, Sendable {
    let id: String            // stable key, e.g. "recap-deck"
    let title: String         // menu label, e.g. "Recap deck"
    let subtitle: String      // one-line description for the row
    let symbol: String        // SF Symbol
    let kind: Kind
    /// The skill body: how to structure the artifact + the exact JSON contract
    /// the model must return. Used verbatim as the system prompt.
    let guidance: String

    /// Which structured artifact this skill produces (drives decoding + render).
    enum Kind: String, Sendable, CaseIterable { case deck, minutes, sheet }
}

/// The bundled skill set. Ordered as they should appear in the in-call menu.
enum SkillLibrary {
    static let all: [MeetingSkill] = [recapDeck, minutes, actionItemSheet]

    static func skill(_ kind: MeetingSkill.Kind) -> MeetingSkill {
        // Safe: every Kind has exactly one bundled skill.
        all.first { $0.kind == kind }!
    }

    // MARK: - Recap deck

    static let recapDeck = MeetingSkill(
        id: "recap-deck",
        title: "Recap deck",
        subtitle: "Turn the call into a shareable slide outline",
        symbol: "rectangle.on.rectangle.angled",
        kind: .deck,
        guidance: """
        You convert a live meeting transcript into a concise, shareable recap deck.
        Adapt the presentation to what was actually discussed — never invent content.

        Structure:
        - Open with a title slide (the meeting's subject) and a one-line subtitle.
        - 4–7 body slides, each a single idea: context, key decisions, open
          questions, risks, next steps. Merge thin topics; drop filler.
        - Each slide heading is <= 8 words. 2–5 bullets per slide, each a tight,
          concrete phrase (not a full sentence). Add short speaker notes only when
          they add signal.
        - If a stated goal is provided, bias slide selection toward what advances it.

        Return ONLY minified JSON, no prose, no code fences:
        {"title":"<meeting subject>","subtitle":"<one line>","slides":[{"heading":"<=8 words","bullets":["...","..."],"notes":"optional speaker notes"}]}
        """
    )

    // MARK: - Minutes

    static let minutes = MeetingSkill(
        id: "minutes",
        title: "Minutes",
        subtitle: "Formal minutes: decisions, discussion, actions",
        symbol: "doc.text",
        kind: .minutes,
        guidance: """
        You write formal, faithful meeting minutes from a live transcript. Record
        only what was said; do not editorialize or invent attendees or dates.

        Capture:
        - A short title and, if inferable from the transcript, the date.
        - Attendees actually named in the transcript (else an empty list).
        - A 2–3 sentence executive summary.
        - Decisions made (each a single, unambiguous statement).
        - Discussion grouped by topic, each with the salient points.
        - Action items with an owner and due date when stated (else null).
        - Next steps / follow-ups.

        Return ONLY minified JSON, no prose, no code fences:
        {"title":"...","date":"YYYY-MM-DD or null","attendees":["..."],"summary":"...","decisions":["..."],"discussion":[{"topic":"...","points":["..."]}],"actionItems":[{"task":"...","owner":"name or null","due":"date or null"}],"nextSteps":["..."]}
        """
    )

    // MARK: - Action-item sheet

    static let actionItemSheet = MeetingSkill(
        id: "action-item-sheet",
        title: "Action-item sheet",
        subtitle: "Extract a tracker of tasks, owners, and due dates",
        symbol: "tablecells",
        kind: .sheet,
        guidance: """
        You extract a clean action-item tracker from a live meeting transcript.
        Include only commitments that were genuinely made — a task someone owns or
        agreed to do. Ignore hypotheticals and musings.

        For each item capture: the task (imperative, concrete), the owner (the
        person responsible, or null if unassigned), a due date if stated (else
        null), a priority inferred from urgency in the conversation (high|medium|
        low), and status (default "open"). Deduplicate near-identical tasks.

        Return ONLY minified JSON, no prose, no code fences:
        {"columns":["Task","Owner","Due","Priority","Status"],"rows":[{"task":"...","owner":"name or null","due":"date or null","priority":"high|medium|low","status":"open"}]}
        """
    )
}
