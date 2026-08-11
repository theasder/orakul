# Cruxwing roadmap — mined pains → JTBD → features → RICE (2026 H2)

Method (mirrors `proglib-academy-product-pages-generator` pipeline + `content-agent`
signal mining): 4-source fan-out (Reddit/HN via archive APIs, competitor reviews,
surveys n=677–31k, YouTube titles/comments) → verbatim-quote pain clusters, ≥2
distinct sources each → audience attribution (VC-startup PM/founder kept; F100/
enterprise dropped) → per-segment JTBD → feature alternatives per job →
competitor-gap check → RICE. Full mined evidence with URLs lives in the research
transcript; every pain below carries one anchor quote.

## Pain pool (audience-weighted)

| # | Pain cluster | Anchor quote (verbatim) | Sources | Prevalence |
|---|---|---|---|---|
| P1 | Decisions evaporate, get relitigated | "the part that kills me is the relitigating… nobody's sure what we landed on" (r/ProductManagement) | 4 community + essays + Lenny's decision-log podcast | ★★★★★ |
| P2 | Capture ≠ follow-through; phantom/ownerless action items | "An action item without an owner is a wish"; "19 of 31 flagged action items completed" | 2 multi-tool tests + 3 threads | ★★★★★ |
| P3 | Drowning in notes; equal-weight bullets; nobody reads summaries | "'We're changing the entire architecture' sits next to 'Bob will be OOO Friday'" | 5+ | ★★★★ |
| P4 | Meeting overload / firefighting eats strategy | Atlassian n=5k: 78% too-many-meetings; Product Focus n=677: ~60% firefighting | surveys | ★★★★★ (macro) |
| P5 | Stakeholder alignment tax; pre-meetings; "what's blocked?" pings | MTP survey: 35% name influencing stakeholders top obstacle; "I spend more time maintaining our PM tool than doing product work" | 4+ | ★★★★ |
| P6 | Bot stigma, auto-join consent, post-call leakage | "the bot changes the conversation. We get more polished answers"; Otter litigation | 6+ | ★★★★ (moat: Cruxwing bot-free) |
| P7 | Security review dead-ends | Microsoft bans 3rd-party notetakers internally | 4+ | ★★★ (moat: on-device) |
| P8 | Accuracy: speakers, jargon, numbers, code-switching | "inability to tell who said what is a show stopper" (HN, Hyprnote launch) | 8+ | ★★★★ |
| P9 | Personal tool ≠ team system; context scattered across tools | "Critical context lives in people's heads, meetings, Slack threads" | 4+ | ★★★ |
| P10 | Repeating context; solo-PM drowning; status chasing | "45 minutes today updating statuses, syncing decisions from Slack" | 4+ | ★★★ |
| P11 | VC overhead: board prep, investor updates | "You missed the quarter. Now you have to face the board" (41k views) | 5 videos | ★★★ |
| P12 | Notes vs presence | "You end up half present for both" | 3+ | ★★★★ (already served — core product) |

## JTBD map

### Segment A — solo/first PM at a seed–Series A startup (1 PM, ~10–40 people)
- **Aspirations**: be the person whose product judgment the founders trust; stop
  being "a meeting coordinator"; leave at a sane hour with the record intact.
- **Big job (one, measurable)**: *turn every meeting-hour into a decision record
  and follow-through the team acts on, without spending the hour after the
  meeting writing it up.*
- **Little jobs**:
  1. End a call knowing what mattered in it — one screen, not 12,000 words (P3).
  2. Answer "what did we decide about X, and why" in under a minute, weeks later (P1).
  3. Make every commitment carry an owner and a date — or visibly lack one (P2).
  4. Walk into the next call already knowing what was promised last time (P1+P2).
  5. Trust names, numbers, and jargon in the record (P8).
  6. Prove to security-minded clients nothing left the Mac (P6/P7 — served today).
- **Micro jobs** (samples): open yesterday's ledger entry for "pricing"; paste the
  decision + rationale into Slack; chase the two ownerless items from Tuesday;
  check a quoted ARR figure against the transcript.
- **UTP draft**: For the solo PM who loses decisions to relitigation, Cruxwing
  turns live meetings into an evidence-quoted decision ledger you can interrogate
  — unlike Granola/Otter, which ship a transcript nobody reads and keep no
  cross-meeting memory.

### Segment B — product lead / founder-as-PM at Series B–C (2–6 PMs)
- **Aspirations**: run a team whose decisions hold without them in the room;
  stand in front of the board with an audit trail, not vibes.
