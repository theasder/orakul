# Launch decisions log

Format: goal / options / rationale / revisit-date.

## D1 — Quota period = rolling 30 days (2026-07-10)
- Goal: enforce the sold "1,000 AI requests/mo" (pro) server-side.
- Options: (a) calendar month, (b) Stripe billing-period anchor, (c) rolling 30 days.
- Rationale: (c) needs no Stripe round-trip and no anchor bookkeeping; strictly
  fair to the user (never counts more than 30 days of usage); (b) is the
  eventual right answer once webhook lifecycle carries period boundaries.
- Revisit: when M7 telemetry lands (llm_usage will then carry tokens/cost too).

## D2 — `guidance` passthrough: keep, but authenticated + metered + neutralized (2026-07-10)
- Goal: close the 2,000-char free-text injection surface on the server key
  without losing local/server prompt parity for theme/role skill layers.
- Options: (a) drop the param, (b) strict whitelist of known layer texts,
  (c) require sign-in + count against quota + wrap as non-authoritative style
  preferences under the handler's own contract.
- Rationale: (a) regresses output parity; (b) breaks whenever the client's
  bundled skills update out of step with the server; (c) makes abuse cost the
  abuser their own quota and keeps the JSON contract authoritative. Cap stays
  at 2,000 chars.
- Revisit: if abuse telemetry (M7) shows guidance-driven token spikes.

## D3 — payment_failed marks past_due; only subscription.deleted deactivates (2026-07-10)
- Goal: honest lifecycle without punishing one failed card charge.
- Rationale: Stripe retries invoices (smart retries); hard-deactivating on the
  first failure churns recoverable users. `past_due` removes the plan from
  getUserPlan (status filter) — access pauses, record survives; deletion is the
  terminal event.
- Revisit: M11 IAP decision (Apple notifications V2 carry their own states).

## D4 — On-device model catalog = base / small / large-v3 (not turbo) (2026-07-11)
- Goal: hardware-tiered local default + a Settings model picker (M4b) without
  shipping a model name that fails to download.
- Options: (a) include large-v3-turbo (best real-time accuracy), (b) restrict to
  the unambiguous variants base/small/large-v3.
- Rationale: WhisperKit's download resolver globs `*<variant>/*` against repo
  folders; the turbo builds carry size/date suffixes
  ("openai_whisper-large-v3_turbo_954MB", "…-v20240930_turbo_632MB") so the
  short string "large-v3-turbo" matches no clean folder and would 404 on first
  use. base/small/large-v3 each map 1:1 to a clean folder. Hardware default:
  Apple Silicon → small (real-time on the ANE), Intel → base.
- Revisit: add turbo once the exact working variant string is verified against
  a live download (it is the ideal Apple-Silicon default — fast + accurate).

## D5 — M5c Slack OAuth blocked on human app registration (2026-07-11)
- Goal: replace the env bot-token Slack setup with in-app OAuth + a channel
  picker, per M5.
- Options: (a) build the backend OAuth route now (dormant until credentials);
  (b) mark blocked on the human console task and proceed to autonomous work.
- Rationale: meaningful M5c completion is gated on a human creating a Slack app
  (client id/secret, redirect URL, scopes) — a console/credential task the
  mission says to surface, not fabricate. A dormant, un-E2E-verifiable OAuth
  route is lower value than M6's fully-autonomous, cost-relevant caching/catalog
  work. The existing env-token TeamConnectors.slack path remains a working
  self-host fallback, so nothing regresses. Chose (b).
- Human to unblock: register the app, set SLACK_CLIENT_ID/SLACK_CLIENT_SECRET +
  redirect URL server-side; then the loop builds the OAuth route + channel picker.
- Revisit: when Slack credentials exist, or M5 is the only remaining work.

