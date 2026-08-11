# Launch loop state

Milestones from docs/mas-launch-loop-prompt.md ROADMAP. Protocol: first
unchecked milestone wins; split oversized ones; after M7, insert `[ ] COST
PASS #n` every two completed milestones.

- [ ] M1 — Rotate secrets & production-true backend
  - [x] M1a — CODE: /health, JWT prod fail-fast (+`\n`-escaped PEMs), STUB_OAUTH prod assert, env example, deploy.md drift, delete .env.swp
  - [ ] M1b — [BLOCKED: human console access] Execute SECRET_ROTATION_PLAN.md P1+P2 key rotation (provider consoles; per docs/dispatch-keys-runbook.md a human confirms each secret)
- [ ] M2 — Entitlement & billing correctness
  - [x] M2a — resolveTier await + metadata-tier mapping + tests
  - [x] M2b — quota enforcement (llm_usage) + brainstorm/factcheck auth+metering + guidance neutralization
  - [x] M2c — webhook lifecycle (subscription.deleted, payment_failed) + expires_at guard
  - [x] M2d — client tier truth: PaywallAPI.refreshEntitlement() at launch (signed-in downgrade/upgrade; offline keeps cache)
- [ ] M3 — First-run that converts
  - [x] M3a — paywall never before first value moment + never without a backend
  - [x] M3b — user-facing .env language purged (8 strings)
  - [x] M3c — session persistence: SessionStore + auto-save on stop/post-call AI + sidebar History restore
  - [x] M3d — onboarding pre-flight (OnboardingView: live mic + Screen Recording asks, on-device model warm-up, relaunch callout; Config.onboardingCompleted gate in ContentView)
  - [x] M3e-1 — council honesty (panels require direct keys; keyless builds hide/skip Council)
  - [x] M3e-2 — DIST builds default BACKEND_URL to the production API
  - [x] M3e-3 — Decision Ledger read view in the sidebar
  - [x] M3e-4 — M2d client tier truth from GET /me (see M2d)
- [x] M4 — Transcription fidelity (glossary + hardware-tiered model + mic voice processing + diarization speaker hint)
  - [x] M4a — per-team glossary end-to-end: Config.transcriptionGlossary + Glossary parser + Settings "Custom vocabulary" editor, threaded into ALL engines (Deepgram keyterm, AssemblyAI word_boost, Whisper API prompt, WhisperKit promptTokens via tokenizer)
  - [x] M4b — hardware-tiered local default + Settings model picker (base/small/large-v3; Apple Silicon→small, Intel→base; user choice persists). D4: turbo deferred (WhisperKit variant-name resolution).
  - [x] M4c — VoiceProcessingIO on the mic path (echo cancellation + noise suppression + AGC via setVoiceProcessingEnabled; Config.micNoiseSuppressionEnabled toggle in Settings, best-effort fallback to raw mic)
  - [x] M4d — speakersExpected from calendar attendees into diarizeSession (excludes self, clamps 1–10; CalendarAgenda.attendeeCount). Optional glossary auto-derivation deferred (not blocking).
- [ ] M5 — Integration scope
  - [x] M5a — write-back SERVICE: MCP/TaskWriteback.swift — schema-driven task→create-tool mapping (Linear/Jira/Asana), tool discovery (per-server pref + fuzzy), metadata→description folding, MCPConnectionManager.createTrackerItem + writebackTargets. Live call unverified (manual E2E needs a connected tracker + M5b confirm UI).
  - [x] M5b — write-back confirm UI: TaskWritebackSheet (tracker picker from writebackTargets, per-task File with verbatim result/error, connect-hint empty state), opened from a 'Send to tracker' header button in AIStudioView when the last artifact is Tasks. Live create needs a connected tracker (manual E2E, M5d); schema-driven required-id prompting (Linear teamId) deferred to M5b-2.
  - [BLOCKED: human — Slack app registration] M5c — Slack in-app OAuth + channel picker. Needs a human to create a Slack app (api.slack.com/apps), set the OAuth redirect URL, request scopes (channels:history, search:read), and supply SLACK_CLIENT_ID/SLACK_CLIENT_SECRET server-side. The env-token TeamConnectors.slack path keeps working as the self-host fallback meanwhile. See D5.
  - [MANUAL] M5d — verify hosted-MCP E2E + write-back create against a live tracker (needs connected accounts; not autonomously verifiable)
- [ ] M6 — Data strategy / prompt caching
  - [x] M6a — GET /api/llm/models: backend single-source model catalog (id/provider/minTier/supportsVision, weak→strong order, public + day-cached) served from the MODELS map; kills the hand-synced drift with the mac LLMCatalog
  - [x] M6b — mac LLMCatalog hydrates from /api/llm/models. Minimal-surface design:
    renamed the static table → `fallback`, made `all` a computed `hydrated ?? fallback`
    so EVERY call site follows the backend with zero per-site change. models(from:)
    maps backend entries → LLMModel (known id keeps its polished label; unknown id
    uses the id; unmappable provider/tier dropped; order preserved). applyHydration
    ignores an empty map (never blanks the picker); hydrate() is best-effort (offline
    → fallback). Wired at launch (MeetGPTApp). Kills the hand-synced client/backend
    catalog drift + lets a shipped app learn new models without an update. D26. 6
    tests (mapping/drop/apply/online/offline/fallback-complete).
  - [x] M6c — Anthropic prompt caching: streamAnthropic sends the system prompt as a cache_control:ephemeral content block (anthropicSystemBlocks), so the stable base+skill-layer prefix is reused across skilled-button presses instead of re-billed. brainstorm/factcheck (OpenAI) already put the stable system first (OpenAI auto-caches prefixes).
  - [x] M6d — digest spine test (early decision recoverable in a BOUNDED prompt across a long call — 2×+ smaller than full, decision preserved via the digest; existing DigestPromptTests already covered activation). Server-side grounding cache: N/A — grounding is client-side (120s AppState.groundingCache); see D6.
- [ ] M7 — COST ENGINE v1 (then recurring COST PASS)
  - [x] M7a — BackgroundLLMQueue actor (AI/BackgroundLLMQueue.swift): the shared
    cost gate for the 5 background watch loops (brainstorm/agenda/factcheck/
    rhetoric/facilitation). Coalesce (skip when transcript entry-count unchanged),
    single-flight per key, and global backpressure (maxConcurrent 2) so aligned
    timers can't stack paid calls. Replaced each loop's private lastXEntryCount
    bookkeeping; ADDED coalescing to brainstorm/agenda (they previously re-ran on
    an unchanged transcript). Gate design (reserve/finish), not a runner — the
    loops keep running their own work on @MainActor. reset() per meeting. D7.
  - [x] M7b — server responseCache.js (TTL LRU): generic TTL+LRU cache
    (stableStringify → sha256 key, injectable clock, hit/miss stats) wired into
    generateSuggestions + generateClaims BELOW the auth/meter middleware, so
    quota still counts per request but an identical re-poll skips the paid
    provider call. Keyed on the full request payload; a hit only returns output
    derivable from input the caller themselves supplied (no cross-user leak).
    60s TTL, env-overridable. D8.
  - [x] M7c-1 — costMeter.js: in-process cost telemetry. Pure per-1M-token
    pricing (gpt-4o-mini exact, documented default fallback, LLM_MODEL_PRICING
    env override), createCostMeter with rolling UTC-daily total + one-per-day
    budget alert (LLM_DAILY_BUDGET_USD) + stats()/byFeature. Shared meter wired
    into brainstorm+factcheck: each provider call records a frame from the real
    OpenAI usage tokens; cache hits record nothing ($0). Best-effort (never
    breaks the response). Rates are INTERNAL accounting, never user-facing. D9.
  - [x] M7c-2 — durable per-call cost telemetry. Shipped as a dedicated
    llm_cost_frames table (feature/model/prompt_tokens/completion_tokens/cost_usd)
    written best-effort via a costMeter SINK (setSink, wired at bootstrap;
    fire-and-forget — never blocks/breaks the response). costSummarySince() gives
    the durable per-feature spend the in-process meter loses on restart.
    DEVIATION from the sketch (columns-on-llm_usage, per-USER): the token counts
    live in the pure LLM fns while userId lives in the handler — joining them was
    the deferred invasiveness. A per-FEATURE table sidesteps it AND avoids per-user
    cost PII (per-user usage is already durable via llm_usage credits). D25. 6 tests
    (costMeter sink + DB frames/summary/window/clamp).
  - [x] M7d-1 — tier-cost invariant tests (LLMCatalogTests): catalog-complete
    guarantees that a mechanical pass NEVER escalates tier (fastAudit ≤ selected
    for every model + Auto), an actual downgrade always lands on the free tier,
    fastAudit preserves provider (direct-key safety), and is idempotent. All
    mechanical passes (rhetoric/facilitation/digest/goal/refine/follow-ups/
    grounding-query) route through fastAudit(for: Config.selectedModel) — grep-
    verified. Known limitation D10: non-OpenAI/Google premium models don't
    downgrade (no cheap same-provider entry); default Auto path IS cheap.
  - [DEFERRED — premature] M7d-2 — Postgres-backed rate limiter. Verified NOT to
    build now (2026-07-13): (1) rateLimiter.consume() is SYNCHRONOUS at ~9 call
    sites (auth × 8, llmGateway, promo, funnel, device-redeem); a DB-backed limiter
    is inherently async → an invasive sync→async refactor across all of them. (2) At
    single-node scale it REGRESSES perf — a DB write per rate-limited request vs the
    in-memory limiter (MAX_BUCKETS eviction) that works today. (3) Its only benefit
    (durable-across-restart / multi-node) isn't needed at single-node launch. This
    is a YAGNI call, not a gap. REVISIT when: scaling beyond one node, OR when
    deploy-time rate-limit resets become an observed abuse vector.
