# Cruxwing launch runbook — the human path to go-live

The autonomous launch-prep is done: backend hardened + metered, StoreKit IAP +
Stripe billing, sandboxed keyless build, consent + account deletion, privacy/
terms/security pages, App Store listing + review map, funnel telemetry. What
remains is **human-gated** — accounts, secrets, and hosts that code can't create.
This is the ordered path. Each step lists the action, the file/command, and the
acceptance check. Dependencies flow top→down; don't skip ahead.

> Secret rotation and Apple-account steps are HUMAN calls by design — never
> committed, never fabricated. The gitignored SECRET_ROTATION_PLAN.md and
> docs/dispatch-keys-runbook.md are your console-by-console rotation guides.

---

## Phase 0 — Secrets & backend truth (gates everything)

1. **Rotate the compromised keys.** The client-baked provider keys and the
   git-history `config.js` credentials are COMPROMISED. Rotate every one in its
   provider console (OpenAI, Anthropic, Google, Deepgram, AssemblyAI, Stripe,
   SMTP, Google OAuth) and place the NEW values only in the server env. Follow
   your local SECRET_ROTATION_PLAN.md §7 checklist + docs/dispatch-keys-runbook.md.
   - **Accept:** rotation checklist fully checked; no old key still valid.
2. **Fill the production env** from `deploy/api/.env.production.example` — JWT PEMs
   (`\n`-escaped one-line), `FRONTEND_ORIGIN`, `LLM_ANON_RATE_LIMIT`,
   `LLM_USER_RATE_LIMIT`, provider keys, `STUB_OAUTH` unset.
   - **Accept:** prod boot without the JWT PEMs exits non-zero (fail-fast).

## Phase 1 — Deploy the backend API (gates the app, landing, funnel)

3. Stand up the API at `https://api.<domain>` per `docs/deploy.md` (systemd unit
   + nginx + `initDb()` self-applies `functions/db/schema.postgres.sql`).
   - **Accept:** `curl -fsS https://api.<domain>/health` → 200; restart does not
     rotate JWKS.
4. **Configure StoreKit receipt verification** (else IAP fails closed):
   `npm i @apple/app-store-server-library`, put Apple's public Root CAs in
   `APPLE_ROOT_CA_DIR`, set `APPLE_IAP_BUNDLE_ID` / `APPLE_IAP_ENVIRONMENT` /
   `APPLE_IAP_APP_APPLE_ID` (see `deploy/api/.env.production.example` +
   `functions/appleReceiptVerifier.js`).
   - **Accept:** with it unset, `POST /api/billing/storekit` → 503 (fail-closed).
5. **Set the operator comp code** (optional) — `FOUNDER_ACCESS_CODE` (≥16 chars)
   + `FOUNDER_ACCESS_LIMIT`. Redeeming works with no email (device account).

## Phase 2 — Deploy the landing (parallel with Phase 1)

6. Deploy `web/landing/` to a static host with **clean-URL routing** so
   `/privacy` `/terms` `/security` resolve (they're `.html` files) and
   `sitemap.xml` / `robots.txt` are served at root.
   - **Accept:** `https://<domain>/privacy` loads; the pricing cards hydrate from
     `https://api.<domain>/api/billing/plans`.
7. **HubSpot + analytics** [M13c-2]: set `portalId`/`formGuid` in
   `web/landing/hubspot.js`; add a **cookieless** analytics provider only
   (Plausible/Fathom — GA/cookie trackers would break the privacy policy's
   no-tracking claim, per D19).

## Phase 3 — Apple Developer / App Store Connect (the big human block)

8. **Confirm the permanent bundle id.** `Support/Info.plist` ships
   `com.meetgpt.macapp`; D14/D16 flag `com.cruxwing.mac` as a pre-submission
   revisit. ⚠ PERMANENT once submitted — decide now.
9. **Trademark check** on "co-pilot" branding (App name is "Cruxwing"; see
   `launch/app-store-listing.md`).
10. Install two certs: **Apple Distribution** (app) + **3rd Party Mac Developer
    Installer** (pkg). Download a **Mac App Store provisioning profile**.
11. In App Store Connect: create the app record; **create the IAP products** with
    the exact ids from `functions/storeKit.js` (subscriptions auto-renewable,
    packs consumable) [M11b-4].
12. Prepare: screenshots + optional app preview; an **email+password demo
    account** for App Review Sign-In (NOT OTP — a reviewer can't get the code);
    review notes from `launch/app-review-readiness.md`.

## Phase 4 — Build, verify, upload

13. Verify a StoreKit sandbox purchase end-to-end against the real verifier
    [M11b-2b-verify]: a sandbox tester buys → `POST /api/billing/storekit` grants
    the plan.
14. Build + package the MAS pkg:
    `MAS_PROVISION_PROFILE=~/Cruxwing_MAS.provisionprofile bash appstore.sh`
    (runs `build.sh` keyless + `assert-no-baked-secrets.sh` before signing;
    aborts if any provider key is baked).
    - **Accept:** the secret gate passes on the shipped binary; `dist/MeetGPT.pkg`
      is produced and installer-signed.
15. Upload with Transporter or `xcrun altool --upload-app -f dist/MeetGPT.pkg`.

## Phase 5 — Submit & launch

16. Paste `launch/app-store-listing.md` fields into App Store Connect, attach the
    review notes, submit for review [M14c].
17. On approval: run the launch channels [M15c] — outreach, campaigns. The
    funnel (`/api/funnel` + landing/app emitters) captures the results honestly;
    read spend from the durable cost frames (`costSummarySince`).

## Not launch-blocking (self-host / later)

- **Slack in-app OAuth** [M5c] — needs a Slack app registration; the env-token
  connector works meanwhile.
- **Hosted-MCP + tracker write-back E2E** [M5d] — needs connected accounts.
- **Device sandbox verification** [M8c] — mic + ScreenCaptureKit + OAuth loopback
  under the sandbox on a real machine.
- **Postgres-backed rate limiter** [M7d-2] — only when scaling beyond one node.
