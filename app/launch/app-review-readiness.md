# App Review readiness — Cruxwing (M14b)

A guideline→shipped-state map for the first Mac App Store submission, with the
evidence in-repo, the honest gaps, and the reviewer notes. Cited file paths are
checked to exist by `test/appReviewReadiness.test.js` so this map can't drift
into claiming something that isn't there.

## Guideline mapping

| Guideline | State | Evidence / notes |
| --- | --- | --- |
| **2.1 App Completeness** — no placeholders, works on first run | Ready + [HUMAN] demo acct | Onboarding pre-flight `Sources/MeetGPT/Views/OnboardingView.swift` (optional sign-in step; recording never blocked); sessions persist `Sources/MeetGPT/Persistence/SessionStore.swift`. Reviewer needs a demo login (below). |
| **2.3 Accurate Metadata** — honest listing | Ready | `launch/app-store-listing.md` (length + honesty tested); permission strings now branded Cruxwing; no compliance claims in store copy. |
| **2.5.2 Sandbox / no private API** | Ready | Dist build is sandbox-mandatory: `build.sh` ties `MEETGPT_DIST` → `Support/MeetGPT.sandbox.entitlements`; keyless binary enforced by `assert-no-baked-secrets.sh`. |
| **3.1.1 In-App Purchase** — digital goods via IAP | Partial — [HUMAN] products | StoreKit catalog `functions/storeKit.js`; client `Sources/MeetGPT/Integrations/StoreKitPurchaser.swift`; server receipt bridge `functions/storeKitBridge.js` with a real Apple verifier `functions/appleReceiptVerifier.js` (fail-closed until configured). GAP: create products in App Store Connect (M11b-4) + configure the verifier (M11b-2b-verify). |
| **5.1.1 Privacy — policy + manifest** | Ready | Privacy Policy `web/landing/privacy.html`; privacy manifest `Support/PrivacyInfo.xcprivacy` (no tracking, app-functionality only). |
| **5.1.1(v) Account deletion in-app** | Ready | `Sources/MeetGPT/Views/SettingsView.swift` "Delete account" → `Sources/MeetGPT/Integrations/AccountDeletion.swift` → `DELETE /auth/account`. |
| **5.1.2 Sign in with Apple** | Conditional | **Default ship:** first-party only (email OTP / email+password / phone) → 5.1.2 is not triggered. Connected Apps **"Connect Google Calendar"** is a data connector, not account login. **When** `Config.socialAccountLoginEnabled` is turned on (native Apple + Google **account** buttons in `SignInSheet`), 5.1.2 **applies** — Apple button is equal-prominence above Google; entitlement `com.apple.developer.applesignin` is in `Support/MeetGPT.entitlements` + sandbox variant; backend `POST /auth/apple/native` + `POST /auth/google/native`. Keep the flag off until ASC capability + Apple keys are verified. |
| **Recording consent** | Ready | `Sources/MeetGPT/Views/RecordingConsentSheet.swift` before the first recording; user-responsibility clause in `web/landing/terms.html`. |
| **Export compliance / encryption** | Ready | `ITSAppUsesNonExemptEncryption` = false in `Support/Info.plist` (standard HTTPS/TLS only). |
| **Permission usage strings** | Ready | Mic / screen-capture / speech strings in `Support/Info.plist`, branded Cruxwing. |

## Three Google meanings (reviewer clarification)

| Surface | What it is | Not |
| --- | --- | --- |
| **Account → Continue with Google** (flagged) | Platform account login via OpenID (`/auth/google/native`) | Calendar access |
| **Connected Apps → Connect Google Calendar** | Read-only Calendar/Docs/Sheets connector (`GoogleAuth.swift`) | Account login |
| **No Google** | First-party email/password/phone still work | — |

## Reviewer notes (paste into App Review "Notes")

- **Demo account:** provide an **email + password** account (NOT the email-OTP
  flow — a reviewer can't receive the one-time code). The email+password path is
  live (`/auth/password/login`); create a reviewer account and put the
  credentials in App Review "Sign-In Information". [HUMAN]
- **How to try it without a real meeting:** start a recording and speak into the
  mic (or play any audio) — a live transcript appears. Then press any one-click AI
  action (e.g. Summary) to see a managed-AI result. No external meeting needed.
- **On-device by default:** transcription runs locally; the first run downloads a
  ~150 MB on-device speech model (progress is shown). No provider keys ship in the
  app — AI is proxied through our backend.
- **"Connect Google Calendar" is Google Calendar / Workspace data**, used only to
  read the user's calendar (and optional Docs/Sheets) in Connected Apps. It is
  not the account login. Account login (when enabled) uses Sign in with Apple and
  a separate "Continue with Google" button on the Sign in sheet.
- **Recording asks for consent first;** the app prompts the user to confirm they
  have participant consent before the first recording.

## Open items before submit (HUMAN)

- Demo email+password account in App Review Sign-In Information.
- Screenshots + optional app preview (localized as needed).
- App Store Connect IAP products matching `functions/storeKit.js` ids (M11b-4).
- Configure + verify the Apple receipt verifier against a sandbox purchase
  (M11b-2b-verify) so IAP grants for real.
- Confirm the permanent bundle id (D14/D16) and a trademark check on "co-pilot".
- Before enabling `Config.socialAccountLoginEnabled`: enable **Sign in with Apple**
  on the Mac App ID, configure `APPLE_*` backend secrets, and re-test 5.1.2
  equal-prominence UI on the Sign in sheet.
