# App Store listing — Cruxwing (M14a)

Source of truth for the App Store Connect listing. Copy each `asc-*` block into
the matching App Store Connect field. Every field is length-checked against
Apple's limits by `test/appStoreListing.test.js`, and audited for the honesty
non-negotiable (no "certified" claims, no fabricated ratings, no hardcoded
prices — the app shows live prices from the billing catalog).

## Metadata

| Field | Value |
| --- | --- |
| Primary category | Productivity |
| Secondary category | Business |
| Bundle id | `com.meetgpt.macapp` — ⚠ PERMANENT once submitted; confirm vs `com.cruxwing.mac` first (D14/D16, HUMAN) |
| Marketing URL | https://cruxwing.com |
| Support URL | https://cruxwing.com |
| Privacy Policy URL | https://cruxwing.com/privacy |
| Copyright | © 2026 Cruxwing |
| Age rating | 4+ (no objectionable content) |
| Pricing | Free with auto-renewable subscriptions + consumable packs (StoreKit; prices live from the billing catalog) |

## Fields

### App name — limit 30

```asc-name
Cruxwing
```

### Subtitle — limit 30

```asc-subtitle
AI meeting notes & decisions
```

### Promotional text — limit 170 (editable without a new review)

```asc-promotional
Bot-free, on-device meeting AI that catches the sharp question live — then logs what your team actually decided into an auditable ledger that outlives the transcript.
```

### Keywords — limit 100 (comma-separated, no spaces)

```asc-keywords
meeting,notes,transcription,AI,assistant,decisions,minutes,summary,standup,agenda,recorder
```

### Description — limit 4000

```asc-description
Cruxwing is a meeting co-pilot for your Mac. It listens to any conversation — bot-free — transcribes it, surfaces the sharp question in the moment, and records what your team actually decided into a ledger that outlives the transcript.

CATCH THE CRUX, LIVE
Set your goal for the meeting and Cruxwing surfaces fresh blind spots as you talk: sharp questions, risks, and missing information — plus live framing and fact-checking against the context you attach. It reads the room so you can stay in it.

BOT-FREE CAPTURE
Cruxwing listens to your microphone and the meeting's system audio together — no visible bot joining the call, no platform lock-in. It works in Zoom, Meet, Teams, in person, or on offline audio.

ON-DEVICE BY DEFAULT
Transcription runs on your Mac by default, so audio never has to leave your device. Prefer a cloud engine for a hard room? That's opt-in, per session.

DECISIONS, NOT JUST NOTES
Cruxwing drafts candidate decisions and action items from the conversation — but nothing enters your ledger until a human confirms it. No hallucinated decisions. Confirmed decisions land in a team-scoped, append-only ledger with owners and goals, and every change writes an audit row in the same transaction. Export it, cite it, defend it.

ONE-CLICK AI ACTIONS
Summaries, action items, fact-checks, brainstorms, and multi-model "council" reviews — each as a one-click, skill-layered action that grounds on your meeting and the sources you connect.

PLANS
Start free. Upgrade to Pro, Premium, or Ultra for more AI Copilot hours, compute credits, and grounded research — with add-on packs when you need more. Current prices are always shown in the app.

Cruxwing keeps provider keys server-side: the app ships with none. You are responsible for obtaining any recording consent the law requires; Cruxwing asks you to confirm before its first recording.
```

## Honesty & review notes

- No compliance claims in the listing. SOC 2 is "readiness in progress" (see the
  Security page) and is deliberately kept OUT of the store copy to avoid any
  "certified" implication.
- No prices are hardcoded here — the app shows live prices from the billing
  catalog; the listing only names the tiers.
- No ratings, awards, or user counts (we have none to cite).
- HUMAN calls before submit: (1) whether "co-pilot" branding needs a trademark
  check; (2) the permanent bundle id; (3) screenshots + app preview; (4) the App
  Review demo account + notes (M14b).