- [x] M7O — Orchestration councils (price-tiered ensembles; user-directed, D11).
  Cost-engine feature: N frontier models per request + chairman synthesis, so it
  ships with a tier gate + cache + N× telemetry or it doesn't ship.
  - [x] M7O-P1 — foundation: OrchestrationLevel (Free/Medium/Max/Ultra panels +
    chairman), Tier.ultra, claude-opus-5 in all catalogs, China council
    reversal. mac 318 / backend 227.
  - [x] M7O-P2 — Ultra billing tier: ultra-monthly/annual in PAYWALL_PLANS
    (placeholder price), purchase→ultra via the existing webhook tier-copy.
  - [x] M7O-P3 — backend ensemble endpoint (keyless launch can't run client-side
    panels). P3a/P3b/P3c all done (stale parent checkbox — corrected).
    - [x] P3a — ensemble.js primitive (fan-out + quorum + chairman synthesis,
      injectable callModel; ORCHESTRATION_LEVELS mirror + catalog parity). Also
      extracted functions/models.js (DB-free catalog).
    - [x] P3b — POST /api/orchestrate (auth + meterLlmFeature + in-handler tier
      gate + response cache + N× costMeter frames). DI factory
      createOrchestrateHandler so it's unit-tested with no DB/providers. Added
      llmGateway.callModel (consume a provider stream to full text). Cost story:
      tier-gated, cached, N+1 estimated-token frames.
    - [x] P3c — SSE streaming: the route now streams the chairman synthesis
      (Stage 2) token-by-token like /llm/chat; members fan out non-streamed
      (Stage 1). Split runPanel out of orchestrate; added llmGateway.streamModel;
      cache hits + errors-before-first-token still return cleanly. P3 complete.
  - [x] M7O-P4 — client wiring + paywall (P4a/P4b/P4c all done).
    - [x] P4a — OrchestrateService (POST /api/orchestrate, streams the SSE
      synthesis, maps the server 403 tier gate) + AutoOrchestrator routing:
      an `orchestrate:<level>` selection runs the backend council in backend mode
      (keyless launch) or the client EnsembleGateway with the level's panel in
      direct-key mode. URLProtocol-stubbed tests (deltas/[DONE], payload, 403,
      mid-stream error).
    - [x] P4b — model picker offers the tier-gated OrchestrationLevels (backend
      mode, strongest-first) + the re-enabled China council (direct-key builds);
      Config.selectedModelID now passes through orchestrate:<level> and council:cn
      (was coerced to Auto); selectedModel treats orchestrate: as an auto sentinel.
      Transparency notes for each council (incl. "content goes to China vendors").
    - [x] P4c — Ultra plan surfaced in the paywall. VERIFIED (not re-built): the
      backend publicPlans() serves ultra-monthly/annual with catalog priceCents
      (9900/99000); the mac PaywallView.selectablePlans renders ALL tiers for the
      interval (Ultra not filtered) with priceLabel derived from the API priceCents
      (never hardcoded). Locked with guard tests both sides — backend (tariffs
      publicPlans includes Ultra @ 9900) + mac (selectablePlans surfaces Ultra,
      priceLabel "$99/mo"). M7O now fully complete.
- [ ] M8 — Sandbox by default for distribution
  - [x] M8a — App Sandbox MANDATORY for dist builds: build.sh now signs with
    MeetGPT.sandbox.entitlements whenever MEETGPT_DIST=1 (or the opt-in
    MEETGPT_SANDBOX=1) — the non-sandbox profile can never ship. Fail-safe: aborts
    if the sandbox entitlements file is missing. MEETGPT_PRINT_ENT=1 hatch prints
    the resolved entitlements without a full build (verified: dev→non-sandbox,
    dist→sandbox+mandatory log, opt-in→sandbox). notarize.sh already sets
    MEETGPT_DIST, so notarized builds auto-sandbox.
  - [x] M8b — narrow the sandboxed capture surface: extracted
    SystemAudioCapture.makeStreamConfiguration() (audio-only, excludesCurrentProcessAudio,
    2×2 video, showsCursor off — we add only an .audio output so no frames are
    decoded) + a test locking the contract. Filter stays display-scoped BY DESIGN
    (a meeting plays through any app); app-scoping deferred as a fragile refinement.
  - [MANUAL] M8c — verify mic + ScreenCaptureKit system-audio + OAuth loopback +
    user-selected file import all work under the sandbox at runtime (device test;
    not autonomously verifiable — a dev build never runs sandboxed).
- [x] COST PASS #1 — audited every LLM surface: brainstorm/factcheck/orchestrate/
  llm-chat all reserve compute credits via reserveComputeCredits→reserveLlmUsage,
  which is ATOMIC (pg_advisory_xact_lock per user → SUM period → check → INSERT
  debit in one tx; the debit IS the durable telemetry in llm_usage.compute_credits)
  and correctly costed (tariffs.test: per-model/level credits + input surcharge).
  Tier gates present; caches present (brainstorm/factcheck/orchestrate response
  caches; cache hits still charge — intended, D8); fail-CLOSED on metering error.
  GAP FIXED: the charging middleware (meterLlmFeature) was inline in index.js and
  untested — extracted to auth/meterLlmFeature.js (DI) + 6 tests locking the tier
  gate / 429 over-budget / 503 fail-closed / usage-shape / unknown-level paths.
  No feature ships without a cost story; no silent caps found. D13.
- [x] M9 — Privacy manifest + Info.plist keys (PrivacyInfo.xcprivacy packaged; category + encryption keys; CFBundleVersion from git height)
- [ ] M10 — Consent & account deletion
  - [x] M10a — one-time recording consent gate (sheet + Config flag; recording blocked until affirmed)
  - [x] M10b — DELETE /auth/account endpoint (FK-cascade purge + token invalidation, tested)
  - [x] M10c-1 — recording indicator present: MenuBarView shows a live red
    StatusDot + "Recording" status + record/stop control while capturing (plus the
    OS's own mic/screen-recording indicators). Verified in code.
  - [x] M10c-2 — consent link targets /privacy AND /terms (both pages now exist,
    M13b). RecordingConsentSheet links cruxwing.com/privacy + /terms; pages go live
    with the M13c [HUMAN] deploy.
  - [x] M10d — "Delete account" in SettingsView: destructive confirmation dialog →
    AppState.deleteAccount() → DELETE /auth/account (Bearer) → on success
    signOutWheespr() + clear purchasedTier. This iteration: extracted the HTTP call
    to Integrations/AccountDeletion.swift (injectable session) so the App-Review-
    required flow is TESTED — 3 tests: 2xx→deleted+DELETE/Bearer/path assertions,
    non-2xx→failed(status), empty-base→failed-no-request.
- [ ] M11 — Launch decisions (RESOLVED by human, D14: name = Cruxwing, IAP =
  StoreKit 2).
  - [x] M11a — canonical name → Cruxwing: CFBundleDisplayName=Cruxwing + every
    user-facing "MeetGPT" string renamed across the mac Views (menu bar, sidebar,
    overlay, onboarding, settings, MCP, paywall). Internal target/CFBundleName/
    bundle id kept (com.meetgpt.macapp — revisit com.cruxwing.mac at M12).
  - [ ] M11b — StoreKit 2 IAP (multi-iteration; blocks the paywall purchase path).
    - [x] M11b-1 — product catalog contract: functions/storeKit.js maps every
      tariffs.js plan+add-on ↔ a StoreKit product id (com.cruxwing.sub.* /
      .pack.*), built DYNAMICALLY from tariffs (can't drift), productForId reverse
      lookup returns null for unknown (untrusted) transactions. Exposed
      storeKitProductId per item in GET /api/billing/plans (single source, no
      client hardcoding). 9 tests (coverage/format/uniqueness/round-trip + catalog).
    - [x] M11b-2 — receipt→entitlement bridge: POST /api/billing/storekit
      (authed) → verify (INJECTED, fail-closed default) → productForId → idempotent
      activation. New iap_transactions table (PK=transaction_id) +
      recordIapTransaction so a replayed transaction grants exactly once.
      Subscriptions activate the plan at its tier (source:'storekit', like the
      Stripe webhook); add-ons return an honest "not yet grantable" (no grant path
      exists for EITHER provider yet). 7 DB-backed tests (activate/idempotent-
      replay/unknown-product/add-on/malformed/missing/fail-closed-503). The real
      Apple JWS x5c verifier is M11b-2b (security-critical; needs Apple's Root CA
      + real fixtures) — until then the route rejects every transaction.
    - [x] M11b-2b — real Apple StoreKit JWS verifier: functions/appleReceiptVerifier.js
      wraps Apple's OFFICIAL App Store Server Library (SignedDataVerifier →
      verifyAndDecodeTransaction) — x5c chain to Apple Root CA + ES256 signature +
      bundle-id/environment checks (NOT hand-rolled crypto; a self-verified receipt
      = free-Ultra hole). Wired as storeKitBridge's DEFAULT verifier (replaced the
      always-throw stub). FAIL-CLOSED: library-absent OR APPLE_IAP_BUNDLE_ID /
      APPLE_ROOT_CA_DIR / (Production) APPLE_IAP_APP_APPLE_ID unset → 503, grants
      nothing. 12 pure unit tests (stub library): ctor wiring, prod-vs-sandbox
      app-id gate, 4 fail-closed misconfigs, generic-400 on verify-throw (no crypto
      leak), missing-field + bundle-mismatch rejection, empty-input short-circuit.
      Config documented in deploy/api/.env.production.example.
    - [MANUAL] M11b-2b-verify — E2E against a StoreKit sandbox-signed transaction
      (needs `npm i @apple/app-store-server-library`, Apple Root CAs in
      APPLE_ROOT_CA_DIR, a sandbox purchase → real JWS). The library's crypto is
      Apple's to warrant; only this last real-signature check isn't autonomous.
    - [x] M11b-3 — mac client: split into the verified network seam (3a, tested)
      and the StoreKit-native purchase primitives (3b, device-tested).
      - [x] M11b-3a — StoreKitBridge.submit: POST the SIGNED transaction (JWS) to
        /api/billing/storekit (Bearer), parse the server's decision →
        .activated(tier,planId,idempotent) / .notGrantable (add-ons) / .failed.
        Never grants on the client's word — the server owns verification; this
        only reports what the server decided. 9 unit tests (URLProtocol-stubbed,
        mirrors AccountDeletion): activate + idempotent replay + add-on +
        verification-fail + fail-closed-503 + malformed-200-never-fabricates +
        empty jws/token/base short-circuits.
      - [x] M11b-3b — StoreKitPurchaser (import StoreKit; DEVICE-tested, like M8c):
        products(for:) fetches Apple-priced products by catalog id; purchase()
        runs the sheet → verified Transaction → submit JWS → finish() ONLY after
        the server durably records it (transient submit failure left unfinished);
        syncUnfinished() drains Transaction.unfinished at launch (ask-to-buy /
        renewals / retried submits). Unverified transactions never trusted, never
        finished. Compiles; StoreKit-native calls need real ASC products + a
        sandbox tester (M11b-4). Paywall wiring is a later slice.
    - [HUMAN] M11b-4 — create the products in App Store Connect (matching the
      storeKit.js ids) — needs the Apple account.
