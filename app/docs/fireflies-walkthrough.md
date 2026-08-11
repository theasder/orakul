# Fireflies paid-tier walkthrough

Backlog item 15. Written 2026-08-09 from a live trial account
(`app.fireflies.ai`, "7 days left in your AI credits trial" — so this is the
paid feature set, metered by AI credits rather than by seat).

Screenshots in `docs/fireflies-walkthrough/`. All were taken on
`ACCENT-BENCH-*` uploads, which are public RIPE conference recordings, so
nothing here exposes a real customer call.

---

## The headline

**Fireflies is no longer competing to record your meetings well. It is
competing to not need you in them.**

`Voice Agents` is a top-level nav item marked NEW: *"Voice Agents handle your
calls, ask the right questions, and deliver clear insights."* It ships with
voice cloning ("make your agent sound exactly like you in 30 seconds") and seven
prepared roles:

Screening Interview · Discovery Call · Progress Check-In · User Testimonial ·
Performance Review · User Research · Customer Support

Every one of those is a meeting a human currently attends. This is not a
note-taker feature; it is a different product wearing the same navigation.

Read alongside their MCP surface — `create_soundbite`, `list_channels`,
`get_rule_executions`, `share_meeting`, `revoke_meeting_access`,
`update_meeting_privacy`, `get_usergroups`, `get_user_contacts` — the strategy
resolves cleanly: **a governed, searchable archive of everything the company
said, with automation on top, and now agents that generate the material too.**

Cruxwing's bet is the opposite end of the same call: value *during* it. That
remains defensible. This document is about what they have learned that we can
use, not about matching them.

---

## Navigation model

A single left rail, icon-only when collapsed, labelled when expanded. Twelve
destinations, in this order:

| Route | Label | Note |
|---|---|---|
| `/` | Home | |
| `/ask-fred` | AskFred | **⌘J** — a global shortcut to the assistant |
| `/notebook/mine-shared` | Meetings | |
| `/status` | Meeting Status | pipeline health, separate from the meetings list |
| `/upload` | Uploads | |
| `/integrations` | Integrations | |
| `/analytics` | Analytics | |
| `/agents` | Voice Agents | NEW |
| `/skills` | AI Skills | |
| `/settings/team/members-and-groups` | Team | |
| `/upgrade` | Upgrade | |
| `/settings/meeting-recording` | Settings | |

Two things stand out.

**AI automation is navigation, not settings.** `AI Skills` and `Voice Agents`
are peers of `Meetings`. In Cruxwing the equivalent capability (quick prompts)
lives inside the composer, and custom prompts are a Settings concern. Their
placement says these are destinations you visit and manage, not controls you
reach for mid-task.

**The assistant is both a panel and a place.** `AskFred` is a persistent
right-hand pane on every meeting AND its own route with a keyboard shortcut. The
panel is scoped — on the meetings list it carries a `# Hosted by me` chip, so
the assistant answers across a *filtered set of meetings*, not just the open one.

The meetings list itself has a channels sidebar (`Create channels to organize
your conversations`) and segments: `Hosted by me` / `Shared with me`, plus
`All Meetings` and `Voice Agent Meetings`.

---

## Meeting detail layout

Two columns under a breadcrumb (`#All Meetings / <title>`).

**Left column** — tabbed `Notes` | `AI Skills · 0` (a live count of skill
outputs). Under Notes: title, owner, date, language, then two controls sitting
directly above the summary —

- `General Summary ▾` — the summary *template* is swappable
- `Refine Summary` — opens `Condense` / `Elaborate` / a free-text
  "Make the summary ___"