- **Big job**: *keep a team of PMs and stakeholders aligned on what was decided
  and who owes what — without pre-meetings, status pings, or a wiki nobody updates.*
- **Little jobs**:
  1. See the week's decisions + open commitments across the team's meetings (P5/P10).
  2. Send stakeholders/investors a digest that gets read (P5, P11).
  3. Let a teammate look up a decision they weren't in the room for (P9, P1).
  4. Pass a security review without a meeting-bot argument (P7 — served today).
- **UTP draft**: For the product lead whose org relitigates decisions weekly,
  Cruxwing gives the team one interrogable decision record with per-audience
  digests — unlike per-seat notetaker rollouts that IT bans and nobody reads.

## Features — alternatives considered per job, gap-checked

**Job A2/B3 ("what did we decide about X")** — candidates: (a) cross-meeting
semantic recall over ledger+transcripts; (b) manual tags/folders; (c) export to
Notion and let Notion AI search. (b) = the wiki that dies (P10 evidence); (c)
re-scatters context (P9) and loses evidence quotes. **Chosen: F1 Decision
Recall.** Competitor gap: none of Granola/Otter/Fireflies answer across
meetings with evidence; Granola "one-meeting-at-a-time" called out in reviews.

**Job A1 ("one screen, what mattered")** — candidates: (a) consequence-ranked
minutes with a What-matters block; (b) shorter LLM summaries (lossy, hallucination
risk — P10 verification burden); (c) user-configurable templates (work moved to
user). **Chosen: F4 ConsequenceRanker** — deterministic, offline, testable, zero
credit cost; LLM ranking rejected: adds spend + a hallucination surface to the
one artifact that must stay trustworthy.