- [x] COST PASS #2 — recurrence (M10 + M11 = 2 milestones since #1). Cost engine
  GREEN (45/45 regression across tariffs/meterLlmFeature/billing.tier/responseCache/
  costMeter). No new LLM feature since #1 (M8/M10/M11 are sandbox/consent/billing/
  naming) — tier+cache+telemetry guarantees intact. NEW payment surface audited:
  the StoreKit bridge feeds the cost quota correctly — an IAP-activated subscription
  carries the tier's compute-credit allowances (getUserPlan derives via
  TARIFF_ALLOWANCES[tier]), so App Store customers are metered exactly as Stripe
  ones. Gap CLOSED: added the allowances assertion to the bridge test (was tier-only).
  No silent caps. D11-era councils unchanged.
- [ ] M12 — MAS signing/packaging/upload
  - [x] M12a — appstore.sh MAS lane + fail-safe secret gate. appstore.sh mirrors
    notarize.sh but for the store: Apple Distribution app signing (not Developer
    ID), embedded provisioning profile, productbuild .pkg signed with the Mac
    Installer identity, no hardened runtime (App Sandbox instead). Reuses build.sh
    (MEETGPT_DIST=1 → keyless + mandatory sandbox). assert-no-baked-secrets.sh is
    the M12 "SECRET_VARS empty or abort" gate — scans the SHIPPED Mach-O binary
    for provider/org key shapes (OpenAI/Anthropic/Google/Slack/bearer), redacts
    matches, aborts the lane before productbuild/upload. Pre-flight fails fast on
    missing Apple creds (never a half-signed pkg); MAS_DRY_RUN=1 runs build+gate
    without creds. D16. VERIFIED live: gate refuses the current dev build (keys
    baked) + all 4 provider shapes, passes clean input; pre-flight aborts with no
    profile (no build started); bash -n clean on both scripts.
  - [HUMAN] M12b — Apple Distribution + Mac Installer certs, a MAS provisioning
    profile, and Transporter/altool upload (paid Apple account). Also the
    PERMANENT bundle-id call: confirm com.meetgpt.macapp vs com.cruxwing.mac in
    Support/Info.plist BEFORE first submission (D14/D16 — surfaced, not decided).