**Right column** — tabbed `AskFred` | `Transcript`. The AI pane is the default;
the transcript is secondary. On open it shows three **auto-generated questions
specific to this meeting** ("How do regulatory issues affect deployment?",
"What future protocols may emerge for satellites?", "What are Starlink's primary
challenges?"). The composer reads *"Ask anything. Type / to run AI Skills."*

**Chrome** — a media scrubber pinned to the bottom (speed, ±skip, download), a
narrow icon rail on the far left (search, waveform, comments, bookmarks), and top
right: `Share`, a copy-link split button, `1 View` viewer analytics, and
thumbs-up / thumbs-down **on the summary itself**.

---

## The three interactions they have clearly iterated on

**1. The summary is a document you argue with, not an output you receive.**
Template selector, refine-with-instruction, and explicit 👍/👎 all sit within one
control cluster. The coach mark — *"Want your summaries shorter, clearer, or more
detailed?"* — is aimed squarely at the complaint every summarising product gets.

**2. Skills are recommended per meeting, then run on demand.**
On a technical talk the panel offered `Meeting Metrics`, `Key Ideas`, and
`Technical issue tracker` — the third is content-specific, so recommendation is
driven by what the meeting is about. Each carries a run count (51.5k / 60.5k /
6.1k) and a `Run` button, with `200+ AI Skills →` and the honest footnote
`Consumes AI credits`.

**3. Skills are a marketplace with a persistence model.**
`Discover` / `Active Skills` / `Feed`, a `Create Skill` button, and per-skill
`Enable` / `Try Skill` / `Edit` / `Copy Link`. Crucially the list rows are
**toggles**, not buttons: an enabled skill runs on *future* meetings
automatically, and its output lands in the `Feed` and optionally in Slack.
Ranking is by run count, and the numbers are enormous — `Popular Topics` shows
174M, `Sales Call` 315k, `1:1` 301k, `BANT` 254k.

---

## They do X, we do Y

**1. Prompts — marketplace vs fixed list.**
*They:* 200+ skills, authored by Fireflies and by users, shareable by link,
ranked by run count, recommended per meeting.
*We:* eight built-in quick prompts plus user-defined customs, no sharing, no
ranking, no per-meeting recommendation.
*Worth taking:* recommendation. `QuickPromptResolver` already picks a prompt from
context; surfacing *why* a prompt is offered for this call is a small change with
a large legibility gain. The marketplace is not worth taking — it is the shallow
tail item 14 warns against.

**2. Prompts — one-shot vs standing.**
*They:* enabling a skill makes it run on every future matching meeting; output
accumulates in a Feed.
*We:* every prompt is a manual, one-shot action.
*Worth taking:* the standing-instruction idea, narrowly. "Always run the risk
register on customer calls" is a real want. It needs a spend ceiling — theirs is
solved by AI credits, ours by the compute-credit budget already in place.

**3. Summary — fixed output vs revisable artefact.**
*They:* swappable template, `Condense`/`Elaborate`/free-text refine, 👍/👎.
*We:* answer styles (item 7) adjust delivery at generation time; there is no way
to refine an answer already on screen without re-running the prompt.
*Worth taking:* a refine control on a delivered answer. We deliberately rejected
a rewrite pass for *styles* because a second pass doubles cost and can break a
structured contract — but a user-invoked refine is different: they asked, they
pay, and they can see the result.

**4. Assistant scope — one call vs a filtered set.**
*They:* AskFred answers across `# Hosted by me`, and the scope chip is editable.
*We:* the assistant is bound to the current call plus attached context.
*Worth taking:* eventually. Cross-call Q&A is squarely their archive game, but
"what did we decide about X across the last five calls" is a question our users
have too. It presumes durable local history we do not yet index.

**5. Trust surfaces — viewer analytics and feedback everywhere.**
*They:* `1 View` per meeting, thumbs on the summary, `Share` with revocable
access, `Copy Link` on skills.
*We:* no viewer telemetry (correctly — we are not an archive), and no feedback
capture on AI output at all.
*Worth taking:* the thumbs. We have no signal on whether a blind spot or a
summary was useful. Item 13's analytics now has the event vocabulary to carry it
without payload risk (`feature_used`/`feature_failed` are dimension-only).

**6. Metering — visible credits vs invisible budget.**
*They:* "Consumes AI credits", a 7-day credit trial, run counts on every skill,
`Upgrade` in the nav.
*We:* compute credits exist and are tariffed, but the composer shows cost only
for full-context mode (item 12).
*Worth taking:* the honesty of showing cost at the point of action. We already
concluded this for item 12; their UI is evidence it does not scare users off.

---

## What is explicitly NOT worth copying

- **Integration count.** Item 14 already settles this: a long shallow tail is
  their game, and depth is the landing-page argument.
- **The archive itself.** Channels, usergroups, contact graphs and revocable
  meeting access are the furniture of a company-wide record. Building it would
  put us in a market where they have a large head start and where our
  privacy posture (local transcription, outbound redaction, nothing leaves
  without asking) becomes a liability rather than a differentiator.
- **Voice Agents.** Not on cost grounds but on positioning: a product that
  attends meetings *instead of* the user is the opposite of a co-pilot that makes
  the user better in the room.

## Open questions this walkthrough did not answer

- What `Meeting Status` actually shows, and whether it is worth an equivalent.
- The `Feed` tab's contents — the account has no enabled skills, so it was empty.
- Analytics: not opened. Their `get_analytics` MCP tool suggests
  speaking-time/talk-ratio reporting, which is the classic sales-coaching angle.
- Pricing tiers and what is gated: the trial banner implies AI credits are the
  metering unit, but the boundary was not explored.
