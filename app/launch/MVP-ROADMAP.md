# MVP roadmap — landing on domain · HubSpot · auth (email/SMS) · Stripe · best Whisper

Target: a stranger lands on your domain, becomes a HubSpot lead, downloads the
app, signs up (email or SMS), pays via Stripe, and gets best-quality managed
transcription (Whisper large-v3 on the VPS) + metered AI through your keys.

**Baseline (already done in code):** backend complete (auth incl. OTP/password/
Google/Apple/SMS · RS256 JWT · metered LLM gateway · Stripe checkout + webhook
lifecycle · StoreKit · `/api/transcribe` Whisper gateway); landing built with
API-driven pricing; `hubspot.js` scaffolded; deploy configs + env starter + JWT
generator ready; mac app suite green with a live E2E test rig (`livetest.sh`);
dist builds default signed-in users to Cruxwing Whisper (server large-v3).

Legend: **You** = accounts/consoles/server (only you can). **Me** = repo work /
verification I drive. Est. total: 2–3 focused days; ~1 week with approval waits.

---

## Phase 0 — Security gate (½ day · You) — BLOCKS EVERYTHING
- [ ] Rotate every compromised key (client-baked + git-history `config.js`):
      OpenAI, Anthropic, Deepgram, AssemblyAI, DeepSeek, Google. New values go
      ONLY into the server env.
- ✅ Old keys 401; new keys exist nowhere in the repo.

## Phase 1 — Accounts & keys (½–1 day · You, parallelizable)
Collect into `deploy/api/.env.production` (copy `deploy/api/.env.production.starter`):
- [ ] Domain + DNS (`cruxwing.com`, `api.cruxwing.com`)
- [ ] VPS (Ubuntu, ≥8 vCPU if CPU-only Whisper — see Phase 2b) + Postgres
- [ ] SMTP (Postmark/Resend/SES) → email OTP
- [ ] Twilio Verify (3 values) → SMS auth
- [ ] Stripe account (secret key now; webhook secret in Phase 5)
- [ ] HubSpot free portal (portal ID + form GUID)
- ✅ Starter env has no `CHANGE_ME` left (except Stripe webhook).

## Phase 2 — Backend live on api.<domain> (½ day · You on server, Me prep/verify)
- [ ] `bash deploy/api/generate-jwt-keypair.sh >> deploy/api/.env.production`
- [ ] Server: clone → `npm ci` → env in place (chmod 600) → install
      `deploy/api/cruxwing-api.service` + `deploy/api/nginx-cruxwing.conf` → certbot
- [ ] Set `FOUNDER_ACCESS_CODE` (≥16 chars) — tier testing without payments
- ✅ `curl https://api.<domain>/health` → 200 · boot without JWT PEMs exits
     non-zero · email OTP + SMS + password sign-in succeed against prod.

## Phase 2b — Best Whisper on the VPS (1–2 h · You run, Me verify)
- [ ] `docker compose -f deploy/api/whisper-compose.yml up -d` (large-v3, int8,
      preloaded, bound to 127.0.0.1 — never expose the port)
- [ ] Env already points at it (`WHISPER_UPSTREAM_URL`, `WHISPER_MODEL=large-v3`);
      restart backend
- [ ] Sizing honesty: CPU-only needs ~8 vCPU for ~2 live chunk streams — if
      transcripts lag, switch to `distil-large-v3` (near-large quality, ~6×
      faster) or a GPU box. Bridge until then: `WHISPER_ALLOW_OPENAI_FALLBACK=1`.
- ✅ `POST /api/transcribe` (signed-in) returns text for a sample WAV; the app,
     signed in, transcribes via the server by default; signed-out still works
     on-device.
- [ ] **Honesty task (Me + You):** update landing/privacy copy — "on-device for
      trial; managed Whisper (large-v3) when signed in" (current copy claims
      on-device by default).

## Phase 3 — Landing published (2–3 h · mixed)
- [ ] Deploy `web/landing/` (Netlify/Cloudflare Pages; clean URLs so
      `/privacy` `/terms` `/security` resolve) or same-VPS nginx; point DNS
- [ ] Set `FRONTEND_ORIGIN` on the backend (CORS); restart
- ✅ Page live on the domain; pricing cards hydrate from
     `/api/billing/plans`; sitemap/robots at root.

## Phase 4 — HubSpot wired (1 h · You paste, Me verify)
- [ ] Create the lead form → paste `portalId`/`formGuid` into
      `web/landing/hubspot.js` CONFIG (guide: `docs/landing/HUBSPOT.md`); redeploy
- ✅ Test submission appears as a HubSpot contact; funnel events still flow
     (cookieless only — no GA, per the privacy policy).

## Phase 5 — Stripe end-to-end (2–3 h · mixed)
- [ ] Create products/prices matching `PAYWALL_PLANS` (pro $12 · premium $29 ·
      launch $19)
- [ ] Webhook endpoint `https://api.<domain>/api/billing/webhook` → paste
      `STRIPE_WEBHOOK_SECRET`; restart
- [ ] Test mode: `4242…` checkout → plan activates → tier upgrades in-app;
      cancel → downgrade (lifecycle already coded)
- [ ] Flip to live keys
- ✅ Purchase upgrades the tier and cancellation downgrades it with zero
     manual DB touches.

## Phase 6 — A download users can run (2–4 h · You for Apple cert, Me the rest)
- [ ] Apple Developer ID cert installed (one-time)
- [ ] `.env → BACKEND_URL=https://api.<domain>` → `MEETGPT_DIST=1` build →
      `notarize.sh` → zip → landing CTA download link
- ✅ Clean Mac: download → open (no Gatekeeper fight) → sign in → record →
     server-Whisper transcript → metered AI answer.

## Phase 7 — MVP acceptance (1 h · together)
- [ ] Full funnel once, honestly: land → HubSpot lead → download → email AND
      SMS sign-up → Stripe purchase → tier visible → AI + server transcription
      work → cancel → downgrade
- [ ] `SKIP_BUILD=1 bash livetest.sh` against the prod-pointed build
- ✅ Every step above passes → MVP is live.

---
Critical path: 0 → 1 → 2 → 2b/3 (parallel) → 5 → 6 → 7. HubSpot (4) anytime
after 3. When the VPS + domain exist, Phases 2–3 can be driven interactively:
you run the server commands, I verify each acceptance gate.