- [ ] M13 — Landing → install funnel
  - [x] M13a — bring web/landing under version control + reconcile pricing/honesty.
    Committed web/landing (index.html + assets + hubspot.js placeholders-only +
    briefs; .DS_Store gitignored). Audited for the honesty non-negotiable: SOC 2 is
    framed "readiness, not certification" with an explicit disclaimer (compliant);
    only Cruxwing's own logo; no fabricated metrics/testimonials. Consumer tier
    prices ($0/$19/$49/$99) + shown add-on prices MATCH tariffs.js; landingPricing
    test now DERIVES expected prices from the billing catalog (TARIFF_PLANS/ADD_ONS)
    so a price change forces a landing update instead of silent drift. Live
    hydration hook → /api/billing/plans already present. D17. Team pilot ($29
    target, "rolling out") + Enterprise ("from $15k, custom") are honestly framed
    as not-shipped and sit OUTSIDE the consumer billing API (can't be reconciled —
    a human product call on whether to keep aspirational team pricing pre-launch).
  - [x] M13b — /privacy /terms /security pages. Three on-brand static pages
    (shared legal.css matching the landing's dark system) with content ACCURATE to
    what the app does: privacy mirrors the App Store manifest (on-device default,
    no tracking, no data brokers, account deletion, honest sub-processor list);
    terms puts recording-consent responsibility on the user + discloses Apple/
    Stripe billing; security describes real posture (keyless client, pinned TLS,
    team isolation, App Sandbox) and frames SOC 2 as "readiness, NOT certification".
    All flagged pending-legal-review; no fabricated certifications. Added /terms to
    the landing footer + the in-app consent sheet. 13 tests lock the honesty
    properties. D18. Unblocked M10c-2.
  - [x] M13c-1 — SEO (autonomous): robots.txt (allow + sitemap), sitemap.xml (/,
    /privacy, /terms, /security — valid XML), per-page rel=canonical on all 4
    pages, og:url + robots meta on the landing, and honest JSON-LD
    (SoftwareApplication, macOS) — NO aggregateRating/reviews (none to cite), and
    the only price is the genuinely-free $0 tier so structured data can't drift
    from the catalog. 9 tests lock it. D19.
  - [HUMAN] M13c-2 — HubSpot portal id/form guid (placeholder-only today);
    analytics (must be COOKIELESS to honor the privacy policy's no-tracking claim
    — Plausible/Fathom-style, not GA); deploy to a static host with clean-URL
    routing so /privacy /terms /security resolve. Reconcile pricing display before
    launch (live hydration already wired).
- [x] COST PASS #3 — recurrence (M12 + M13 = 2 milestones since #2). Cost engine
  GREEN (45/45 regression: tariffs/meterLlmFeature/billing.tier/responseCache/
  costMeter). Audited every source file changed since #2 (storeKitBridge,
  appleReceiptVerifier, StoreKitBridge.swift, StoreKitPurchaser.swift,
  RecordingConsentSheet.swift): grep for openai/anthropic/deepgram/gpt-/claude-/
  chat-completions/recordLlmUsage/reserveLlmUsage/orchestrate → ZERO hits. The
  M11b/M12/M13 slices are IAP + packaging + static landing/legal/SEO — NO new LLM
  call or metered path. /billing/storekit is an authed billing route, not an LLM
  route. IAP reinforces the cost story (COST PASS #2 locked IAP subscribers to the
  tier's compute-credit allowances). tier+cache+telemetry guarantees intact. No
  action. Next COST PASS #4 after two more milestones (M14 + M15).
- [ ] M14 — MAS listing & ASO + review readiness
  - [x] M14a — App Store listing copy + ASO metadata: launch/app-store-listing.md
    is the source of truth (name/subtitle/promo/keywords/description in parseable
    asc-* blocks + category/URLs/copyright). appStoreListing test enforces Apple's
    HARD field limits (name≤30, subtitle≤30, promo≤170, keywords≤100, desc≤4000 —
    actuals 8/28/168/90/1857) + honesty (no "certified", no fabricated ratings/
    counts, NO hardcoded prices — names the tiers, live prices in-app). D20.
  - [x] M14b — App Review readiness map: launch/app-review-readiness.md maps each
    review guideline → shipped evidence (VERIFIED against code, not asserted):
    sandbox/keyless (build.sh + assert-no-baked-secrets), privacy manifest +
    policy, 5.1.1(v) in-app account deletion, IAP (StoreKit + fail-closed verifier,
    products=HUMAN), consent sheet, export-compliance. 5.1.2 DETERMINED not
    triggered — primary auth is first-party (email OTP/password/phone); "Sign in
    with Google" is a Calendar connector, not login. Reviewer notes call out the
    email+password demo account (OTP can't be reviewed) + on-device model. Fixed
    the user-facing Info.plist permission strings MeetGPT→Cruxwing + added
    copyright. 24 tests: every cited path exists (anti-drift) + plist keys +
    honesty. D21.
  - [HUMAN] M14c — paste into App Store Connect + screenshots/app preview +
    trademark check on "co-pilot" + confirm the permanent bundle id + submit.
- [ ] M15 — Launch channels & funnel metrics
  - [x] M15a — first-party COOKIELESS funnel telemetry. functions/funnel.js: a
    fixed stage taxonomy (landing_view → cta_click → download → app_open →
    onboarding → first_recording → first_ai_action → paywall_view → checkout →
    subscribe_success / promo_redeem); POST /api/funnel (public, rate-limited,
    records via logEvent). Rejects unknown stages + any PII-shaped prop key (never
    a data hole). Landing emitter (landing_view + cta_click) is cookieless
    (sessionStorage, DNT-respecting, sendBeacon) → consistent with the privacy
    policy's no-tracking claim. 22 tests (taxonomy/PII-reject/sanitize + landing
    emitter). D23. Storage is logEvent (KISS); a queryable funnel_events table is
    a scale-up follow-up.
  - [x] M15b — mac client funnel emitters. FunnelTracker (cookieless, anonymous
    Config.deviceId, fire-and-forget, Config.funnelOptOut honored) → /api/funnel.
    Wired 7 honest stages: app_open (MeetGPTApp), first_recording + first_ai_action
    (AppState, once-per-device via trackOnce), paywall_view (onAppear),
    checkout_start (startCheckout), subscribe_success (pollActivation — fires only
    after the plan is confirmed active), promo_redeem (redeem success). 3
    URLProtocol-stubbed tests. D24.
  - [x] M15b-2 — closed the two loose ends: IAP-path subscribe_success funnel
    event (StoreKitPurchaser activated case, props via:iap) + a user-visible
    telemetry OPT-OUT toggle in Settings → Account & Privacy ("Share anonymous
    usage data", bound to Config.funnelOptOut). Closes the privacy gap of shipping
    telemetry with no off switch — consistent with the cookieless/no-tracking
    posture. D27.
  - [HUMAN] M15c — actual launch channels: post/outreach, campaign content,
    schedule. Funnel metrics now capture the results honestly (no fabricated numbers).
- [x] COST PASS #4 — recurrence (M14 + M15 = 2 milestones since #3). Cost engine
  GREEN (45/45 regression). Audited the 2 new source surfaces since #3
  (deviceRedeem.js, funnel.js): grep for openai/anthropic/deepgram/gpt-/claude-/
  chat-completions/orchestrate → ZERO. funnel.js is event logging (no provider
  call). The ONE cost-relevant surface — device-redeem grants the Founder (Ultra)
  plan without payment — is BOUNDED: founder plan is_unlimited=FALSE +
  allowances=TARIFF_ALLOWANCES.ultra (bounded monthly compute credits), so a
  device-comp account is metered exactly like a paying Ultra subscriber; can't run
  unbounded LLM calls. Redemptions capped by FOUNDER_ACCESS_LIMIT + idempotent per
  device. M14a/b are docs. No action. HUMAN lever: keep FOUNDER_ACCESS_LIMIT low.
  Next COST PASS #5 after two more milestones.

## Iteration journal
(appended per iteration: done / verified-how / next)

### Iteration 1 — 2026-07-10 09:11–09:21
- Done: M1a (health endpoint, JWT prod fail-fast + \n-PEMs, STUB_OAUTH prod
  assert, env-example PEM note, deploy.md drift, deleted .env.swp) and
  M2a/b/c (resolveTier await + metadata-tier mapping; llm_usage quota,
  brainstorm/factcheck now authenticated+metered, guidance neutralized;
  webhook subscription.deleted/payment_failed + expires_at guard). D1–D3
  logged in DECISIONS.md.
- Verified: npx vitest run → 6 files, 56/56 passed (8 new M2 regression tests).
- Next: M2d (mac client tier truth) folded into M3; then M3 first-run.
- Interrupt handled mid-iteration: user hit "session binding verification
  failed" on Fireflies MCP connect — triage delivered in chat (not loop work).

### Iteration 2 — 2026-07-10 09:25–09:32
- Done: M3a paywall timing gate (value-moment + backend guards in
  Config.shouldShowPaywall); M3b .env-language purge across 8 user-facing
  strings; M3c session persistence (Persistence/SessionStore.swift, auto-save
  on stop + after post-call AI in all 3 pipelines, sidebar History with
  restore/delete).
- Verified: cd mac && swift test → 71/71 (4 new SessionStore tests; ISO8601
  second-precision date nuance covered).
- Next: M3d/M3e remain; taking M9 (privacy manifest + Info.plist keys) as the
  next bounded slice — mechanical, lint-verifiable, unblocks the MAS chain.

### Iterations 3–4 — 2026-07-10 09:33–09:45
- Done: M9 complete (privacy manifest, plist keys, git-height build number,
  packaged + codesign-verified); M3e-1 council honesty; M3e-2 dist BACKEND_URL
  default; M3e-3 ledger read view (sidebar, quiet auto-load); M10a consent
  gate; M10b account-deletion endpoint + health/deletion tests.
- Verified: backend 58/58 (vitest, live PG); mac swift test 71/71; packaged
  app codesign --verify --deep --strict clean, CFBundleVersion=160, manifest
  in Contents/Resources.
- Ops note: repo git hook (block-no-verify) false-positives on `-n` anywhere
  in a combined shell command — commits now run as dedicated calls.
- Next (first unchecked): M1b key rotation [BLOCKED: human]; M3d onboarding
  pre-flight; M3e-4 client tier truth; M4 glossary.

### Iteration 5 (final of the hour) — 2026-07-10 09:45–09:48
- Done: M2d server-truth entitlement refresh at launch (cancel downgrades,
  cross-device purchase arrives; offline keeps the cached tier).
- Verified: swift test 71/71; backend 58/58 earlier this hour.
- Hour closed at 09:48 (budget 10:11): M3d onboarding cannot land cleanly in
  the remainder — stopping per protocol rather than leaving a half-built
  slice. Next iteration starts at: M1b [BLOCKED: human rotation], M3d
  onboarding pre-flight, M4 glossary.

### Iteration 6 — 2026-07-10 ~19:15 (hourly session loop resumed)
- Done: M3d onboarding pre-flight. New OnboardingView (first-run sheet gated on
  Config.onboardingCompleted in ContentView): live mic + Screen Recording
  status with per-permission Enable actions (AppState.requestMicrophonePermission
  / requestScreenRecordingPermission / refreshPermissionStatus using the
  authoritative async SCK probe), on-device model warm-up row (honest
  preparing/ready/failed — no fake %, reuses prepareLocalModel, local engine
  only), and the relaunch-quirk callout. Prewarm kicks off on .task.
- Verified: cd mac && swift test → 258/258 (+3: Config flag round-trip +
  ViewInspector rows/granted-state), deterministic ×3. Production build clean.
- Next (first unchecked): M1b [BLOCKED: human rotation], M3e all done, M4
  transcription glossary (first substantive unchecked milestone).

### Iteration 7 — 2026-07-11 (hourly loop)
- Done: M4a per-team glossary (the transcription-fidelity lever). New
  Models/Glossary.swift parser (split/trim/dedupe/cap) + Config.transcriptionGlossary;
  Settings → Transcription "Custom vocabulary" editor with live term count;
  threaded into every engine — Deepgram nova-3 `keyterm` query items,
  AssemblyAI `word_boost` (payload extracted as pure transcriptPayload),
  Whisper API multipart `prompt`, WhisperKit `promptTokens` via the pipeline
  tokenizer (special tokens filtered, WhisperKit's own pattern).
- Verified: cd mac && swift test → 267/267 (+9: parser + Deepgram keyterm +
  AssemblyAI payload), deterministic ×3; production build clean. Backend
  untouched this slice.
- Next: M4b hardware-tiered local default; then M4c/M4d; then M5 integrations.

### Iteration 8 — 2026-07-11 (hourly loop)
- Done: M4b hardware-tiered on-device model. New Transcription/LocalWhisperModel.swift
  (base/small/large-v3 catalog + runtime Hardware.isAppleSilicon sysctl probe +
  pure recommendedDefault: Apple Silicon→small, Intel→base); Config.localWhisperModel
  now user-settable (UserDefaults, known-value guarded, baked/self-host escape
  hatch); Settings → Transcription "On-device model" radio picker with per-model
  captions (applies on restart). D4 logged: turbo variant deferred (its
  WhisperKit folder name wouldn't resolve via the `*variant/*` download glob).
- Verified: cd mac && swift test → 272/272 (+5: tiering, catalog, isKnown,
  hardware probe, Config persistence), deterministic ×3; production build clean.
- Next: M4c VoiceProcessingIO on the mic path; then M4d speakersExpected; then M5.

### Iteration 9 — 2026-07-11 (hourly loop)
- Done: M4c mic voice processing. MicrophoneCapture routes the input through
  Apple's VoiceProcessingIO (setVoiceProcessingEnabled) — echo cancellation
  (keeps the speaker-played remote side out of the mic track; we already have
  it cleanly via ScreenCaptureKit), noise suppression, AGC — re-reading the
  node format afterward and falling back to raw mic if the hardware refuses.
  Gated by Config.micNoiseSuppressionEnabled (default on) with a Settings →
  Transcription "Reduce noise & echo" toggle.
- Verified: cd mac && swift test → 273/273 (+1 flag default+round-trip;
  the AVAudioEngine path is a device smoke test), deterministic ×3; prod build
  clean.
- Next: M4d speakersExpected from calendar attendees into diarizeSession; then
  M5 integration scope.

### Iteration 10 — 2026-07-11 (hourly loop) — M4 complete
- Done: M4d diarization speaker hint. CalendarAgenda gains attendeeCount
  (parsed in CalendarService.parse); AppState stores callAttendeeCount when the
  agenda is fetched at recording start (reset per meeting); diarizeSession now
  passes AssemblyAIService.speakersExpected(attendeeCount:) — a pure helper
  that excludes the local user (the diarized track is the REMOTE system audio)
  and clamps to AssemblyAI's 1–10. Optional glossary auto-derivation deferred
  (not blocking). M4 closed (a: glossary, b: hardware model, c: mic voice
  processing, d: speaker hint).
- Verified: cd mac && swift test → 274/274 (+2: speakersExpected clamping/
  exclusion, CalendarAgenda.attendeeCount parse), deterministic ×3; prod build
  clean.
- Next: M5 integration scope — verify hosted-MCP E2E; Slack in-app OAuth +
  channel picker; one write-back (Tasks button → Linear/Jira, human-confirmed).

### Iteration 11 — 2026-07-11 (hourly loop) — M5a
- Done: M5a write-back service. New MCP/TaskWriteback.swift — the one place
  MeetGPT writes to a connected app (Tasks button → Linear/Jira/Asana issue via
  MCP tool-call), always behind the human-confirm the UI (M5b) will enforce.
  Tool name + arg shape resolved from the server's LIVE schema (not hardcoded):
  pickCreateTool (per-server preference + isCreateTool fuzzy fallback),
  buildArguments (title→title/summary/name, metadata→description, caller extras
  for teamId/projectId), describe (drops [OWNER?]/[DUE?] placeholders).
  MCPConnectionManager.writebackTargets/createTrackerItem call callToolText.
- Verified: cd mac && swift test → 281/281 (+7: tool pick, isCreateTool,
  supportsWriteback, describe, buildArguments incl. Jira summary + no-title
  nil), deterministic ×3; prod build clean. HONEST: the live tool-call is
  unverified — needs a connected tracker + the M5b confirm UI; not claimed to
  create real issues yet.
- Next: M5b confirm UI in the Tasks artifact view; M5c Slack OAuth (likely
  human-blocked on Slack app registration); M5d manual E2E.

### Iteration 12 — 2026-07-11 (hourly loop) — M5b
- Done: M5b write-back confirm UI. TaskWritebackSheet — the human-confirm step:
  a tracker picker (mcp.writebackTargets), a task list where each row files on
  demand (per-task File → createTrackerItem → verbatim ✓result / ✗error), and an
  honest connect-hint empty state when no tracker is connected. Opened from a
  new "Send to tracker" header button in AIStudioView, shown only when the last
  structured artifact is Tasks (AppState.currentTaskItems). Nothing writes until
  the user taps File.
- Verified: cd mac && swift test → 283/283 (+2 ViewInspector: renders tasks +
  connect hint; File disabled without a tracker), deterministic ×3; prod build
  clean. HONEST: the live tool-call is still unverified E2E (needs a connected
  Linear/Jira/Asana); trackers that require a team/project id will surface that
  error until M5b-2 adds schema-driven id prompting.
- Next: M5c Slack OAuth (likely [BLOCKED: human app registration]); M5d manual
  E2E per connector; then M6 data strategy.

### Iteration 13 — 2026-07-11 (hourly loop)
- Done: M5c marked [BLOCKED: human — Slack app registration] (D5 logged: needs a
  human to register the Slack app + SLACK_CLIENT_ID/SECRET + redirect URL; the
  env-token path stays as the self-host fallback so nothing regresses); M5d
  marked [MANUAL]. Then M6a: GET /api/llm/models — the backend now serves the
  model catalog (id/provider/minTier/supportsVision, weak→strong, public +
  day-cached) from the MODELS map, so the mac LLMCatalog can single-source it
  instead of hand-syncing (drift was flagged in the MODELS comment). Added
  supportsVision to the backend map.
- Verified: npx vitest run → 16 files, 202/202 (+4: catalog shape, tier order,
  cache header, tier/vision anchors matching the mac catalog). Mac unchanged
  (283, no mac edits this iteration).
- Next: M6b client hydration from the endpoint; M6c Anthropic prompt caching;
  M6d digest spine test + server grounding cache.

### Iteration 14 — 2026-07-11 (hourly loop) — M6c
- Done: M6c Anthropic prompt caching (the cost lever). streamAnthropic now sends
  the system prompt as a cache_control:ephemeral content block
  (anthropicSystemBlocks helper) — the stable prefix (base instructions + this
  call's theme/role/skill layers, which repeat verbatim across skilled-button
  presses) is reused by Anthropic instead of re-billed every call; below the
  provider minimum it's a harmless no-op. brainstorm/factcheck route to OpenAI,
  which auto-caches prefixes and already puts the stable system first — no change
  needed there. Took M6c ahead of the invasive M6b client-hydration.
- Verified: npx vitest run → 17 files, 205/205 (+3: helper shape + empty-drop +
  a body-capture proving cache_control is sent and the transcript stays in the
  user message, not the cached prefix). Mac unchanged (283).
- Next: M6d digest spine test (min-5 decision recoverable at min-70) + server
  grounding cache; then M6b hydration; then M7 COST ENGINE.

### Iteration 15 — 2026-07-11 (hourly loop) — M6d
- Done: M6d context-preservation spine. Added the min-5→min-70 spine test to
  DigestPromptTests: an early decision (unique raw marker) survives a ~48k-char
  call in a BOUNDED prompt via the digest (digest carries "launch is locked";
  the raw line scrolled out of the 8k tail; recent talk stays verbatim), and the
  no-digest path proves the win is the BOUND — it keeps the raw line but at 2×+
  the size. (First attempt asserted "digest is the sole preserver" — wrong: the
  full transcript also preserves it, just unbounded; corrected to the bound.)
  Server-side grounding cache resolved N/A (D6): grounding is client-side (120s
  groundingCache); the backend gets pre-grounded context.
- Verified: cd mac && swift test → 284/284 (+1 spine test), deterministic ×3.
- Next: M6b client catalog hydration (invasive) OR M7 COST ENGINE v1 (background
  queue, responseCache, cost telemetry). M6 substantively complete bar M6b.

### Iteration 16 — 2026-07-11 (hourly loop) — M7a (COST ENGINE begins)
- Done: M7a BackgroundLLMQueue actor — the shared cost gate for the 5 background
  watch loops. Coalesce (skip-unchanged transcript), single-flight per key, and
  global backpressure (maxConcurrent 2). Wired brainstorm/agenda/factcheck/
  rhetoric/facilitation through reserve()/finish(), replacing each loop's private
  lastXEntryCount; brainstorm+agenda GAINED coalescing (they used to re-poll on an
  unchanged transcript). Reset per meeting. Timely: I'd just tripled the loop
  count (factcheck/rhetoric/facilitation) with no cross-loop backpressure. D7.
- Verified: cd mac && swift test → 307/307 (+6: coalesce, single-flight,
  backpressure cap, idempotent finish, reset, maxConcurrent floor), deterministic
  ×3; production build clean. Wiring is behavior-preserving for the 3 coalescing
  loops and a strict cost win for brainstorm/agenda.
- Next: M7b responseCache.js (server TTL LRU for unchanged-transcript polls);
  then M7c costMeter telemetry; then M7d tier-assert tests + PG rate limiter.
  After M7 completes, COST PASS rule activates (insert COST PASS #n every 2
  milestones).

### Iteration 17 — 2026-07-11 (hourly loop) — M7b (server response cache)
- Done: M7b responseCache.js — a generic TTL+LRU cache (deterministic
  stableStringify→sha256 keys, injectable clock, hit/miss stats) wired into the
  brainstorm + factcheck handlers BELOW the auth/meter middleware. An identical
  re-poll within the 60s TTL returns the prior result instead of re-billing
  OpenAI; quota still counts per request. Key = full request payload + model;
  shared across callers safely (a hit only returns output derivable from input
  the caller supplied). env-example updated with the TTL overrides. D8.
- Verified: npm test (live PG on :5434) → 18 files, 217/217 (+12: 8 cache
  primitive — TTL expiry/LRU/stats via injected clock, 2 brainstorm + 2 factcheck
  cache-hit/re-bill). Mac untouched this slice.
- Next: M7c costMeter.js (per-call token/cost usage frames + budget alerts;
  wire responseCache.stats() hit-rate in as telemetry); then M7d tier-assert
  tests + Postgres-backed rate limiter. M7 completes after M7c+M7d, then the
  COST PASS recurrence rule activates.

### Iteration 18 — 2026-07-11 (hourly loop) — M7c-1 (cost telemetry)
- Done: M7c-1 costMeter.js — pure per-1M-token pricing (gpt-4o-mini exact +
  documented default + LLM_MODEL_PRICING env override), a shared meter with a
  rolling UTC-daily total, a one-per-day budget alert (LLM_DAILY_BUDGET_USD), and
  stats()/byFeature. Wired into brainstorm+factcheck: every provider call records
  a frame from the real OpenAI `usage` tokens; cache hits record $0. Best-effort
  (never breaks the response). env-example updated. D9. Split M7c-2 (persist
  tokens to llm_usage) as a follow-up.
- Verified: npm test (live PG :5434) → 19 files, 226/226 (+9: 7 cost primitive —
  pricing math, accumulation, budget-alert-once, no-budget, daily rollover via
  injected clock; 2 brainstorm — frame-from-usage + no-frame-on-cache-hit). Mac
  untouched.
- Next: M7c-2 (durable llm_usage token/cost columns) or M7d (tier-assert tests +
  Postgres rate limiter). M7 completes after M7d; then COST PASS recurrence arms.

### Iteration 19 — 2026-07-11 (hourly loop) — M7d-1 (tier-cost invariant tests)
- Done: M7d-1 — catalog-complete fastAudit cost invariants in LLMCatalogTests:
  a mechanical pass NEVER escalates tier (fastAudit ≤ selected, across all models
  + Auto), an actual downgrade always lands on free tier, provider is preserved
  (direct-key safety), and fastAudit is idempotent. Grep-confirmed every
  mechanical pass call site routes through fastAudit(for: Config.selectedModel).
  D10 logs the known limitation (non-OpenAI/Google premium models don't
  downgrade; default Auto path is cheap). Split M7d-2 (PG rate limiter, deferred
  — single-node launch, in-memory limiter suffices).
- Verified: cd mac && swift test → 311/311 (+4 invariant tests), deterministic
  ×3. Backend untouched.
- Next: M7d-2 (Postgres rate limiter) OR M7c-2 (durable llm_usage token columns).
  M7 substantively complete (a–d landed; c-2/d-2 are deferred durability slices).
  Per COST PASS rule, M7 completion arms "insert COST PASS #n every 2 further
  milestones" — next feature milestone is M8 (sandbox).

### Iteration 20 — 2026-07-11 (hourly loop) — M7O added to roadmap + P3a
- Done: user directed P1/P2 orchestration into the loop roadmap (new M7O). Built
  M7O-P3a — functions/ensemble.js: the backend council primitive (parallel
  fan-out to a level's panel + quorum + chairman synthesis), with callModel
  INJECTED so it's fully provider-agnostic and unit-tested. Backend
  ORCHESTRATION_LEVELS mirror the mac OrchestrationLevel (parity asserted).
  Refactor: extracted the model catalog into functions/models.js (pure, no DB) so
  the councils + tests use it without the Postgres pool; llmGateway re-imports it.
- Verified: npm test → 20 files, 238/238 (+8 ensemble: parity, chairman=last,
  fan-out+synthesis carries all proposals, failure-tolerance, quorum-fail,
  blank-answer, unknown-level). Mac untouched.
- Next: M7O-P3b — authed + tier-gated /api/orchestrate route wiring callModel to
  the real providers (consume PROVIDERS[] generators) + N× costMeter frames +
  response cache; then P3c SSE streaming; then P4 client.

### Iteration 21 — 2026-07-11 (hourly loop) — M7O-P3b (orchestrate route)
- Done: M7O-P3b POST /api/orchestrate — authed (sign-in required) + quota-metered
  + in-handler TIER GATE (level.minTier vs caller tier, before the cache so a free
  user never gets a cached ultra result) + response cache + N× costMeter frames
  (one per member + chairman, estimated tokens). Built via a DI factory
  (createOrchestrateHandler) so it's unit-tested with stubbed callModel/resolveTier
  — no DB, no providers. Added llmGateway.callModel (consume a provider stream to
  full text) for the real fan-out. Ships the cost non-negotiables: tier + cache +
  telemetry.
- Verified: npm test → 21 files, 245/245 (+7: tier-gate deny/allow, success+N+1
  frames, cache hit, member-failure tolerance, quorum-fail 502 masked, unknown-
  level/empty-user 400). env-example gained ORCHESTRATE_CACHE_TTL_MS. Mac untouched.
- Next: M7O-P3c SSE streaming of the synthesis; then P4 client (picker offers the
  tier-gated levels + China council; Ultra plan in paywall).

### Iteration 22 — 2026-07-11 (hourly loop) — M7O-P3c (SSE streaming) — P3 done
- Done: M7O-P3c — /api/orchestrate now STREAMS the chairman synthesis over SSE
  (data: {delta} … [DONE]) like /llm/chat, instead of returning JSON. Stage 1
  (members) still fans out non-streamed + metered; Stage 2 (chairman) streams,
  accumulating the text to meter + cache on a clean finish. Refactor: split
  runPanel out of orchestrate (P3a orchestrate + tests unchanged); added
  llmGateway.streamModel (generator) with callModel now built on it. Pre-stream
  errors (tier gate, quorum, unknown level) still return JSON status codes;
  cache hits replay as a single SSE delta. M7O-P3 complete (a/b/c).
- Verified: npm test → 21 files, 245/245 (orchestrate handler rewritten to the
  SSE contract: streamed text assembly, N+1 metering, cache-replay, quorum-fail
  502-before-headers, 400s). Mac untouched.
- Next: M7O-P4 — client wiring: AutoOrchestrator/model picker offers the tier-
  gated orchestration levels + China council; the mac calls /api/orchestrate and
  renders the streamed synthesis; Ultra plan surfaced in the paywall.

### Iteration 23 — 2026-07-11 (hourly loop) — M7O-P4a (client council plumbing)
- Done: M7O-P4a — OrchestrateService.swift: streams POST /api/orchestrate as SSE
  (same data:{delta}…[DONE] contract as BackendGateway), sends Bearer, maps the
  server tier-gate 403 + mid-stream errors to LLMError. AutoOrchestrator now
  routes an `orchestrate:<level>` selection → the backend council (backend/keyless
  mode) or the client EnsembleGateway with the level's panel (direct-key mode);
  falls through to normal routing if a direct-key panel can't form.
- Verified: cd mac && swift test → 322/322 (+4: OrchestrateService SSE deltas,
  payload shape, 403 tier gate, mid-stream error — URLProtocol-stubbed),
  deterministic ×3; production build clean. Backend untouched.
- Next: M7O-P4b — model picker offers the tier-gated OrchestrationLevels + China
  council (only levels the tier allows); then P4c verify the Ultra plan renders in
  the paywall (price from the billing API).

### Iteration 24 — 2026-07-11 (hourly loop) — M7O-P4b (council picker)
- Done: M7O-P4b — ModelSelectionRows offers the price-tiered orchestration
  councils (OrchestrationLevel.available(for: tier), strongest-first, backend
  mode) + the re-enabled China council (councilAvailable(.china); direct-key
  builds), each with a transparency note (US = US vendors, China = "content goes
  to those vendors"). Config.selectedModelID getter now passes orchestrate:<level>
  and council:cn straight through (CN was coerced to Auto pre-D11); selectedModel
  treats orchestrate: like a council/auto sentinel.
- Verified: cd mac && swift test → 323/323 (updated councilCoercion→councilPresets
  for the CN reversal; +orchestrationLevelSelection round-trip), deterministic ×3;
  build clean. Backend untouched.
- Next: M7O-P4c — verify the Ultra plan renders in the paywall and its price comes
  from the billing API (not hardcoded); then M7O is fully user-facing.
### Iteration 26 — 2026-07-11 (hourly loop) — M8a (sandbox mandatory for dist)
- Done: M8a — build.sh ties App Sandbox to distribution: MEETGPT_DIST=1 (or opt-in
  MEETGPT_SANDBOX=1) now signs with MeetGPT.sandbox.entitlements; a dist build can
  no longer fall back to the non-sandbox profile (fail-safe aborts if the sandbox
  entitlements are missing). Added a MEETGPT_PRINT_ENT=1 inspection hatch (prints
  the resolved entitlements, no compile) for fast verification.
- Verified: bash -n clean; MEETGPT_PRINT_ENT across flag combos → dev=non-sandbox,
  MEETGPT_DIST=1=sandbox (mandatory), MEETGPT_SANDBOX=1=sandbox (opt-in). swift
  test 317/317 (shell change; suite green).
- Next: M8b narrow SCContentFilter; M8c MANUAL device gate. After M8, COST PASS due.

### Iteration 27 — 2026-07-11 (hourly loop) — M8b (narrow capture) + COST PASS #1 queued
- Done: M8b — extracted SystemAudioCapture.makeStreamConfiguration() as the
  narrow, testable capture surface (audio-only, excludesCurrentProcessAudio, 2×2
  video, showsCursor off; only an .audio output is added so no frames decode).
  Documented the filter as display-scoped by design (any meeting app) with
  own-audio dropped. M8 substantively done (a+b; c is a MANUAL device gate).
  COST PASS rule fired (M7O + M8 = 2 milestones since M7) → appended COST PASS #1
  as the next milestone.
- Verified: swift test → 318/318 (+1 capture-config narrowing contract),
  deterministic ×3; build clean. Backend untouched.
- Next: COST PASS #1 — audit the councils + compute-credits surfaces for tier +
  cache + telemetry; confirm orchestrate/brainstorm/factcheck debit credits and
  record durable usage; flag any gap.

### Iteration 28 — 2026-07-11 (hourly loop) — COST PASS #1
- Done: COST PASS #1 audit — cost engine is green (atomic durable compute-credit
  ledger, tier gates, response caches, fail-closed metering; costs verified in
  tariffs.test). Found the one untested cost-critical seam — the meterLlmFeature
  charging middleware (inline + unexported) — extracted it to
  auth/meterLlmFeature.js (DI) and added 6 tests. D13 logged.
- Verified: npm test → 24 files, 270/270 (+6 middleware: allow/429/503-fail-closed/
  usage-shape/tier-gate/unknown-level; index.js route wiring still green). Mac
  untouched.
- Next: first unchecked roadmap milestone is M9 (PrivacyInfo.xcprivacy + Info.plist
  keys + screen-recording pre-permission UX) — largely landed in a prior iteration
  (M9 is [x]); so the next actionable is M10c/M10d (recording indicator + Delete
  account action) or M6b. Verify M9 then proceed.

### Iteration 29 — 2026-07-11 (hourly loop) — recovered + committed parallel green work
- Done: a parallel session had soft-reset the history (dropping the iteration-25
  compute-credits + iteration-28 COST PASS #1 commits into staging + untracked new
  files) and gone quiet an hour ago. Confirmed it was NOT live (HEAD unchanged),
  green, and secret-clean, so preserved it via a surgical commit (51 files, work
  paths only — never git add -A; SECRET_ROTATION_PLAN/.claude/Secrets.swift never
  staged). Also fixed 3 red mac tests (LLMStreamingClient Anthropic/Gemini
  missingKey) that MY earlier MEETGPT_DIST build caused by wiping Secrets.swift —
  regenerated dev Secrets from .env (gitignored; not committed).
- Verified: npm test → 24 files 270/270; swift test → 317/317 (both green post-fix);
  staged-diff secret scan clean. Commit 10a9a81.
- Next: tree is clean + green — resume the roadmap at M10c/M10d (recording indicator
  + Delete-account Settings action; DELETE /auth/account already exists), then M6b.
  Known follow-up: LLMStreamingClient Anthropic/Gemini tests are Secrets-dependent
  (keyless build breaks them) — give those clients a keyProvider like OpenAIClient.

### Iteration 30 — 2026-07-12 (hourly loop) — M10d tested (account deletion)
- Done: verified M10 is substantially complete — consent gate (M10a), DELETE
  endpoint (M10b), recording indicator (M10c-1: MenuBar live red dot + status),
  and M10d ("Delete account" Settings action + AppState.deleteAccount) all present
  and correct. Closed the real gap: the App-Review-required deletion flow was
  UNTESTED (deleteAccount used a hardcoded pinned session). Extracted the HTTP call
  to Integrations/AccountDeletion.swift (injectable session) + 3 tests. M10c-2
  (consent link → live pages) BLOCKED on M13.
- Verified: cd mac && swift test → 320/320 (+3 AccountDeletion), deterministic ×3;
  build clean. Backend untouched.
- Next: M11 (launch decisions — name + IAP strategy; both HUMAN calls, surface for
  decision) or M6b (client catalog hydration). Two milestones on, COST PASS #2 due.

### Iteration 31 — 2026-07-12 (hourly loop) — M11 decision brief (human call)
- Done: M11 is a HUMAN product/legal milestone (canonical name + IAP strategy) —
  surfaced, not fabricated. Inventoried the 3-name split (Cruxwing customer-facing,
  MeetGPT bundle w/ a "GPT"-in-name App-Review risk, Wheespr internal) and laid out
  the IAP options (StoreKit 2 / US external-link / web-account-only) with
  trade-offs + a recommendation in D14. Marked M11 [BLOCKED: human decision].
- Verified: no code changed (decision brief only); tree otherwise green from
  iter-30 (mac 320, backend 270). Decisions surfaced to the user in-chat.
- Next: M11 blocks M12 (needs the name/bundle id) — so the next actionable code
  slice is M6b (mac LLMCatalog hydrates from /api/llm/models) or M7c-2. Two
  milestones on, COST PASS #2 due.

### Iteration 31b — 2026-07-12 — M11 decisions made + M11a (name → Cruxwing)
- Done: human resolved M11 (D14) — name=Cruxwing, IAP=StoreKit 2. Implemented
  M11a: CFBundleDisplayName=Cruxwing + renamed all user-facing "MeetGPT" strings
  in the mac Views to Cruxwing (verified: 0 user-facing MeetGPT left; ChatGPT
  untouched; internal target/bundle-id kept). M11b (StoreKit 2) queued next.
- Verified: swift test → 320/320; build clean. No test asserted a renamed string.
- Next: M11b StoreKit 2 IAP (large; App Store Connect products = human) — or, since
  that's multi-iteration + partly human, M6b (catalog hydration) as a bounded code
  slice meanwhile. Two milestones on, COST PASS #2 due.

### Iteration 32 — 2026-07-12 — purchase-path A/B cohort (user-directed)
- Done: added the purchase-path A/B experiment infra per human decision (D15) —
  channel-level (MAS = IAP-only, no anti-steering risk) + server cohort.
  functions/abTest.js (stable per-user 'iap'|'web', env-tunable split) exposed in
  the profile payload for the client/landing to steer the CTA. Backend-only, no
  App-Review-risky in-app web link.
- Verified: npm test → 25 files, 277/277 (+7 abTest: stable/splits/anon/bad-split/
  bucket-range; auth integration still green with the new profile field).
  env-example gained AB_WEB_PURCHASE_SPLIT.
- Next: M11b StoreKit 2 IAP (large; App Store Connect products = human) or M6b
  (catalog hydration). Two milestones on, COST PASS #2 due.

### Iteration 33 — 2026-07-12 — M11b-1 StoreKit product-catalog contract
- Done: M11b groundwork — functions/storeKit.js, the StoreKit product-id ↔ tariffs
  contract, built dynamically from tariffs.js (6 subs + 11 add-ons → com.cruxwing.
  sub.*/pack.* ids) with a productForId reverse map (null for unknown = untrusted
  transactions). Exposed storeKitProductId per plan/add-on in GET /api/billing/plans
  so the mac IAP client requests the same App Store Connect products (no client-side
  drift). This is the shared contract the receipt bridge (M11b-2) + client (M11b-3)
  build on.
- Verified: npm test → 26 files, 286/286 (+9: storeKit coverage/format/uniqueness/
  round-trip + plansHandler catalog exposure via DB-backed stripeBilling test).
  Secret scan of the diff clean.
- Next: M11b-2 receipt→entitlement bridge (verify JWS → productForId → activate),
  Apple verifier injectable/mocked. Then M11b-3 client. Two milestones on, COST
  PASS #2 due.

### Iteration 34 — 2026-07-12 — M11b-2 StoreKit receipt→entitlement bridge
- Done: POST /api/billing/storekit (authed) — verify (INJECTED, fail-closed) →
  productForId → idempotent activation. Added iap_transactions table (PK on the
  Apple transaction id) + recordIapTransaction so a replay grants once;
  subscriptions activate the plan at its tier (source:'storekit'); add-ons return
  an honest not-yet-grantable (no grant path for either provider). Split out
  M11b-2b (the real x5c JWS verifier — security-critical, needs Apple's root cert
  + signed fixtures) so we never ship a half-verifier.
- Verified: npm test → 27 files, 293/293 (+7 DB-backed: activate/idempotent/
  unknown-product/add-on/malformed/missing/fail-closed-503). Secret scan clean.
- Next: M11b-3 (mac StoreKit client: fetch products from the catalog → purchase()
  → verified transaction → POST the bridge → refresh entitlement) or M11b-2b.

### Iteration 35 — 2026-07-12 — COST PASS #2
- Done: COST PASS #2 (M10 + M11 = 2 milestones since #1). Cost engine green
  (regression 45/45). No new LLM feature to re-audit; the one new cost-relevant
  surface is the StoreKit bridge — verified + LOCKED that an IAP-activated
  subscription carries the tier's compute-credit allowances (getUserPlan →
  TARIFF_ALLOWANCES[tier]), so IAP customers hit the same metered quota as Stripe.
  Closed the test gap (bridge test was tier-only → added the allowances assertion).
- Verified: npm test → 27 files, 293/293; cost-critical suites 45/45. No secrets.
- Next: M11b-3 (mac StoreKit client) or M11b-2b (real Apple JWS verifier). COST
  PASS #3 after two more milestones.

### Iteration 36 — 2026-07-12 — M11b-3 (mac StoreKit client)
- Done: M11b-3 — the mac purchase path. 3a StoreKitBridge.submit (POST signed
  JWS → /api/billing/storekit, parse the server's decision; client never grants
  itself) + 9 URLProtocol-stubbed tests. 3b StoreKitPurchaser (import StoreKit:
  products/purchase/syncUnfinished; finish() only after the server records it;
  unverified never trusted) — compiles, device-tested (needs ASC products M11b-4).
- Verified: swift build clean; swift test → 329 pass (+9). No secrets in new files.
- Next: M11b-2b (real Apple JWS x5c verifier — the last security-critical server
  slice before IAP grants for real) or M12. No new cost surface this slice (client
  for the already-audited bridge) → COST PASS #3 not yet due.

### Iteration 37 — 2026-07-12 — M11b-2b (real Apple JWS verifier)
- Done: M11b-2b — functions/appleReceiptVerifier.js wraps Apple's OFFICIAL App
  Store Server Library (SignedDataVerifier.verifyAndDecodeTransaction) as the
  storeKitBridge DEFAULT verifier (replaced the always-throw stub). Fail-closed
  when library/Apple-Root-CAs/bundle-id (/prod app-id) unset → 503. Chose the
  audited library over hand-rolling x5c+ES256 (security boundary). Config in
  deploy/api/.env.production.example. 12 pure unit tests via a stub library.
- Verified: npx vitest test/appleReceiptVerifier.test.js → 12/12; storeKitBridge
  fail-closed still 503; npm test → 28 files, 305/305. No secrets (env vals empty).
- Next: M12 (MAS signing/packaging) — the first unchecked top-level milestone.
  Real-signature E2E is [MANUAL] M11b-2b-verify. No new LLM/cost surface this
  slice → COST PASS #3 due after M12+M13 (M11 already counted in #2).

### Iteration 38 — 2026-07-12 — M12a (MAS packaging lane + secret gate)
- Done: M12a — appstore.sh (Apple Distribution sign + embedded profile +
  productbuild .pkg + Transporter/altool upload; no hardened runtime, App Sandbox
  via build.sh MEETGPT_DIST=1) and assert-no-baked-secrets.sh (the M12
  SECRET_VARS fail-safe — scans the shipped Mach-O for key shapes, aborts before
  packaging). Pre-flight fails fast on missing Apple creds; MAS_DRY_RUN=1 for the
  credless build+gate path. D16; bundle-id permanence surfaced as a human call.
- Verified: bash -n both; secret gate LIVE-refuses the real dev binary (keys
  baked) + all 4 provider shapes + passes clean input; pre-flight aborts with no
  profile (no build started). No Swift/JS changed → mac 329 / backend 305 hold.
- Next: M12b is [HUMAN] (Apple certs/profile/upload + the permanent bundle-id
  call). First unchecked autonomous milestone → M13 (landing→install funnel).
  No new LLM/cost surface this slice → COST PASS #3 due after M13.

### Iteration 39 — 2026-07-12 — M13a (landing under version control + pricing reconciled)
- Done: M13a — committed web/landing (index.html + assets + placeholder-only
  hubspot.js). Honesty audit passed (SOC 2 = readiness+disclaimer, own logo only,
  no fabricated metrics). landingPricing test now DERIVES consumer-tier + shown
  add-on prices from tariffs.js so the fallback can't drift from the billing API.
  D17. Team/Enterprise tiers flagged as honestly-framed-but-outside-the-API (human).
- Verified: npx vitest test/landingPricing.test.js → 6/6; npm test → 28 files,
  307/307. hubspot.js placeholder-only; .DS_Store gitignored; no secrets.
- Next: M13b (/privacy /terms /security static pages — unblocks M10c-2 consent
  links). COST PASS #3 due when M13 completes (M12 + M13 = 2 since #2).

### Iteration 40 — 2026-07-12 — M13b (privacy/terms/security pages)
- Done: M13b — three on-brand static legal pages (shared legal.css) with content
  accurate to app behavior + honest SOC-2-readiness framing; /terms added to the
  landing footer + in-app consent sheet. Unblocked M10c-2. D18.
- Verified: legalPages test → 13/13; npm test → 29 files, 320/320; swift build
  clean + swift test → 329. Secret scan clean (only prose "password"). No fab certs.
- Next: M13c (HubSpot portal/form [HUMAN], SEO/analytics, deploy [HUMAN host]) —
  last M13 slice. COST PASS #3 due when M13 completes (M12 + M13 since #2).

### Iteration 41 — 2026-07-12 — M13c-1 (landing SEO)
- Done: M13c-1 — robots.txt + sitemap.xml (valid XML) + per-page canonicals +
  og:url/robots meta + honest JSON-LD (SoftwareApplication, no fabricated
  ratings, only the free $0 tier priced). HubSpot/analytics/deploy split to
  [HUMAN] M13c-2 (analytics must be cookieless per the privacy policy). D19.
- Verified: landingSeo test → 9/9; sitemap valid via xmllint; npm test → 30
  files, 329/329. Secret scan clean.
- Next: COST PASS #3 is now DUE (M12 + M13 = 2 milestones since #2) — run it next
  iteration before M14.

### Iteration 42 — 2026-07-12 — COST PASS #3
- Done: COST PASS #3 (M12 + M13 since #2). Cost engine green (45/45); grep-audited
  all 5 source files changed since #2 → no LLM call / metered path (IAP + packaging
  + static web only). No new cost surface; tier+cache+telemetry intact. No action.
- Verified: cost-critical suites 45/45; npm test → 30 files, 329/329. No secrets.
- Next: M14 (MAS listing & ASO + review readiness) — the first unchecked milestone.
  COST PASS #4 due after M14 + M15.

### Iteration 43 — 2026-07-12 — M14a (App Store listing + ASO)
- Done: M14a — launch/app-store-listing.md (name/subtitle/promo/keywords/desc +
  metadata), drawn from the audited landing copy. Fields enforced against Apple's
  hard limits + honesty (no certified/ratings/prices) by a 10-test suite. D20.
- Verified: appStoreListing test → 10/10 (actuals 8/28/168/90/1857 chars all under
  limit); npm test → 31 files, 339/339. No secrets.
- Next: M14b (App Review readiness checklist + reviewer demo account/notes) — the
  next autonomous slice. COST PASS #4 after M14 + M15.

### Iteration 44 — 2026-07-12 — M14b (App Review readiness)
- Done: M14b — launch/app-review-readiness.md (guideline→shipped map, all evidence
  verified in code), 5.1.2 determined not-triggered (first-party auth), reviewer
  notes (email+password demo, on-device model). Fixed Info.plist permission
  strings MeetGPT→Cruxwing + added copyright. D21.
- Verified: appReviewReadiness test → 24/24 (every cited path exists); npm test →
  32 files, 363/363; swift test → 329; plutil OK. No secrets.
- Next: M14c is [HUMAN] (demo acct, screenshots, ASC submit). First unchecked
  autonomous milestone → M15 (launch channels & funnel metrics). COST PASS #4 due
  after M15 (M14 + M15 since #3).

### Iteration 45 — 2026-07-12 — M15a (funnel telemetry)
- Done: M15a — functions/funnel.js (fixed-taxonomy, PII-rejecting POST /api/funnel,
  rate-limited, logEvent-backed) + a cookieless DNT-respecting landing emitter
  (landing_view + cta_click). Honest + privacy-consistent. D23.
- Verified: funnel test → 22/22; npm test → 34 files, 391/391. No secrets.
- Next: M15b (mac client funnel emitters). M14 + M15 autonomous work now done →
  COST PASS #4 is DUE next (2 milestones since #3).

### Iteration 46 — 2026-07-12 — COST PASS #4
- Done: COST PASS #4 (M14 + M15 since #3). Cost engine green (45/45). Audited the
  new surfaces: funnel.js = no provider call; device-redeem grants Ultra but the
  Founder plan is bounded (is_unlimited=false + TARIFF_ALLOWANCES.ultra), capped by
  FOUNDER_ACCESS_LIMIT + idempotent per device → metered like any Ultra sub. No leak.
- Verified: cost-critical suites 45/45; grep audit clean; founder is_unlimited=false.
- Next: M15b (mac client funnel emitters) — first unchecked autonomous milestone.
  COST PASS #5 after two more milestones.

### Iteration 47 — 2026-07-12 — M15b (mac funnel emitters)
- Done: M15b — FunnelTracker (cookieless, anonymous, opt-out-gated) wired at 7
  honest stages across MeetGPTApp/AppState/PaywallView. subscribe_success fires
  only after the plan is confirmed active. D24.
- Verified: FunnelTracker tests 3/3; swift build clean; swift test → 332 (+3);
  backend unchanged (391). No secrets.
- Next: M15 nearly done (M15c is [HUMAN] channel outreach). Remaining autonomous
  work is deferred sub-items (M6b, M7c-2, M7d-2) or M15b-2 (IAP funnel event).

### Iteration 48 — 2026-07-12 — M7c-2 (durable cost telemetry)
- Done: M7c-2 — llm_cost_frames table + costMeter sink (setSink @ bootstrap,
  fire-and-forget) + costSummarySince() aggregate. Per-feature (not per-user) to
  sidestep the deferred handler-plumbing invasiveness + avoid cost PII. D25.
- Verified: costMeter sink tests + DB frames tests (6); npm test → 35 files,
  397/397. No secrets. No new env (uses existing LLM_MODEL_PRICING).
- Next: remaining autonomous backlog is M6b (invasive client hydration) or M7d-2
  (Postgres rate limiter, low urgency). COST PASS #5 after two more milestones.

### Iteration 49 — 2026-07-13 — M6b (mac catalog hydration)
- Done: M6b — LLMCatalog.all is now backend-hydrated (hydrated ?? fallback),
  wired at launch; kills client/backend catalog drift + lets a shipped app learn
  new models without an update. Minimal surface (call sites unchanged). D26.
- Verified: hydration tests 6/6; swift build clean; swift test → 338 (+6), stable
  across 2 runs; backend unchanged (397). No secrets.
- Next: only M7d-2 (Postgres rate limiter, low-urgency/single-node) remains in the
  autonomous backlog; everything else is [HUMAN]/[MANUAL]. Loop near its autonomous end.

### Iteration 50 — 2026-07-13 — Launch runbook (human handoff)
- Done: launch/LAUNCH_RUNBOOK.md — the dependency-ordered go-live path
  consolidating every [HUMAN]/[MANUAL] gate (secrets/rotation → backend deploy +
  verifier config → landing deploy → Apple/ASC → build+upload → submit →
  channels) with the file/command + acceptance check for each. 16 tests: every
  cited path is TRACKED (fresh-clone safe; gitignored rotation docs referenced in
  prose) + the safety invariants (fail-closed verifier, keyless gate, cookieless
  analytics, permanent bundle id, email+password demo acct) are asserted.
- Verified: launchRunbook test 16/16; npm test → 36 files, 413/413. No secrets.
- LOOP STATUS: all 15 milestones' autonomous work is COMPLETE. Only M7d-2
  (Postgres rate limiter) remains autonomous — deferred as YAGNI (single-node
  launch; building it now is speculative). Everything else is human-gated (see the
  runbook). The loop has reached its autonomous end; the path to launch is the
  runbook, executed by a human. Recommend pausing the loop until then.

### Iteration 51 — 2026-07-13 — M15b-2 (telemetry opt-out UI + IAP funnel event)
- Done: M15b-2 — user-visible "Share anonymous usage data" toggle (Settings →
  Account & Privacy, bound to Config.funnelOptOut) closing the no-off-switch
  privacy gap; IAP-path subscribe_success funnel event. D27.
- Verified: swift build clean; swift test → 338; backend unchanged (413). No secrets.
- LOOP STATUS: autonomous backlog now down to only M7d-2 (Postgres rate limiter,
  YAGNI single-node). Everything else human-gated (launch/LAUNCH_RUNBOOK.md).
  Genuinely at the autonomous end — recommend pausing the loop.

### Iteration 52 — 2026-07-13 — Autonomous loop COMPLETE
- Done: dispositioned the last open autonomous item — M7d-2 marked
  [DEFERRED — premature] with a verified rationale (sync→async refactor across ~9
  call sites + a per-request DB regression at single-node scale, for a benefit
  nothing needs yet) and a concrete revisit trigger. No high-value autonomous work
  remains that doesn't violate YAGNI.
- Verified: doc-only change; suites hold (backend 413, mac 338). No secrets.
- STOP CONDITION MET: every roadmap milestone is now checked, [HUMAN]/[MANUAL]/
  [BLOCKED], or [DEFERRED — premature]. The path to launch is launch/LAUNCH_RUNBOOK.md,
  executed by a human. Loop halting — restart it when a runbook phase lands or an
  App Review rejection needs turning into a new slice.

### Iteration 53 — 2026-07-13 — M7O-P4c (Ultra in the paywall) — CORRECTION
- Done: the diligent state scan caught a genuinely-open item I'd wrongly folded
  into "loop complete" last iteration — M7O-P4c. VERIFIED (not re-built) that the
  paywall surfaces Ultra with an API-sourced price (publicPlans serves ultra @
  9900/99000; selectablePlans renders all tiers; priceLabel from priceCents) and
  LOCKED it with guard tests both sides. M7O-P4 + M7O now fully complete.
- Verified: backend npm test → 36 files, 414/414 (+1); mac swift test → 339 (+1). No secrets.
- CORRECTION to iter 52: the loop was NOT complete — M7O-P4c was open. Now it is:
  every roadmap milestone is checked, [HUMAN]/[MANUAL]/[BLOCKED], or [DEFERRED].
  Path to launch remains launch/LAUNCH_RUNBOOK.md (human).

### Iteration 54 — 2026-07-13 — state scan (no actionable slice)
- Done: diligent full scan of every unchecked item. Found NO genuine open
  autonomous leaf — only a stale M7O-P3 parent checkbox (its P3a/b/c children were
  all done); corrected it. Every other unchecked item is a parent header whose
  remainder is [HUMAN]/[MANUAL]/[DEFERRED] (M1b rotation, M11b-4/M12b/M13c-2/M14c
  Apple+deploy, M5c/M5d/M8c/M11b-2b-verify, M7d-2 deferred).
- Verified: doc-only; no code changed (backend 414 / mac 339 hold). No secrets.
- STATUS: autonomous backlog empty. Path to launch = launch/LAUNCH_RUNBOOK.md
  (human). Loop holding — restart when a runbook phase lands or App Review responds.

### Iteration 56 — 2026-07-13 — Keychain hardening (from a real incident)
- Done: hardened SystemKeychain against the cross-signature login-keychain prompt a
  user just hit — get/set pass LAContext.interactionNotAllowed so a mismatched-ACL
  item FAILS SOFT (no un-passable modal) and the app self-heals (re-auth + recreate
  the item) instead of locking the user out. D28.
- Verified: real-keychain happy-path smoke test; swift build clean; swift test 339;
  app rebuilt + installed. No secrets.
- Next: cross-signature path device-verifiable only; MAS build immune. Backlog empty.

### Iteration 57 — 2026-07-13 — AI thinking-panel + closed chat cost-telemetry gap
- Done: verified the user-requested AI-UX work against the cost non-negotiable and
  CLOSED a real gap — the generic /api/llm/chat surface (9 text buttons + custom
  prompts + follow-ups, the largest LLM path) now records a durable USD cost frame
  (estimated tokens), like brainstorm/factcheck/orchestrate. Thinking panel adds no
  LLM cost (derived from existing stages); follow-ups already had the fastAudit
  tier. D29.
- Verified: chatCostFrame + costMeter tests 14/14; npm test → 416/416; mac 343. No secrets.
- Next: autonomous roadmap backlog remains empty (launch = LAUNCH_RUNBOOK.md, human).

### Iteration 58 — 2026-07-13 — state hygiene (session fixes logged)
- Done: logged D30 (dev-build BACKEND_URL=off direct mode; mic voice-processing
  default OFF, with the echo-vs-ducking tradeoff). Confirmed no new actionable
  autonomous leaf — only human/manual/deferred remainders.
- Verified: working tree clean; last suites green (backend 416, mac 343 in CI config).
- STATUS: autonomous roadmap backlog empty; launch path = LAUNCH_RUNBOOK.md (human).
  Recent value came from user-driven fixes + audits catching a real cost-telemetry gap.