**Job A3 ("commitment carries an owner or visibly lacks one")** — candidates:
(a) owner/date enforcement + ownerless-item callout in artifacts; (b) full task
manager inside Cruxwing (scope trap — competitors' graveyard); (c) push into
Linear/Asana/Notion (exists: TaskWritebackSheet). **Chosen: F2 = (a)+(c)
follow-through pass: unowned-commitment section, next-meeting carry-over.**

**Job A4/B1 ("walk in knowing what was promised")** — candidates: (a) pre-meeting
brief from prior ledger by attendee overlap (BriefService exists — extend);
(b) calendar-title mining (measured rejection earlier — WER cost, parked).
**Chosen: F8 brief deepening.**

**Job A5 ("trust names, numbers, jargon")** — F10 numbers-guard (extend
fact-check to figures in artifacts); F7 vertical lexicon packs (miner exists);
F5 local diarization (FluidAudio has models; biggest effort). All kept, staged.

**Job B2 ("digest that gets read")** — candidates: (a) per-audience digest
(team/stakeholder/investor) from ledger; (b) auto-email summaries (P6 leakage
horror stories — REJECTED as default; explicit send only). **Chosen: F3,
explicit-send only.**

## RICE (Reach %active-users/quarter · Impact 0.25–3 · Confidence · Effort person-weeks)

| Rank | Feature | R | I | C | E | RICE | Tier |
|---|---|---|---|---|---|---|---|
| 1 | F1 Decision Recall (cross-meeting ask) | 80 | 3 | .9 | 3 | **72** | Now |
| 2 | F4 Consequence-ranked minutes | 80 | 1 | .85 | 1 | **68** | Now |
| 3 | F8 Pre-meeting brief: prior decisions + open commitments | 60 | 2 | .7 | 2 | **42** | Now |
| 4 | F10 Numbers guard in artifacts | 50 | 1 | .75 | 1 | **37.5** | Next |
| 5 | F2 Follow-through pass (ownerless callout + carry-over) | 70 | 2 | .8 | 3 | **37.3** | Next |
| 6 | F3 Per-audience digest (explicit send) | 65 | 2 | .7 | 2.5 | **36.4** | Next |
| 7 | F7 Vertical lexicon packs | 30 | 1 | .8 | 1 | 24 | Next |
| 8 | F5 Local speaker diarization | 70 | 2 | .6 | 4 | 21 | Later |
| 9 | F9 HubSpot writeback | 25 | 2 | .6 | 3 | 10 | Later |
| 10 | F6 Team ledger workspace | 40 | 2 | .6 | 5 | 9.6 | Later |

## Delivery log — night of 2026-08-10/11

Everything in the Now and Next tiers shipped, plus the top of Later. Each row
names the type that makes the claim true, so a deleted feature is findable from
the roadmap rather than only from the diff.

| Feature | Shipped as | Entry point | Tests |
|---|---|---|---|
| F4 | `ConsequenceRanker` + `MinutesArtifact.ranked()` | every minutes artifact | 12 |
| F1 | `DecisionRecallService`, `DecisionRecallContext` | ask flow, EN+RU intent gate | 12 |
| F8 | `BriefRecallSources.build` | `refreshMeetingBrief` | 2 |
| F10 | `NumbersGuard` + `auditingNumbers(against:)` | minutes decode | 5 |
| F2 | `OpenCommitments`, `repeatedPromises` | brief (leads it) + minutes callout | 10 |
| F3 | `WeeklyDigest` + `copyWeeklyDigest` | menu bar, three audiences, copy-only | 11 |
| F7 | `DomainLexicon.verticalPacks` | whole-file restore, signal-gated | 9 |
| F5 | `SpeakerAssignment`, `LocalDiarization` | post-call pass, **flag off** | 11 |

### F5 measurement, 2026-08-11 — the flag stays off

Three EdAcc conversations, two speakers each by construction, accented English
(Indian, Romanian, Chinese, American — representative of who uses this):

Run twice: three files first, then all five EdAcc dyads available.

| threshold | n=3 correct | n=5 correct | n=5 counts |
|---|---|---|---|
| 0.5 | 0/3 | 0/5 | 3, 3, 3, 7, 3 |
| 0.6 | **2/3** | 1/5 | 2, 3, 4, 3, 4 |
| 0.65 | 1/3 | **2/5** | 2, 2, 3, 4, 6 |
| 0.7 (library default) | 0/3 | 0/5 | 1, 3, 5, 5, 5 |
| 0.8 | 1/3 | 1/5 | 1, 2, 3, 3, 4 |
| 0.9 | 0/3 | 1/5 | 1, 1, 1, 1, 2 |

Measured again 2026-08-11 on five EdAcc conversations (five minutes each, 5,000+
seconds of accented two-person English) with per-turn ground truth, scoring
ATTRIBUTION — share of speech time landing on the right person, after mapping
arbitrary speaker IDs the way that flatters the model most:

| threshold | mean attribution | as read (per line) | exact speaker count |
|---|---|---|---|
| 0.5 | **70.6%** | **88.3%** | 2/5 |
| 0.6 | 63.8% | 81.6% | 1/5 |
| 0.65 | 68.1% | 85.1% | 2/5 |
| 0.7 (library default) | 57.5% | 70.9% | 0/5 |
| 0.8 | 49.5% | 61.1% | **3/5** |
| 0.9 | 47.7% | 59.7% | 0/5 |

Two metrics because they answer different questions. Time-weighted attribution
is what the MODEL does. As-read is what a READER sees: the product never shows
raw turns — `SpeakerAssignment` gives each transcript line the speaker who
overlaps it most, so a turn too short to win a line never reaches the screen.
The gap between the columns, 17.7 points at the best setting, is error the
product already absorbs; scoring only the left column would have been
pessimistic about a shipping decision.

The bar was written into the test before the run: 90%. Best as-read is 88.3%, so
**F5 stays dark** — but by 1.7 points rather than by twenty. That is a feature
worth one more attempt, not a feature that is far away.

Two things narrow what that attempt should be. The mean hides its worst file:
at the best threshold one conversation still reads 74.7%, a quarter of its lines
naming the wrong person, and an average is no comfort to whoever owns that call.
And the obvious fix is already ruled out — island merging, which is what the
cloud path uses against exactly this complaint, cannot fire here: the pass emits
no segment shorter than a second on any of the five conversations. Its
over-segmentation is multi-second turns handed too many identities, so the
remaining work is in clustering (embedding quality, or re-clustering globally
once the whole file is known), not in tidying up fragments.

Read the last two columns together: the setting with the BEST count agreement
(0.8) is second worst by attribution, and 0.6 — which looked best at n=3 and was
deliberately not adopted — is mid-table. Choosing a default from speaker counts
would have shipped nearly the worst option. That is the finding, not the 70.6%.

The second run is why the first one's "best" was recorded as a hint and not
adopted: 0.6 led at n=3 and falls to 1/5 at n=5, while 0.65 takes over. Neither
is close to usable. The library default is still among the worst settings on
this material, and no threshold tested gets more than two files in five right.

Speed was never the constraint — 118–150x realtime, 74–88% speech coverage.
Clustering is. "Speaker 5" in a two-person call is exactly the failure this
feature answers, so it stays dark. The next attempt needs a better approach
(known-speaker enrollment, or the mic track as an anchor for one voice), not a
better constant.

Not shipped and why: F9 (HubSpot) and F6 (team workspace) need surfaces outside
this app — a CRM account and a backend workspace model — so neither is a night's
work. F5 is code-complete but dark: a confidently wrong speaker label is the
exact complaint it answers, so it waits on a measurement against the metered
pass (`CRUXWING_DIARIZE_WAV=… swift test --filter smokeRealDiarization`).

### What the verification pass found

Every feature above passed its own tests when it was written. A second pass
drove each one through the seam where it actually runs, at realistic scale, and
found eight defects — none of which any unit test could have seen:

| # | Defect | How it was found |
|---|---|---|
| 1 | Recall took **183s** over 250 sessions (brief: 284s), on the ask path | perf harness with a year of meetings |
| 2 | `store.list()` called inside a filter — quadratic disk decodes | reading the hot path after (1) |
| 3 | Recall excerpts uncapped: one long paragraph could inject tens of KB into every prompt, on the user's credits | bounding audit |
| 4 | Weekly digest unbounded — recreated the wall of text it exists to replace | same audit |
| 5 | Highlight lines and the figures warning unbounded (caps on count, none on size) | same audit |
| 6 | Recall and digest read `SessionStore.shared`, not the injected store | end-to-end test through `AppState.ask` |
| 7 | `ship.sh HEAD` rebuilt the previous batch — green log, wrong binary | launching the shipped app |
| 8 | Three suites failed on every full run and passed alone | running the full suite honestly |
| 9 | **Recall could not find a meeting by name at all** — 2 of 3 phrasings returned nothing, because sentence-embedding cosine rewards topical resemblance while a recall question asks about a NAME | measuring accuracy, not just speed, at 250 sessions |

| 10 | The numbers guard flagged **every spoken figure** as invented — "twenty five hundred" vs "$2,500" — so on real speech it would have cried wolf constantly | testing it against numbers said aloud rather than typed |
| 11 | Glossary restore rewrote a product name (`adcreative.ai` → `adcreative.AI`) and an ordinary English word (`confluence`) | running the pass over 10,944 words of real recorded speech |
| 13 | **Island merging cannot help the local pass — it emits no islands.** The cloud path collapses one-word speaker islands, so the same fix looked obvious here; measured, the diarizer produced ZERO segments under a second on all five conversations (median 2.3-3.1s), and merged output scored identically to raw at every threshold, to the decimal | writing the merge, then measuring whether it fired |
| 12 | **The F5 verdict rested on the wrong metric.** Speaker COUNT is close to uncorrelated with getting the words on the right person: threshold 0.8 had the best count agreement (3/5) and the second-worst attribution (49.5%), and on one conversation found exactly two voices while attributing only 38.9% correctly | scoring attribution against per-turn ground truth instead of counting voices |

On (9): the first suspicion was the shortlist added in (1). Disabling it changed
nothing — the defect predated the optimisation and would have shipped either
way. Fixed with a hybrid score (cosine + share of the question's distinctive
words present), which also made recall FASTER: with the lexical half doing the
discriminating, four semantic comparisons per session beat six. 2.19s → 1.59s.

The through-line: fixture-sized tests prove *behaviour* and say nothing about
*proportion*, and a green pipeline says nothing about *what it built*. Both now
have guards — perf budgets (`CRUXWING_PERF=1`), bounding tests, an end-to-end
request assertion, and a release chain that reads the commit stamp back out of
each DMG before it will upload.

Open follow-ups:
- The A/B arms exist but nothing splits traffic to `/v2.html` yet — it needs a
  campaign link or an nginx rule before the `arm` dimension has anything to
  compare.
- Free tier stays on the floor model: one credit ($0.005) does not cover a
  Haiku scan (~$0.0070). Changing that is a pricing decision, not a routing one.

Confidence sources: F1 .9 (highest-prevalence pain, direct quotes, competitor gap
verified); F5 .6 (model quality on-device unproven); F6 .6 (distribution risk,
needs backend surface). Reach = share of weekly-active users the feature touches
in a normal week. Effort = solo-dev weeks against the existing codebase
(embeddings index, BriefService, TaskWriteback, fact-check all already exist —
which is what keeps F1/F8/F10 cheap).

Non-goals (explicit): full task manager (P2 answered by enforcement+writeback,
not by another tracker); auto-send anything (P6); stealth/undetectability
(anti-goal per blindspots section); meeting-count analytics theater.