## D6 — "server-side grounding cache" (M6d) is N/A in the current architecture (2026-07-11)
- Goal: cache repeated MCP/team grounding lookups within a call (M6d's second half).
- Finding: grounding runs CLIENT-side — MCPGrounding + the 120s AppState.groundingCache
  connect to hosted MCP servers directly (keyless). The backend (brainstorm/factcheck,
  llm gateway) receives already-grounded context from the client and does NO MCP/team
  lookups, so there is nothing server-side to cache.
- Decision: the client 120s groundingCache is the grounding cache story; no server-side
  grounding cache is built. The server-side response cache (unchanged-transcript polls)
  is a distinct concern and lands in M7 (responseCache.js).
- Revisit: if grounding ever moves server-side (e.g. a backend MCP proxy).

## D7 — BackgroundLLMQueue is a gate (reserve/finish), not a runner; cap 2; digest/goal loops excluded (2026-07-11)
- Goal: M7a — one cost gate for the 5 background watch loops (brainstorm, agenda,
  fact-check, rhetoric, facilitation) so coalescing is uniform and aligned timers
  can't stack a burst of paid LLM calls.
- Options: (a) an actor that RUNS each loop's operation (owns the work), (b) a
  gate the loop asks permission from (reserve→run-your-own-work→finish).
- Rationale: AppState is @MainActor and each loop mutates MainActor state
  (factClaims, rhetoricNote, suggestions…). Making the actor run the operation
  forces every loop body onto the actor's executor and back via MainActor.run —
  noisy and error-prone. A gate keeps the work where it already lives; only the
  arbitration (coalesce/single-flight/backpressure) crosses the isolation
  boundary. Chose (b). maxConcurrent=2 lets a slow call overlap a fast one
  without letting all five fire at once. Coalescing was ADDED to brainstorm/
  agenda (previously re-ran every cycle even on an unchanged transcript — pure
  waste, since mergeSuggestions dedups anyway) — a strict cost win, no behavior
  loss. The digest-fold (120s rolling summary) and goal-suggest (fires until a
  goal exists) loops are intentionally OUT: digest must run to keep continuity,
  goal-suggest is one-shot; neither is a repeated same-input poll. Client-only,
  fully unit-tested (no live LLM); the server-side halves are M7b/M7c/M7d.
- Revisit: if telemetry (M7c) shows the cap starving a loop, or if digest cost
  becomes material enough to meter.

## D8 — Response cache sits BELOW metering; keyed on the request payload, shared across users (2026-07-11)
- Goal: M7b — stop re-billing the provider when the same brainstorm/factcheck
  input is polled again within a short window.
- Options: (a) cache above the route (skip auth+quota too), (b) cache inside the
  handler below auth+meterLlmFeature, (c) per-user cache keys.
- Rationale: (b) — the metering middleware (authenticate → meterLlmFeature →
  handler) must still run so a user's quota reflects requests they actually make;
  the cache only saves OUR OpenAI call, not the user's fair-use count. (a) would
  hand out free unmetered responses. Chose (b). Cache key = sha256 of the full
  payload (goal/transcript/prior/guidance for brainstorm; transcript/context/
  guidance for factcheck) + model. NOT per-user (c): the output is a pure
  function of the payload, so a cross-user hit only ever returns something the
  hitting caller already supplied as input — no data they couldn't derive
  themselves, and identical input across users is exactly the case worth sharing.
  temperature:0 factcheck is deterministic; brainstorm is 0.7 but a hit still
  returns a valid answer for that exact input. 60s TTL (a call's transcript grows,
  so a same-(transcript,prior) re-poll inside 60s is a true duplicate), 500-entry
  LRU, env-overridable. In-process (single node); swap for Redis if we scale out.
  Telemetry: stats() exposes hit rate for the M7c cost meter.
- Revisit: M7c wires stats() into cost frames; multi-node deploy needs Redis;
  raise TTL if hit-rate telemetry shows headroom.

## D9 — Cost meter is in-process first; pricing is internal config, not user-facing (2026-07-11)
- Goal: M7c telemetry half — know what each server-key LLM call costs and alert
  when a daily budget is crossed, satisfying the "every LLM feature ships with
  telemetry" non-negotiable.
- Options: (a) persist per-call tokens/cost to llm_usage now (schema migration +
  move the metering seam so the handler, which has the token counts, writes the
  row); (b) an in-process cost meter that reads the provider `usage` field per
  call, with the DB ledger as a follow-up.
- Rationale: (b) — the metering middleware records the quota row BEFORE the
  handler runs (it has no token counts yet); adding tokens means either a second
  DB write per call or relocating the quota seam, both riskier than the telemetry
  is urgent. An in-process meter with the real `usage` tokens delivers the
  ship-gate telemetry (per-call cost, daily total, budget alert, per-feature
  breakdown) now, fully unit-testable with an injected clock, no DB/network.
  Split the durable per-user ledger into M7c-2. Pricing: gpt-4o-mini (the model
  actually called) from its public rate; a conservative documented default for
  anything unpriced; env override (LLM_MODEL_PRICING). These are INTERNAL
  cost-accounting estimates — never shown to users — so the honesty guardrail
  (no fabricated user-facing metrics) is intact. Cache hits record no frame ($0),
  so the meter also quantifies what M7b saves.
- Revisit: M7c-2 persists frames to llm_usage; wire the gateway (streaming) path
  once it exposes token usage; keep the pricing table current from provider docs.

## D10 — fastAudit's cost guarantee is "never escalate", not "always free"; provider affinity is deliberate (2026-07-11)
- Goal: M7d-1 — lock in that mechanical/background LLM passes actually use the
  cheap tier, so a catalog edit can't silently make them expensive.
- Finding: fastAudit maps OpenAI/Google selections (and Auto/council) to a
  free-tier fast model, but for providers with NO cheap catalog entry
  (Anthropic, Moonshot, DeepSeek, Qwen, Zhipu) it returns the SAME model — so a
  Pro/Premium user who explicitly picks e.g. Claude Sonnet runs mechanical passes
  on Sonnet, not a cheaper model.
- Options: (a) test only the universal "never escalate" invariant and document
  the affinity fallback; (b) change fastAudit to fall back to the global cheapest
  model (gpt-5.4-mini) for all providers.
- Rationale: (b) would break DIRECT-KEY mode — a user who configured only an
  Anthropic key would have mechanical passes routed to OpenAI and fail. fastAudit
  is a pure catalog function with no gateway-mode awareness. So the safe,
  universally-true guarantee is "fastAudit(m).minTier ≤ m.minTier" (never
  escalate) + "an actual downgrade lands on free tier" + "provider preserved".
  Chose (a). The launch DEFAULT is Auto, which fastAudit routes to gpt-5.4-mini
  (free) — so the common path is already cheap; the gap only affects users who
  hand-pick a premium non-OpenAI/Google model (they opted into paying for it).
- Revisit: in BACKEND mode (launch config, all keys server-side) cross-provider
  fast routing is safe — a future slice can make fastAudit gateway-aware and
  route premium non-OpenAI/Google mechanical passes to the global cheap model.

## D11 — Orchestration: 4 price-tiered council panels + new Ultra tariff; China council reversed (2026-07-11, user-directed)
- Goal (user request): orchestration ("Auto") offered as price/power-tiered
  multi-model councils mapped to tariffs, plus a China-models orchestration option.
- Decisions:
  - Four OrchestrationLevels, each a council (members answer independently, the
    strongest member CHAIRS the synthesis): Free (mini+Flash) · Medium
    (Sonnet+GPT-5.5+Flash, Pro) · Max (Opus 4.8+Sol+Gemini Pro, Premium) · Ultra
    (Fable 5+Sol+Gemini Pro, Ultra plan). Chairman = panel's strongest member.
  - Power order Ultra(Fable 5) > Max(Opus 4.8): Fable 5 is the newer Claude-5
    flagship, so it out-ranks Opus 4.8; catalog places Opus before Fable so Fable
    stays the strongest Anthropic autoVersion.
  - New 4th billing tier "Ultra" (Tier.ultra, rank 3) above Premium — the plan
    that unlocks the Ultra council. Backend TIER_RANK gains ultra:3. (Billing
    plan wiring is Phase 2.)
  - Added claude-opus-5 (Anthropic premium, vision) to all catalogs + a
    costMeter Opus-class pricing estimate ($15/$75 per 1M — flagged to verify).
  - CHINA COUNCIL REVERSED: the 2026-07 "China council never offered" decision is
    withdrawn per the user; councilAvailable(.china) now follows the SAME ≥2-
    configured-member rule as US (symmetric). Individual CN models were already
    available; this only re-enables the China-only preset.
- Runs where: the panels need multi-model fan-out, which the KEYLESS launch build
  can't do client-side (backend serves single-model chat). User chose to build a
  BACKEND ENSEMBLE ENDPOINT (Phase 3) so panels work in the dist build — N× cost,
  authed + metered.
- Phasing: P1 (done) catalog+tier+panel data+China reversal; P2 billing (ultra
  plan in PAYWALL_PLANS, entitlement/quota); P3 backend ensemble endpoint
  (fan-out + chairman synthesis + N× cost frames); P4 client wiring + paywall UI.
- Revisit: verify Opus 4.8 real pricing; confirm Ultra plan price at P2.

## D12 — Compute-credits tariff model (landed externally; verified + build-fixed 2026-07-11)
- What: functions/tariffs.js is now the ONE commercial source of truth (landing +
  mac paywall + Stripe + server quota). Cost-weighted "compute credits" replace
  raw request counts — a council spends more than a mini call — so allowances are
  economically comparable: free 15 / pro 250 / premium 750 / ultra 1500 credits/mo,
  plus copilotHours + groundedCycles, plus buyable add-on packs and regional price
  multipliers. quotaError is now credit-based; billing period resets on the
  subscription anniversary. Ultra priced $99/mo (was a $49 placeholder).
- Honesty: prices are served by publicPlans() → GET /api/billing/plans and the
  client reads them via PaywallAPI.catalog() — nothing hardcoded client-side.
  Secret scan of the full diff: clean.
- This loop's contribution: the refactor left the mac build broken on one line
  (PaywallView `.frame(width:maxHeight:)` — not a valid overload); fixed to two
  .frame calls. Both suites then green (backend 260, mac 316).
- FLAG FOR HUMAN: the credit costs, allowance sizes, add-on/plan prices, and
  regional multipliers are BUSINESS decisions — review before launch. Committed
  the green tested state so it isn't lost; amend pricing freely.
- Revisit: confirm per-model credit weights track real provider cost once cost
  telemetry (costMeter) has live data.

## D13 — COST PASS #1: cost engine audited green; charging middleware extracted + tested (2026-07-11)
- Audit result: every server-key LLM surface (brainstorm, factcheck, orchestrate,
  llm/chat) ships with tier + cache + telemetry. Compute credits are reserved
  BEFORE the handler via reserveComputeCredits → reserveLlmUsage, which is atomic
  (pg_advisory_xact_lock(userId) → SUM the billing period → check limit → INSERT
  the debit, all one tx) so concurrent flagship calls can't overspend; the debit
  row (llm_usage.compute_credits) IS the durable usage ledger sumComputeCreditsSince
  reads for the quota. Costs are correct per tariffs.test (per-model/level +
  input-token surcharge). Metering fails CLOSED (503) — never serve free LLM.
- Gap + fix: meterLlmFeature (the middleware that actually charges) was an inline
  closure in auth/index.js, unexported and untested — the highest-value cost seam
  with no direct coverage. Extracted to functions/auth/meterLlmFeature.js (DI
  factory) and added 6 unit tests: allow→next, over-budget→429, metering-throws→
  503-fail-closed, correct usage assembly (feature/level/inputChars/tier),
  orchestration tier gate→403-uncharged, unknown-level→pass-through-uncharged.
- Notes: cache hits still charge credits (intended — the cache saves OUR provider
  cost, not the user's fair-use count; D8). A quorum-failed council still debits
  (the providers were called and cost real money) — acceptable, revisit if users
  complain. Pricing/credit weights remain a human business call (D12).
- Revisit: COST PASS #2 after two more milestones; re-check when M7c-2 (durable
  token/$ ledger) or the PG rate limiter (M7d-2) land.

## D14 — M11 launch decisions: canonical name + IAP strategy (OPEN — awaiting human, 2026-07-12)
Both are product/legal calls the mission says to surface, not fabricate. Brief:

### 1. Canonical customer-facing name (3 names in the tree today)
- Cruxwing — CUSTOMER-FACING now: paywall ("Cruxwing plans"), api.cruxwing.com,
  the whole web/ landing. No trademark risk.
- MeetGPT — the BUNDLE: CFBundleName=MeetGPT, com.meetgpt.macapp, app dir, 8 views.
  RISK: Apple + OpenAI brand rules restrict "GPT" in an app's DISPLAY name — a
  real App-Review-rejection risk if "MeetGPT" is the App Store name.
- Wheespr — INTERNAL backend/auth name (WheesprAuth; 12 mac + 5 backend files);
  users never see it.
- RECOMMENDATION: customer-facing name = **Cruxwing** (already the marketing name,
  avoids the GPT-name risk). Keep Wheespr internal (no user impact, no rename
  churn). Bundle id: decide `com.cruxwing.mac` vs keep `com.meetgpt.macapp` (a
  bundle id is PERMANENT once an App Store record exists — must be set before the
  first submission; not user-visible, but should be chosen now).

### 2. IAP strategy — how paying customers pay on the Mac App Store
Our model = subscriptions (Pro/Premium/Ultra) + consumable add-on packs
(compute/copilot/transcription), all priced server-side in tariffs.js.
- (a) StoreKit 2 IAP — Apple's in-app purchase. Subs → auto-renewable IAPs,
  add-ons → consumable IAPs. Apple cut 15–30%. Prices set in App Store Connect
  (a SYNC burden vs the billing API — honesty rule wants prices from the API).
  Frictionless + always-approved; most complex to build (StoreKit 2 + a receipt→
  entitlement bridge to our plans table).
- (b) US external-link entitlement — link out to the existing Stripe Checkout
  (post-Epic External Purchase Link Entitlement). US-only; Apple still takes
  ~12–27%; needs the entitlement + a scare-sheet; heavier review. Reuses Stripe.
- (c) Web-account-only ("reader"-style) — app is free on MAS, ALL purchasing on
  the website; the in-app paywall must DROP its purchase CTA (anti-steering: no
  in-app link/mention of external buying). No Apple cut, reuses Stripe, simplest
  to build — but means gutting the paywall's "See plans → Stripe" flow and losing
  in-app conversion.
- RECOMMENDATION: this is a revenue/legal call for the human. If maximizing MAS
  conversion + lowest review risk → (a) StoreKit 2. If protecting margin + you
  accept web-only conversion → (c). (b) is a middle path, US-only.
- Revisit: blocks M12 (bundle id in appstore.sh) and the paywall's purchase path.

## D14 RESOLVED (2026-07-12, human): name = **Cruxwing**; IAP = **StoreKit 2**.
- Name: Cruxwing is the canonical customer-facing name. M11a done — set
  CFBundleDisplayName=Cruxwing and renamed every user-facing "MeetGPT" string in
  the mac Views (menu bar, sidebar, overlay, onboarding, settings, MCP, paywall).
  Kept internal: SwiftPM target "MeetGPT", CFBundleName, bundle id
  com.meetgpt.macapp (a permanent id — reconsider com.cruxwing.mac at M12 before
  the first submission; not user-visible). Wheespr stays the internal backend name.
- IAP = StoreKit 2 (M11b, next, multi-iteration): auto-renewable subs
  (Pro/Premium/Ultra) + consumable add-on packs, a StoreKit 2 purchase flow, and a
  receipt→entitlement bridge that activates the plans table (like the Stripe
  webhook path). App Store Connect product creation is a HUMAN step. Prices still
  from the billing API for display; StoreKit product ids map to tariffs.js.

## D15 — Purchase-path A/B (StoreKit IAP vs web Stripe): channel-level + server cohort (2026-07-12, human)
- Goal: A/B test whether MAS StoreKit IAP or web Stripe checkout converts/nets more.
- Decisions (human): (1) CHANNEL-level test — the MAS build stays IAP-ONLY (no
  in-app web link → zero anti-steering / App-Review risk); the web funnel + any
  off-MAS build use Stripe; (2) SERVER-controlled cohort assignment.
- Built (this slice, App-Review-safe backend only): functions/abTest.js —
  purchaseArm(userId, split) → stable 'iap'|'web' (sha256(userId)→[0,1) < split),
  env-tunable AB_WEB_PURCHASE_SPLIT (default 0.5), anonymous→iap, out-of-range
  split→default. Exposed in the profile payload (sanitizeUser → /me, /auth/profile)
  so the client/landing steers the purchase CTA. No client purchase-flow change
  (MAS remains IAP-only). Tests: stable, split 0/1/0.25/0.5 distribution, anon,
  bad-split, bucket∈[0,1).
- Revisit: conversion attribution per arm lands with StoreKit (M11b) + funnel
  analytics (M15); log the arm at plan activation then. Split retunable via env,
  no client update.

## D16 — MAS packaging lane (M12a): appstore.sh + fail-safe secret gate (2026-07-12)
- Goal: a Mac App Store signing/packaging/upload lane, separate from the
  Developer-ID notarize.sh, with a hard guarantee that a key-baked binary can
  never reach the store.
- Decisions: (1) appstore.sh mirrors notarize.sh but signs with "Apple
  Distribution" (not Developer ID), embeds a provisioning profile, and wraps the
  app in a productbuild .pkg signed with "3rd Party Mac Developer Installer" — no
  hardened runtime (MAS relies on the App Sandbox). (2) The SECRET_VARS "empty or
  abort" gate is a standalone assert-no-baked-secrets.sh that scans the SHIPPED
  Mach-O binary (defense beyond build.sh's stripping) and redacts any match. It
  runs before productbuild/upload; verified live — it refuses the current dev
  build (keys baked) and passes clean input. (3) Pre-flight fails fast on missing
  Apple creds so no half-signed pkg is ever produced; MAS_DRY_RUN=1 runs the
  keyless build + secret gate without creds.
- SURFACED (human call, do NOT auto-decide): the bundle id is PERMANENT once
  submitted. Info.plist ships com.meetgpt.macapp; D14 flagged com.cruxwing.mac as
  a pre-submission revisit. appstore.sh's header calls this out; a human must
  confirm/change Support/Info.plist BEFORE the first submission.
- Revisit: signing certs + provisioning profile + Transporter upload are M12b
  (HUMAN, paid Apple account). The script + gate are ready for them.

## D17 — Landing under version control + pricing reconciled to the catalog (2026-07-12)
- Goal: bring web/landing into git and guarantee its pricing/claims obey the
  honesty non-negotiable (prices from the billing API; readiness≠certified; no
  fabricated logos/metrics).
- Decisions: (1) Committed web/landing (index.html + assets + placeholder-only
  hubspot.js + briefs; .DS_Store gitignored). (2) The landingPricing test now
  DERIVES the expected consumer-tier + shown-add-on prices from tariffs.js
  (TARIFF_PLANS/ADD_ONS) rather than hardcoding them — a catalog price change now
  fails the test until the landing is updated, so the static fallback can't drift
  from what the API charges. The live hydration hook (fetch /api/billing/plans →
  overwrite card prices) was already present. (3) Audit passed: SOC 2 framed as
  "readiness, not certification" + explicit disclaimer; only Cruxwing's own logo;
  no invented metrics/testimonials.
- SURFACED (human call): the Team pilot (target $29, "seat billing rolling out")
  and Enterprise ("from $15k, custom") tiers are honestly labeled not-shipped but
  live OUTSIDE the consumer billing API, so they can't be API-reconciled. Whether
  to advertise aspirational team pricing before it's self-serve is a product call.
- Revisit: M13b (/privacy /terms /security pages) unblocks the M10c-2 consent
  links; M13c (HubSpot portal id/form guid, SEO/analytics, deploy) needs a human.

## D18 — Legal pages: honest drafts describing actual behavior, flagged for review (2026-07-12)
- Goal: give the in-app consent link + landing footer real /privacy /terms
  /security destinations instead of dead links, without fabricating legal or
  compliance claims.
- Decisions: (1) Content is written to MATCH what the app actually does — privacy
  mirrors the App Store privacy manifest (audio/transcript for app functionality,
  email for identity, on-device default, no tracking, no data brokers, in-app
  account deletion); security describes only real posture (keyless client, pinned
  TLS, JWT auth, team isolation, App Sandbox). (2) SOC 2 is framed exactly as the
  landing does — "readiness, NOT a certification" — and a test forbids any
  "certified" claim. (3) Terms puts the recording-consent obligation on the user
  (Cruxwing records meetings; consent law varies) and discloses Apple/Stripe
  billing. (4) Every page carries an honesty note that it is pending legal review;
  the contracting entity + governing law are bracketed [TBD by counsel].
- Rationale: honest, accurate drafts are strictly better than dead links and are a
  legitimate engineering deliverable; final legalization is a human/counsel step.
- Revisit: counsel finalizes entity + governing law + DPA before public launch;
  pages go live with the M13c deploy.

## D19 — Landing SEO + honest structured data (M13c-1); analytics must be cookieless (2026-07-12)
- Goal: make the landing crawlable/indexable without violating the honesty
  non-negotiable (no fabricated ratings) or the privacy policy's no-tracking claim.
- Decisions: (1) robots.txt + sitemap.xml (/,/privacy,/terms,/security),
  per-page rel=canonical, og:url + robots meta. (2) JSON-LD SoftwareApplication
  with NO aggregateRating/review (we have none) and the only price the genuinely-
  free $0 tier — so structured data cannot drift from the billing catalog. A test
  forbids ratingValue/reviewCount/award. (3) Analytics is deferred to [HUMAN]
  M13c-2 and MUST be cookieless (Plausible/Fathom-style), because the privacy
  policy states no cross-site tracking — shipping GA/cookie analytics would make
  that page a lie. HubSpot stays placeholder-only until a human supplies the
  portal id/form guid; deploy needs a static host with clean-URL routing.
- Revisit: M13c-2 (HubSpot creds, cookieless analytics, deploy) at launch.

## D20 — App Store listing copy as a length-checked, honesty-locked deliverable (2026-07-12)
- Goal: produce the App Store Connect listing (M14a) as a versioned artifact a
  human can paste field-by-field, without risking an over-limit rejection or an
  honesty-non-negotiable violation.
- Decisions: (1) launch/app-store-listing.md holds each field in a parseable
  ```asc-<field>``` block; test/appStoreListing.test.js enforces Apple's hard
  limits (name/subtitle 30, promo 170, keywords 100, description 4000) so a
  too-long field fails CI, not App Review. (2) Honesty locked by test: no
  "certified"/SOC2 in store copy (kept out deliberately), no fabricated
  ratings/awards/user-counts, and NO hardcoded prices — the description names the
  tiers and says "prices always shown in the app" (live from the catalog).
  (3) Copy is drawn from the already-audited landing, so it describes only shipped
  behavior (on-device default, bot-free, human-confirmed decisions, consent
  responsibility).
- SURFACED (human, M14c): trademark check on "co-pilot"; the permanent bundle id;
  screenshots/app preview; the App Review demo account + notes (M14b drafts them).
- Revisit: M14b review-readiness checklist next; M14c is the ASC paste + submit.

## D21 — App Review readiness: 5.1.2 determination + Cruxwing permission strings (2026-07-12)
- Goal: a verified review-readiness map (M14b) that pre-empts the common Mac App
  Store rejections, with the Sign-in-with-Apple question answered correctly.
- Decisions: (1) 5.1.2 (Sign in with Apple) is NOT triggered — the primary
  account uses first-party auth (email OTP / email+password / phone OTP via
  WheesprAuth); "Sign in with Google" is only a Calendar data connector in
  Connected Apps, not account login. Documented + a reviewer note clarifies it;
  suggested relabeling the button to "Connect Google Calendar" to remove any
  ambiguity (deferred — UI copy, parallel-session file). (2) Reviewer demo account
  MUST be email+password, not OTP (a reviewer can't receive the one-time code).
  (3) Fixed the user-facing Info.plist permission strings (mic/screen/speech) from
  "MeetGPT" → "Cruxwing" and added NSHumanReadableCopyright — the internal
  CFBundleName/executable stay MeetGPT (D14). (4) The readiness map cites only
  verified files; a test asserts each path exists so it can't drift.
- Revisit: M14c [HUMAN] — demo credentials, screenshots, ASC IAP products,
  verifier config, bundle-id + trademark confirmation.

## D22 — Promo redeem without email → device-scoped account (2026-07-12, user request)
- Goal (user): "after promocode, don't ask me email — just give access to switch
  between tariffs."
- Constraint surfaced: entitlements are per-user and server-enforced (the LLM
  gateway meters per account), so tier access needs SOME identity or it's either
  broken (calls rejected) or an unmeterable anonymous hole. A purely local tier
  flip would show Ultra but fail on real calls (dishonest). User chose (via
  AskUserQuestion) the auto-device-account option over local-preview.
- Built: POST /api/promo/device-redeem (functions/deviceRedeem.js) — a valid code
  + a stable device id mints an anonymous device-bound account (synthetic
  non-deliverable email), activates the code's plan, and returns a session. SAFE:
  idempotent per device (re-redeem reuses the account, no extra use), capped by the
  promo usage_limit (atomic claimPromoByCode), rate-limited per IP. Client:
  Config.deviceId (persisted UUID), PaywallAPI.deviceRedeem adopts the returned
  session; PaywallView.redeem() calls it when not signed in — no email bounce.
  6 DB tests (mint / idempotent / cap / rejections) + snake_case session contract.
- Revisit: device accounts are recoverable only on that device (no email). If a
  user later wants a portable account, add an "attach email" upgrade path.

## D23 — Funnel metrics: first-party + cookieless (M15a) (2026-07-12)
- Goal: real launch conversion metrics without violating the privacy policy's
  "no tracking across apps/websites" claim or the "no fabricated metrics" rule.
- Decisions: (1) First-party POST /api/funnel with a FIXED stage taxonomy — arbitrary
  stages 400, and any PII-shaped prop key (email/phone/name/token/…) rejects the
  whole event, so this can never become a data hole. (2) The landing emitter is
  cookieless: a per-session anon id in sessionStorage (not a cookie, no cross-site
  id), honors Do Not Track, uses sendBeacon (non-blocking) — so a page that
  promises no tracking keeps that promise. (3) Storage = logEvent (structured logs,
  greppable at single-node launch scale); a queryable funnel_events table is a
  scale-up follow-up, not built now (YAGNI). (4) No third-party analytics (GA/etc.)
  — that was already deferred as cookieless-only in D19.
- Revisit: M15b wires the mac client emitters; a funnel_events table + aggregation
  when the log-grep approach stops scaling.

## D24 — Mac client funnel emitters (M15b) (2026-07-12)
- Goal: complete the funnel from the app side with the same privacy stance as the
  landing emitter (D23).
- Decisions: (1) FunnelTracker mirrors the landing: anonymous device id
  (Config.deviceId, not an account), no PII, fire-and-forget (telemetry never
  surfaces an error). (2) A user opt-out (Config.funnelOptOut) gates all emission —
  the mac equivalent of the landing's Do-Not-Track honoring. (3) first_recording /
  first_ai_action use trackOnce (once-per-device activation), others recur. (4)
  subscribe_success fires from pollActivation ONLY after the plan is confirmed
  active (honest — not on checkout-opened); checkout_start is the initiation event.
- Revisit: IAP-path subscribe_success (StoreKitPurchaser) + a Settings UI toggle
  for funnelOptOut (flag exists; a visible control is a small follow-up).

## D25 — Durable cost telemetry via a per-feature ledger + costMeter sink (M7c-2) (2026-07-12)
- Goal: make provider spend survive restarts (the in-process costMeter resets),
  serving the cost non-negotiable's "telemetry" requirement.
- Options: (a) roadmap sketch — ALTER llm_usage ADD tokens/cost columns, per-USER,
  updated post-call; (b) dedicated per-FEATURE llm_cost_frames table via a sink.
- Chose (b). Why: the token counts live inside the pure LLM fns (generateSuggestions/
  generateClaims) while the userId lives up in the route handler — joining them
  (option a) needs id-threading through 3 layers, the exact invasiveness that got
  M7c-2 deferred. A per-feature table records at the existing costMeter.record()
  seam with ZERO handler plumbing, AND is more privacy-respecting (no per-user cost
  PII; per-user usage is already durable via llm_usage compute credits). costMeter
  stays a pure in-process module — persistence is an injected sink (setSink), wired
  once at bootstrap, fire-and-forget so it never blocks/breaks the LLM response.
- Revisit: if per-user $ attribution is ever needed (abuse forensics beyond the
  credit cap), thread a reservation id through and add the columns then.

## D26 — mac catalog hydration from the backend (M6b) (2026-07-13)
- Goal: kill the hand-synced drift between the mac LLMCatalog and the backend
  models.js (the single source of truth), the last M6 item — deferred as "invasive".
- Decision: minimal-surface hydration. Renamed the static table → `fallback`, made
  `LLMCatalog.all` a computed `hydrated ?? fallback`. Because every call site reads
  `all`, the whole app follows the backend with NO per-site edits — that's what
  made the "invasive" refactor bounded. The endpoint carries id/provider/minTier/
  supportsVision but no label, so mapping keeps the static label for known ids and
  uses the id as the label for a model this build doesn't recognize (honest, still
  selectable). Unmappable provider/tier entries are dropped; an empty mapped set is
  ignored so a bad response can't blank the picker; hydrate() is best-effort so
  offline keeps the fallback. Wired once at launch.
- Benefit beyond drift: a shipped Mac app learns new backend models without an app
  update (the catalog is fetched at each launch).
- Test isolation: hydration mutates a shared static; tests reset via resetHydration()
  (also a legitimate "revert to offline" method). Cross-suite windows are tiny +
  reset; full suite stable across runs.
- Revisit: if the endpoint ever carries labels/pricing, map them too.

## D27 — Telemetry opt-out UI + IAP funnel event (M15b-2) (2026-07-13)
- Goal: close the privacy gap of shipping funnel telemetry (D23/D24) with no
  user-visible off switch — inconsistent with the cookieless/no-tracking posture.
- Decisions: (1) Settings → Account & Privacy gains a "Share anonymous usage data"
  toggle bound to Config.funnelOptOut (inverted), with a caption stating exactly
  what's sent (anonymous, cookieless, no account/content/cross-app) and that off =
  nothing. (2) IAP purchases now emit subscribe_success too (StoreKitPurchaser
  activated case, props via:iap), matching the Stripe web path — the funnel is now
  complete across both purchase channels.
- Revisit: none; this completes the funnel + its privacy control.

## D28 — Keychain hardening: fail-soft reads, self-healing writes (2026-07-13, from incident)
- Trigger: a user hit an un-passable "Cruxwing wants to access ai.wheespr.meetgpt"
  login-keychain prompt — a legacy generic-password item's per-signature ACL didn't
  match a rebuild's signature (regenerated dev cert / ad-hoc), locking them out.
  Fixed operationally (deleted the stale item); this is the code hardening so it
  can never lock a user out again.
- Decision: SystemKeychain get/set now pass an LAContext with interactionNotAllowed
  (kSecUseAuthenticationContext — Apple's non-deprecated replacement for
  kSecUseAuthenticationUIFail). A cross-signature access FAILS SOFT (no modal): get
  returns nil → app treats it as no-session → re-auth; set replaces the stale item
  so the current app owns a fresh one. Happy path (matching ACL) unchanged.
- Verified: real-keychain smoke test — same-signature round-trip works WITH the
  flag; swift test 339 green. Cross-signature fail-soft path needs a device to
  exercise end-to-end. Sandboxed/MAS builds don't hit this (keychain per-app).

## D29 — AI-UX features + closed a cost-telemetry gap on the generic chat path (2026-07-13, user-requested)
- User asked for: a live "thinking process" for prompt runs + follow-up suggestion
  buttons + a workflow for free-text prompts. A parallel-exploration workflow mapped
  the pipeline first.
- Shipped: (1) ThinkingPanel — a collapsible step panel above the answer, DERIVED
  from the existing aiStage/aiStreaming transitions via property observers (zero
  changes to the ~10 stage sites, NO extra LLM cost — the app's real synthesized
  workflow steps, not fabricated reasoning). Added one "Composing…" stage so
  free-text prompts also show a step. (2) Follow-up buttons already existed
  end-to-end (FollowUpService, fast-model epilogue) — verified, not rebuilt.
- COST NON-NEGOTIABLE audit of the (now-prominent) follow-up + main chat LLM
  surface: tier ✅ (fastAudit), cache-story ✅ (follow-up input is unique per
  answer → no cache benefit; honest N/A), telemetry ❌ — the generic /api/llm/chat
  handler (9 text buttons + custom prompts + follow-ups in backend mode, the
  LARGEST LLM surface) reserved compute credits but recorded NO USD cost frame, so
  the durable cost frames (M7c-2) under-reported spend. CLOSED: llmChatHandler now
  records an estimated-token costMeter frame (feature:'chat') at stream completion,
  best-effort, mirroring the orchestrate path. estimateTokens moved to costMeter.js
  (DB-free, shared, unit-tested). Chose synthesized workflow steps over streaming
  REAL model reasoning tokens (bigger change: per-provider parsing + backend SSE) —
  offered as a follow-up.
- Also this session: Clear-all History button (confirmed); keychain fail-soft (D28).

## D30 — Dev-build direct mode + mic voice-processing default off (2026-07-13, from user reports)
- Triggers (dev build with baked keys, no backend deployed): brainstorm threw
  "hostname could not be found" (the app defaults backendBaseURL to the undeployed
  api.cruxwing.com); and system output ducked + transcript stalled after recording.
- Decisions: (1) BACKEND_URL=off|none|direct|local → Config.backendBaseURL resolves
  to "" so a dev build uses baked provider keys DIRECTLY (no backend dial). The
  hardcoded api.cruxwing.com default stays for normal builds (keeps sign-in/plans).
  OrchestrateService.stream gained an injectable baseURL (tests + parity with the
  other services). (2) micNoiseSuppressionEnabled default flipped ON→OFF: Apple's
  voice-processing unit ducks system output (macOS treats it as a call) and its AGC
  can push the mic below the VAD gate — both surprised the user. TRADEOFF: with it
  off, a non-headphone (speaker) user's mic may pick up the remote side as echo —
  but the remote side is already captured cleanly via ScreenCaptureKit, so most
  setups are fine; Settings → Microphone re-enables it. REVISIT if echo on speaker
  setups proves worse than the ducking.
- Test note: a few ViewInspector tests (Sidebar/PromptBudgetBar) assume a non-empty
  backendBaseURL, so they only fail under a local BACKEND_URL=off; CI (default
  backend) stays green (343). Not worth a Config-injection refactor for a
  dev-only config — the shipping build always has a real backend URL.

## D31 — Supersedes D30's mic decision: keep "Reduce noise & echo" ON, disable ducking (2026-07-13, user correction)
- User: the feature should REDUCE noise/echo, not make the call quiet — so turning
  it off (D30) was wrong. The quieting is a SEPARATE side effect (output ducking),
  not the noise reduction itself.
- Fix: default flipped back ON. In MicrophoneCapture, after
  setVoiceProcessingEnabled(true), set voiceProcessingOtherAudioDuckingConfiguration
  (enableAdvancedDucking:false, duckingLevel:.min) on macOS 14+ — echo cancellation
  + noise suppression stay active, but system output no longer ducks. On macOS 13
  (no API) the ducking remains; the toggle still lets the user disable it entirely.
- Verified: builds; MicNoiseSuppression test (default on) + Config tests green;
  app rebuilt. The AGC/VAD interaction, if it recurs, is a separate follow-up.

## D32 — Supersedes D31: mic voice-processing OFF by default (it broke transcription) (2026-07-13)
- After D31 (keep it ON, disable ducking via the macOS-14 config), the user reported
  BOTH the output ducking AND an empty transcript ("listening, no transcript") still
  occurring. Diagnosis: dispatchTranscription shows transcribe() returns EMPTY for
  every chunk (state → .ready, empty → silent return) — i.e. the mic audio reaching
  WhisperKit is effectively silent. Apple's voice-processing unit (a) ducks system
  output and (b) its noise gate/AGC attenuates the mic enough to empty on-device
  transcription; the macOS-14 ducking config doesn't take on all hardware.
- Decision: default micNoiseSuppressionEnabled OFF. The transcript is the core
  feature — a nice-to-have (echo cancellation) that breaks it can't be default-on.
  The remote side is captured cleanly via ScreenCaptureKit regardless. Toggle stays
  in Settings for setups that need echo cancellation AND still transcribe. Kept the
  ducking config for when it IS enabled.
- Verified: builds; mic test (default off); app rebuilt; no stored override for the
  user. Runtime transcript confirmation is the user's to make (needs live speech).

## D33 — Supersedes D30-D32: voice processing fixed for real (root causes found) (2026-07-14)
- User insisted VP must WORK ("voice processing is crucial, fix the issue with it"),
  not be disabled. Ran a 3-agent research+audit pass. Root causes found:
  1. VP silently inflates the mic node output to MULTI-CHANNEL deinterleaved
     (3/7/9ch; only ch0 carries the processed voice — Apple forums #710151,
     undocumented). Our AVAudioConverter downmixed ALL channels, diluting speech
     10–19 dB, which then died at the −42 dBFS VAD gate → empty transcript.
  2. VP additionally attenuates non-near-field audio by design; the −42 dBFS VAD
     gate is too strict for VP output even post-fix.
  3. Ducking: duckingLevel .min is the FLOOR, not "off" — macOS has NO zero-duck
     API (WWDC23 10235; enum has no off value), plus an inherent output gain
     change Apple engineers confirm is expected (forums #733733). The legacy AU
     property fallback (kAUVoiceIOProperty_DuckNonVoiceAudio) is
     API_UNAVAILABLE(macos) — never an option.
  4. Latent bugs: the 0-Hz fallback re-tapped with the pre-VP input format
     (reintroducing the silent-buffer bug), and a failed AVAudioConverter creation
     was cached forever (permanent silent audio drop).
- Decision: VP default ON but ROUTE-AWARE — enabled only when it buys something:
  speakers (echo path exists). Skipped for headphones (3.5mm 'hdpn' data source,
  Bluetooth, AirPlay) and aggregate inputs (VP scrambles them) — those routes get
  raw mic, zero ducking, zero gain loss. This mirrors why Meet/Zoom never duck:
  they don't use VPIO at all (software AEC). Fixes: channel-0 extraction for >2ch
  buffers; VAD gate 0.0025 (−52 dBFS) for VP'd mic; tap installed AFTER engine
  start with format:nil; converter failure retries + logs; route-change restart
  re-evaluates VP. All diagnostics now at .notice/.error (macOS persists those,
  unlike .info) — heartbeat counters per chunker (in/emitted/vadGated/convertFail).
- Honest residual: on speakers, SOME system-audio attenuation while recording is
  Apple-inherent (no API to remove); .min minimizes it. Headphones now fully avoid it.
- Verified: 17 audio/pipeline tests green incl. new 3ch/9ch channel-0 extraction
  proofs + VP-gate threshold test; full suite 341/345 (4 pre-existing env-coupled
  ViewInspector failures, confirmed identical at HEAD); app rebuilt + installed.

## D34 — Post-call speaker labels stay BYO-key for MVP; no AssemblyAI proxy now (2026-07-24)

- Goal: close the last credit-economy gap — AssemblyAI post-call diarization is
  the only transcription route a keyless dist build cannot reach (Deepgram got
  its token-grant lane the same day; the assemblyai rate of 80 chunks/credit
  and POST /api/transcription/usage are already live).
- Options considered:
  1. Slim AssemblyAI proxy (~half day): stream-pipe the recording through the
     backend (their batch API has NO temp-token equivalent — the key can never
     reach the client), create the job with speaker_labels, proxy the poll.
     Cost: a 1 h call is ~115 MB mono-16k WAV (needs client-side AAC encode or
     chunked pipe past the 25 MB transcribe cap), double bandwidth through our
     VPS, an async job broker, and deeper investment in a vendor we already
     plan to replace.
  2. WhisperX self-hosted diarization (2–3 days + infra): same faster-whisper
     core we already run, kills the vendor bill, cheapest rate for users. But
     pyannote on a CPU VPS runs ~0.5–1× realtime — a 60-min call could take
     30–60 min, unusable UX — so it honestly needs a GPU box (~$100+/mo or
     spot), unjustified pre-revenue.
  3. Defer: keep the feature BYO-key + opt-in (its exact state today —
     hasAssemblyAI && assemblyAIDiarizationEnabled, default off), mark the
     landing rate "(early access)".
- Decision: DEFER (option 3). Keyless users who need who-said-what now have
  Deepgram Live + speakers from the same credit pool — the demographic the
  labels serve is covered live, which is worth more in-meeting than post-call.
  The economy rails stay in place, so either build slots in without schema or
  pricing changes.
- Revisit after launch: if support requests ask for post-call labels on
  on-device recordings, build the slim proxy first (results in minutes, known
  quality) and move to WhisperX-on-GPU only when the AssemblyAI bill outgrows
  a GPU rental — record the crossover math in the next COST PASS.
- Verified: landing + Lovable prompt carry the "(early access)" marker; the
  landingPricing test pins it against TRANSCRIPTION_CHUNK_RATES.

## D35 — Privacy · Accuracy · Speed · Price is the canonical transcription frame (2026-07-24)

- Goal: businesses evaluate transcription on four concerns — privacy (where
  does audio go), accuracy (how good are the words), speed (how fast do
  captions land), price (what does it draw from credits). Engine-first naming
  (vendor names, model numbers, chunk rates) buries those answers.
- Decision: transcription is presented as EXACTLY THREE OPTIONS, each named by
  the axis it wins and each stating all four axes explicitly, everywhere the
  choice appears (mac Settings picker captions, landing pricing strip, future
  onboarding):
  1. Private · on-device — audio never leaves the Mac; solid accuracy sized
     to the chip; near-live; free, no credits.
  2. Accurate · Cruxwing servers — our servers only, no third-party AI
     vendor, audio discarded after transcription; best accuracy (large-v3 +
     per-language leaders); near-live at server pace; ≈10 min per credit.
  3. Instant · Deepgram Live + speakers — streamed to Deepgram's cloud;
     excellent accuracy with who-said-what; word-by-word; ≈4 min of streamed
     audio per credit (a call streams two tracks).
- NOT options (kept out of the trio deliberately): the OpenAI whisper-1
  bridge is server-side routing (a footnote rate, ≈6 min per credit, never a
  user choice); post-call speaker labels are an early-access BYO add-on
  toggle (D34); the BYO Whisper API engine remains a power-user row in
  Settings outside the frame ("your key, your bill").
- Every option keeps the same cap story: cloud engines pause, the app
  continues on-device — enforced in code (ServerFallbackTranscription,
  degradeLiveStreamToLocal), not just copy.
- Verified: ConfigTests pins all four captions and asserts every caption
  covers privacy + price; landingPricing pins the three
  data-transcription-option cards, the four bolded axis names, the frame
  lead line, and that transcription is never sold as a pack. swift test
  512/512; landing suites 30/30.

## D36 — OpenRouter adopted as the long-tail lane, hybrid, by attrition (2026-07-24)

- Goal: 8 vendor accounts/keys/consoles for the model catalog is real
  operational drag (the DashScope intl-vs-CN console confusion was the
  trigger); OpenRouter offers one key + provider-level failover for ~5% fee.
- Decision: HYBRID, not migration. A new `openrouter` OPENAI_DIALECT entry +
  a pure routing module (functions/openRouterRouting.js) reroute providers
  listed in OPENROUTER_TAKEOVER through OpenRouter with author-mapped slugs
  (zhipu→z-ai, moonshot→moonshotai). Eligible: deepseek, qwen, zhipu,
  moonshot, google. NOT eligible, enforced in code: openai + anthropic
  (default tiers stay direct — native prompt caching, lowest latency, no
  single point of failure on 90% of traffic) and enterprise (prompts must
  never transit any third party).
- Rollout is attrition, not an event: each long-tail vendor stays direct
  until its prepaid balance runs dry, then its name is added to
  OPENROUTER_TAKEOVER in the env and that vendor account is never topped up
  again. No code or catalog change per flip. OpenRouter funded ~$10 at
  wiring time only.
- Privacy pin: every OpenRouter request carries
  `provider: { data_collection: "deny" }` — routing may only choose hosts
  that do not train on prompts. Fail-safe: without OPENROUTER_API_KEY the
  takeover list is ignored and direct lanes keep working.
- Invariants: credits, tier gates, and cost telemetry stay keyed on the
  CATALOG model id — only the wire call sees the OpenRouter slug. The mac
  UI keeps vendor naming (model authorship is unchanged; only the transport
  path differs).
- Verified: 6 routing unit tests (eligibility allowlist, slug authorship,
  fail-safe, tolerant parsing, takeover routing incl. defaults-can-never-flip).
