# Cruxwing launch TODO (human)

The code is done and green (backend 416 / mac 343 tests). Everything below is
**yours** — accounts, secrets, and hosts that code can't create. Ordered by
priority; each item has the concrete action, the file/command, and how you know
it's done. Companion: `launch/LAUNCH_RUNBOOK.md` (same path, prose form).

Legend: 🔴 do first / blocks everything · 🟠 required to ship · 🟡 required but
parallelizable · ⚪ after launch / optional.

---

## 🔴 P0 — SECURITY (do this first, today)

- [ ] **Rotate every compromised secret.** The client-baked provider keys AND the
  `config.js` credentials in git history are COMPROMISED and still valid. Rotate
  each in its provider console and put the NEW value only in the SERVER env:
  - [ ] OpenAI, Anthropic, Google AI, Deepgram, AssemblyAI, DeepSeek (any you use)
  - [ ] Stripe secret + webhook signing secret
  - [ ] SMTP creds; Google OAuth client secret; Apple Sign-in key (if used)
  - Follow your local `SECRET_ROTATION_PLAN.md` §7 checklist + `docs/dispatch-keys-runbook.md`.
  - **Done when:** rotation checklist fully checked; every OLD key returns 401 when tested.
- [ ] **Never commit the new keys.** They live only in the server env file
  (`deploy/api/.env.production`, gitignored) and your local `.env` (dev only).

## 🟠 P1 — Backend live (gates the app, landing, funnel)

- [ ] **Fill the production env** from `deploy/api/.env.production.example`:
  - [ ] `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY` — `\n`-escaped one-line PEMs
  - [ ] `FRONTEND_ORIGIN`, `LLM_ANON_RATE_LIMIT`, `LLM_USER_RATE_LIMIT`
  - [ ] `DATABASE_URL`, `STRIPE_*`, provider keys; `STUB_OAUTH` unset
  - **Done when:** booting prod WITHOUT the JWT PEMs exits non-zero (fail-fast).
- [ ] **Deploy the API** to `https://api.<your-domain>` per `docs/deploy.md`
  (systemd unit + nginx; `initDb()` self-applies `functions/db/schema.postgres.sql`).
  - **Done when:** `curl -fsS https://api.<domain>/health` → 200; a restart does
    NOT rotate JWKS.
- [ ] **Enable StoreKit receipt verification** (else IAP fails closed at 503):
  - [ ] `npm i @apple/app-store-server-library` on the server
  - [ ] Put Apple's public Root CAs (apple.com/certificateauthority, "Apple Root
        CA - G3") in a dir → `APPLE_ROOT_CA_DIR`
  - [ ] Set `APPLE_IAP_BUNDLE_ID`, `APPLE_IAP_ENVIRONMENT`, `APPLE_IAP_APP_APPLE_ID`
  - **Done when:** unset → `POST /api/billing/storekit` = 503; set → real verify.
- [ ] **(Optional) Operator comp code:** set `FOUNDER_ACCESS_CODE` (≥16 chars) +
  `FOUNDER_ACCESS_LIMIT`. Redeem grants Founder/Ultra (no email needed).

## 🟡 P1 — Landing live (parallel with backend)

- [ ] **Deploy `web/landing/`** to a static host with **clean-URL routing** so
  `/privacy` `/terms` `/security` resolve (they're `.html`) and `sitemap.xml` /
  `robots.txt` serve at root (Netlify/Vercel/Cloudflare Pages do this).
  - **Done when:** `https://<domain>/privacy` loads; the pricing cards hydrate from
    `https://api.<domain>/api/billing/plans`.
- [ ] **HubSpot:** set `portalId` / `formGuid` in `web/landing/hubspot.js`.
- [ ] **Analytics:** add a **cookieless** provider only (Plausible/Fathom) —
  GA/cookie trackers would break the privacy policy's no-tracking claim.

## 🟠 P2 — Apple Developer / App Store Connect (the big block)

- [ ] **DECIDE the permanent bundle id** — ⚠ locked once submitted.
  `Support/Info.plist` ships `com.meetgpt.macapp`; the flagged alternative is
  `com.cruxwing.mac`. Change Info.plist FIRST if switching.
- [ ] **Trademark check** on "co-pilot" branding (app name is "Cruxwing").
- [ ] **Install two certs:** "Apple Distribution" (app) + "3rd Party Mac Developer
  Installer" (pkg). Download a **Mac App Store provisioning profile** for the id.
- [ ] **App Store Connect → create the app record.**
- [ ] **Create the IAP products** with the exact ids from `functions/storeKit.js`
  (subscriptions = auto-renewable; packs = consumable).
- [ ] **Screenshots + optional app preview** (record from the dev build).
- [ ] **Reviewer demo account** — email+password (NOT the OTP flow — a reviewer
  can't get the code). Put it in App Review "Sign-In Information".
- [ ] **App Review notes** — copy from `launch/app-review-readiness.md`.

## 🟠 P2 — Build, verify, upload

- [ ] **Verify a StoreKit sandbox purchase end-to-end** against the real verifier:
  a sandbox tester buys → `POST /api/billing/storekit` grants the plan.
- [ ] **Build + package the MAS pkg:**
  `MAS_PROVISION_PROFILE=~/Cruxwing_MAS.provisionprofile bash appstore.sh`
  (runs `build.sh` keyless + `assert-no-baked-secrets.sh`; aborts if any key is baked).
  - **Done when:** secret gate passes; `dist/MeetGPT.pkg` is produced + signed.
- [ ] **Upload:** Transporter.app, or
  `xcrun altool --upload-app -f dist/MeetGPT.pkg -t macos -u <apple-id> -p <app-specific-password>`.
- [ ] **Paste the listing** (`launch/app-store-listing.md`) into ASC + submit for review.

## ⚪ P3 — Launch & grow (after approval)

- [ ] Run launch channels (posts, outreach, communities). The funnel
  (`/api/funnel` + landing/app emitters) captures results honestly.
- [ ] Watch conversion: read provider spend from the durable cost frames
  (`costSummarySince`); read funnel counts from the `logEvent('funnel', …)` stream.

## ⚪ Later / optional (not launch-blocking)

- [ ] **Slack in-app OAuth** — needs a Slack app registration (env-token connector
  works meanwhile).
- [ ] **Hosted-MCP + tracker write-back E2E** — needs connected accounts.
- [ ] **Device sandbox verification** — mic + ScreenCaptureKit + OAuth loopback
  under the App Sandbox on a real machine.
- [ ] **Postgres-backed rate limiter** — only when scaling beyond one node
  (deferred as premature; see D-notes / LOOP_STATE M7d-2).

---

## Dev / testing notes (for you, right now)

- **Dev build (baked keys, local):** `bash build.sh` → installs to
  `/Applications/MeetGPT.app`. Your `.env` has `BACKEND_URL=off` so AI calls go
  **direct** to providers (no backend needed). Sign-in/paywall won't work in this
  mode (they need the backend) — expected.
- **Switch to backend mode:** set `BACKEND_URL=https://api.<domain>` in `.env`,
  rebuild.
- **MAS/dist build:** `MEETGPT_DIST=1 bash build.sh` (keyless, sandboxed) or
  `MAS_DRY_RUN=1 bash appstore.sh` (keyless build + secret gate, no Apple certs).
- **Keychain password loop after a rebuild** (if the signing cert changed):
  `security delete-generic-password -s "ai.wheespr.meetgpt"`, then relaunch + sign
  in. (The app now fails soft on this instead of an un-passable prompt.)

## Open follow-ups I flagged (tell me to pick any up)

- [ ] **Real model reasoning in the thinking panel** — currently shows synthesized
  workflow steps (no LLM cost). Streaming actual reasoning tokens needs per-provider
  parsing (Anthropic `thinking` / OpenAI `reasoning_content` / Gemini `thinkingConfig`)
  + a backend SSE `reasoning` event.
- [ ] **Mic AGC vs VAD** — if the transcript stalls again after the ducking fix,
  the voice-processing AGC may be the cause (needs macOS 14+; separate tuning).
- [ ] **ViewInspector tests coupled to a non-empty `backendBaseURL`** — fail only
  under a local `BACKEND_URL=off`; CI is green. Minor test-hygiene.
