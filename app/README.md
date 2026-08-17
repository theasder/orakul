# Cruxwing for macOS

Native macOS app (SwiftUI + ScreenCaptureKit) that transcribes **any** meeting
— Zoom, Meet, Teams, Telegram, offline — by capturing system audio directly,
the way Granola does it. No platform‑specific hooks, no BlackHole/Loopback.

- **System audio**: `ScreenCaptureKit` (macOS 13+), audio‑only stream
- **Microphone**: `AVAudioEngine`
- **Transcription**: OpenAI Whisper API (swappable — see `TranscriptionService`)
- **AI responses**: OpenAI Chat Completions, streaming
- **Prompts**: the same Quick Prompts ported from the Chrome extension

## Build

```sh
cd mac
./build.sh
open /Applications/Cruxwing.app
```

`build.sh` runs `swift build -c release`, wraps the binary into a
`Cruxwing.app` bundle with the correct `Info.plist` and app icon
(`Support/AppIcon.icns`), **installs it to `/Applications`**, and codesigns
with the entitlements in `Support/MeetGPT.entitlements`.

Installing to a fixed path keeps the bundle location stable across rebuilds,
which keeps macOS TCC (Screen Recording / Microphone) grants attached. Knobs:

```sh
./build.sh                          # → /Applications/Cruxwing.app
MEETGPT_APP_DIR=~/Applications ./build.sh   # install elsewhere
MEETGPT_NO_INSTALL=1 ./build.sh     # run from ./build/Cruxwing.app instead
./build-intel.sh                    # → dist/Cruxwing-Intel.zip (x86_64)
```

If `/Applications` isn't writable the script falls back to the in-repo
staging copy and prints how to install with `sudo`.

> Requires macOS 13+, Xcode 15+ command line tools (`xcode-select --install`).

### App icon

The icon is generated from the tightly cropped, transparent
`../web/landing/assets/icon-512.png` into `Support/AppIcon.icns`. Run
`./generate-icon.sh` after changing the logo. The generator renders every ICNS
slot directly without adding a second background or macOS-style inset.

### Intel release

`./build-intel.sh` cross-compiles a release-optimized Intel-only executable
(`x86_64-apple-macosx13.0`), verifies its architecture and signature, checks
that no local provider keys were baked in, and writes
`dist/Cruxwing-Intel.zip`. The internal Swift module and executable remain
`MeetGPT` for compatibility; Finder, the menu bar, and the app bundle use
Cruxwing. This script creates a locally signed test artifact. Gatekeeper-ready
distribution still requires a Developer ID signature and Apple notarization.

## Configuration (`.env`)

Provider keys are **no longer entered in the UI**, and as of 2026-07-26 they are
**left empty in `.env` by default** — chat is served through the backend
gateway (`LLM_GATEWAY=backend`, keys server-side in the backend's own `.env`) and
cloud transcription uses a short-lived Deepgram token granted by the backend. A
release build strips these keys regardless (`build.sh` `SECRET_VARS`); keeping
dev builds keyless too means dev and release exercise the same serving path.

Fill a provider key below only for a deliberate `LLM_GATEWAY=direct`/`ensemble`
local experiment. Whatever remains is baked in at build time from `.env`
(gitignored). Copy the template and fill in what you use:

```sh
cd mac
cp .env.example .env      # then edit; build.sh bakes keys into a gitignored Secrets.swift
```

| Key | Used for |
|-----|----------|
| `OPENAI_API_KEY` | GPT models + Whisper transcription |
| `ANTHROPIC_API_KEY` | Claude models |
| `GOOGLE_AI_API_KEY` | Gemini models |
| `DEEPGRAM_API_KEY` | live diarized transcription |
| `ASSEMBLYAI_API_KEY` | at-stop speaker diarization |
| `GOOGLE_CLIENT_ID` | Google Workspace sign-in (Calendar, Docs, Sheets, Slides, Forms; Desktop-app OAuth client with PKCE) |
| `GOOGLE_CLIENT_SECRET` | Token exchange for that same Google Desktop-app OAuth client |
| `BACKEND_URL` | gateway / brainstormer / fact-check backend. **Required** with `LLM_GATEWAY=backend`: empty or `off` means no cloud LLM at all |
| `DEEPSEEK_API_KEY` `DASHSCOPE_API_KEY` `ZHIPU_API_KEY` `MOONSHOT_API_KEY` | Chinese providers (catalog models + Council mode) |
| `LLM_GATEWAY` | `direct` (default) · `backend` (managed, tier-enforced) · `ensemble` (Council) |
| `TRANSCRIPTION_ENGINE` | `local` (on-device), `whisper` (OpenAI), or `deepgram` (`server` wired but hidden until VPS Whisper) |
| `TRANSCRIPTION_CHUNK_SECONDS` | 2–15, chunked engines (default 6) |
| `TRANSCRIPTION_LOCAL_MODEL` | WhisperKit model for `local`: tiny/base/small/large-v3 (default base) |
| `DEFAULT_TIER` | baseline plan `free`/`pro`/`premium` (users can't pick their plan) |

## Plans & models (tariff)

Users don't type keys and **don't pick their plan** — it's earned by behaviour
(`Tariff/TierPolicy.swift`, all thresholds in one place):

- **7-day Premium trial** on first launch (hook new users).
- Then **earned by engagement**: Pro at ≥3 meetings or ≥20 AI prompts; Premium
  at ≥10 meetings or ≥60 prompts.
- Floored at `DEFAULT_TIER` (`.env`); a backend can become the source of
  truth per user later.

Behaviour is tracked in `Tariff/UsageTracker.swift` (recorded meetings + AI
requests). Settings shows the plan and what unlocks next. Within their plan
users pick a **model** (Settings → AI model); locked models show which plan
unlocks them. The tier→model map lives in `AI/LLMModel.swift`:

| Plan | Models |
|------|--------|
| Free | GPT-4o mini, Gemini Flash |
| Pro | GPT-4o, Claude Sonnet |
| Premium | GPT-5, Claude Opus, Gemini Pro |

Every AI call routes through the `LLMGateway` protocol (`AI/LLMGateway.swift`).
Set `LLM_GATEWAY=backend` (with `BACKEND_URL`) and chat is served by the
backend's **managed gateway** (`POST /api/llm/chat`): provider keys stay
server-side and the tier→model policy is enforced by the server — signed-in
users get their account tier, anonymous callers get free. `direct` (default)
uses the baked-in provider keys. Transcription (engine + chunk size) is
`.env`-configured, not in the UI.

## Account & sign-in

Sign-in (Settings → Account, and inside the paywall) supports three methods —
all issuing the same JWT session (RS256 access + rotating refresh tokens):

- **Email code** (default) — one-time code by email, no password.
- **Email + password** — bcrypt-hashed (cost 12) server-side; registering with
  an existing OTP-only email claims that account; uniform-timing login.
- **Phone** — SMS codes via Twilio Verify (`TWILIO_*` backend env).

Google/Apple SSO: backend web flows power the extension; Mac native account
login (`POST /auth/apple/native`, `/auth/google/native` + `AppleAccountAuth` /
`GoogleAccountAuth`) ships behind `Config.socialAccountLoginEnabled` (default
off) until Sign in with Apple is enabled on the App ID and backend `APPLE_*`
keys are verified. Calendar access remains a separate Connected Apps connector.

## Paywall & subscriptions (Stripe)

On launch a **mandatory paywall** runs: intro (benefits) → pricing → Stripe
Checkout in the browser → automatic confirmation once the webhook lands (or an
explicit **Continue with Free**; it re-prompts once when the trial lapses).
Tariffs come from the backend (`GET /api/billing/plans`): Pro/Premium ×
monthly/annual plus a limited-time launch offer (`LAUNCH_OFFER_ENDS`), with
**regional pricing** (multipliers by country, `STRIPE_REGIONAL_MULTIPLIERS`;
the app sends its locale region). A purchase becomes a hard tier floor locally
and activates the plan server-side (`checkout.session.completed` webhook →
`activateUserPlan`), which the managed LLM gateway already enforces. Backend
env: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` (endpoint
`{BASE_URL}/api/billing/webhook`). Subscribing requires the wheespr sign-in —
the paywall includes an inline email-code step.

## Auto — intelligent model orchestration (default)

The model picker's **Auto** setting (the recommended default for new installs)
means Cruxwing picks — and combines — models per request instead of using one
fixed model. Each request is scored (context size, analysis-style asks,
images) and routed to the most appropriate model **your plan allows**; higher
tiers unlock stronger combinations:

| Plan | light | heavy / hard |
|------|-------|--------------|
| Free | GPT-5.4 mini | Gemini Flash |
| Pro | GPT-5.4 mini | Claude Sonnet 5 |
| Premium | GPT-5.4 mini | Claude Fable 5 · hardest requests run the **Council** (US+CN panel + synthesis) when its providers are configured |

Selecting a concrete model disables orchestration for that session. The logic
lives in `AI/AutoOrchestrator.swift`; routing applies live when you switch.

## Council mode (US + CN model ensemble)

`LLM_GATEWAY=ensemble` answers every request with a **panel of models mixing
American frontier and Chinese providers**, then a **chairman** model
synthesizes one streamed answer (mixture-of-agents / llm-council pattern —
we adopted the pattern, not the Python frameworks, which can't embed in a
native app; the thin layer lives in `AI/EnsembleGateway.swift`).

- Default panel (ids verified 2026-07): GPT-5.5 + Claude Fable 5 (US) ·
  DeepSeek V4 Pro + Qwen 3.7 Max + GLM-5.2 (CN). Override with
  `ENSEMBLE_PANEL=provider/model,…`; chairman defaults to your selected model
  (`ENSEMBLE_CHAIRMAN` overrides).
- Flow: silent parallel fan-out (75 s per-member timeout) → quorum ≥2 →
  chairman reconciles agreements/disagreements and streams the final answer.
  Panel failures are tolerated up to quorum and named beyond it.
- All Chinese providers speak the OpenAI dialect (endpoints live-probed), so
  they run through one shared client; keys in `.env`.
- **Privacy trade-off, stated plainly:** council mode sends your meeting
  content to every panel provider, including Chinese ones, under their
  respective data policies. It is opt-in via `.env` and off by default.
- Cost/latency: roughly panel-size × a single call, plus the synthesis.

## Co-pilot (brainstormer)

Set a **Goal of this call** in the sidebar. While recording, an async worker
sends the goal + live transcript to the brainstormer and surfaces a few
**blind-spot suggestions** (question · risk · missing info · advice), each
dismissable or promotable into the assistant with **Ask**.

**Credit burn (when Brainstorm is on):** each scan that reaches the backend
reserves compute credits — Free **1**, Pro **3**, Premium **4**, Ultra **5**,
plus **+1** when connected-app grounding contributed. Turn the toggle off to
stop the loop and the spend.

**Paid probes:** Pro+ rotates through workflows (`brainstorm` → `whattoask` →
`risks` → `unresolved` → `factcheck` → `advice` → `dispute`), each with that
workflow’s connector graph and skills. Premium+ also samples a second workflow
in the same tick. Retrieved hits are **compressed** by a fast model into ≤8
goal-relevant bullets before the blind-spot scan (truncate fallback on failure).
Free stays transcript-only (~120s); Pro+ wakes ~every 90s.

- With `BACKEND_URL` set, it calls `POST /api/brainstorm` — the backend holds
  the LLM key (and, later, MCP/tool/data enrichment). Backend needs its own
  `OPENAI_API_KEY` (see the root `.env.example`).
- With `BACKEND_URL` empty, the app runs it **LLM-only** through the selected
  model — usable immediately, no backend required.
- Toggle it under Settings → Co-pilot. It only runs once a goal is set.

### Research (goal-driven, via Connected apps)

With a goal set and at least one connected app, a **Research** button appears
under the goal field. It fans out to every connected app's search tool in
parallel — Notion `notion-search`, Fireflies keyword search over past meetings,
plus whatever a custom server exposes — using only the goal as the query.
Findings land as removable **Research · App** context chips, so they ground the
Quick Prompts, the ask box, the brainstormer, and the fact-checker alike.
Re-running Research replaces the previous round. Per-app failures are skipped
silently; tool arguments are resolved from each server's live schema.

## Call detection

Two detectors feed the "start recording?" notification (Settings → Call
detection, with an "Ignore music / video" suppression toggle):

- **App activation** — a known meeting app (Zoom, Teams, Webex, Slack,
  Discord, FaceTime) comes to the foreground.
- **Screen-content recognizer** — every ~20 s the on-screen window titles are
  scanned through the ScreenCaptureKit stack (the Screen Recording grant
  already exists for audio), catching **browser calls** — Google Meet, Zoom
  web, Webex, Teams, Whereby, Jitsi — and calls running behind other windows,
  both invisible to the frontmost-app heuristic.
- **Acoustic detector** — CoreAudio's device-state signal ("the default
  microphone is in use by *some* process") correlated with a running
  communication app (Zoom, Teams, WhatsApp, Telegram, Signal, Viber, Skype,
  Discord, Slack, FaceTime) catches **spontaneous voice/video calls** with no
  calendar entry and no recognizable window — proprietary VoIP included.
  Privacy boundary, stated plainly: only the device *state* is read — Cruxwing
  never captures or analyzes audio content before you press Record, which is
  also why deeper "audio signature" classification is deliberately out of
  scope for this detector.

## First run

1. Fill in `.env` (above) and `./build.sh`.
2. Launch `Cruxwing.app`. macOS will ask for **Screen Recording**, **Microphone**,
   and **Notifications** permission — grant them. Quit and relaunch after granting.
3. Settings (⌘,) → pick your **model** (your plan is set by your subscription).
4. Press **Record** (or ⌘R). A live transcript populates as chunks transcribe.
5. Click any Quick Prompt → streaming AI response appears on the right.

## Menu-bar mode

A menu-bar item (brain glyph) is always present; it turns into a record glyph
while capturing. Click it for a compact panel with:

- **Start / Stop recording** and a live timer — control a session without the
  main window in focus
- **Open Cruxwing** — raise the main window
- **Show overlay** — the floating co-pilot card (below)
- **Settings…** and **Quit**

The main window still works exactly as before — the menu bar is an additional
surface, not a replacement.

## Floating overlay

**Menu bar → Show overlay** opens a slim always-on-top card (all Spaces,
full-screen apps included) so the co-pilot stays visible over the meeting
window: recording status + timer, a record/stop button, the call goal, and the
latest blind-spot suggestions — hover a suggestion for its detail, **↑** to
send it to the assistant, **×** to dismiss. The panel is non-activating
(clicking it never steals focus from the call) and draggable anywhere.

## Architecture

```
┌────────────────────┐   ┌──────────────────────┐
│ ScreenCaptureKit   │   │ AVAudioEngine        │
│ (system audio)     │   │ (microphone)         │
└─────────┬──────────┘   └──────────┬───────────┘
          │                          │
          ▼                          ▼
   AudioChunkBuffer          AudioChunkBuffer
   (→ mono 16 kHz WAV)       (→ mono 16 kHz WAV)
          │                          │
          └──────────┬───────────────┘
                     ▼
          TranscriptionService  ← swap for whisper.cpp (local)
                     │
                     ▼
            AppState.transcript  ──►  OpenAIClient (Chat)
                                         │
                                         ▼
                                     AI Response
```

## Local transcription (on-device, no cloud)

Set `TRANSCRIPTION_ENGINE=local` in `.env` and rebuild. Chunks are
transcribed **on-device** by WhisperKit (Core ML on the Apple Neural Engine) —
no audio leaves the Mac and no transcription API key is needed. The model
(`TRANSCRIPTION_LOCAL_MODEL`, default `base`, multilingual) downloads once on
first use (~150 MB for base) and is cached; the first chunk of the first
session waits for that download, everything after is faster than real time on
Apple silicon.

**VAD:** silent chunks are detected (frame-level energy gate) and skipped
before they reach any chunked engine — saving API cost and local compute.
`TRANSCRIPTION_VAD=off` disables it. The full session is still recorded for
diarization; only the transcription call is skipped. `TranscriptionService` remains a protocol —
`TranscriptionFactory` picks the engine, so other backends stay drop-in.

## Cruxwing Whisper (large-v3 on our servers) — infrastructure only

Wired but **not exposed in Settings** yet (`Config.serverWhisperEnabled = false`).
When the VPS Whisper upstream is ready:

1. Set `WHISPER_UPSTREAM_URL` (+ optional key/model) on the API host
2. Flip `Config.serverWhisperEnabled` to `true` (and/or teach it from env)
3. Settings will show **Accurate — large-v3 on Cruxwing** via `selectableCases`

Client path: `ServerWhisperTranscription` → `POST /api/transcribe` (sign-in +
compute credits). Prefer an OpenAI-compatible faster-whisper serving `large-v3`.
Optional local/dev: `WHISPER_ALLOW_OPENAI_FALLBACK=1` uses OpenAI `whisper-1`.

## Distribution (signed + notarized)

`./notarize.sh` builds, signs with your **Developer ID Application** identity
(hardened runtime + secure timestamp), submits to Apple's notary service,
staples the ticket, and produces a Gatekeeper-ready `dist/Cruxwing.zip`.
One-time setup (paid Apple Developer account): install the Developer ID
certificate, then run notarytool store-credentials (profile "meetgpt-notary").
Local dev builds don't need any of this — `build.sh` keeps the free
self-signed identity flow.

## Troubleshooting: "I granted Screen Recording but it still fails"

This almost always means your ad‑hoc build was re‑signed and macOS now
considers it a different app than the one in the allow‑list.

### Fast fix (one rebuild)

```sh
cd mac
./reset-permissions.sh            # wipes TCC for com.meetgpt.macapp
# System Settings → Privacy & Security → Screen Recording → remove any old Cruxwing or MeetGPT entry
# System Settings → Privacy & Security → Microphone        → same
open /Applications/Cruxwing.app
# press Record → macOS prompts → grant
# quit Cruxwing and relaunch (grants only take effect after relaunch)
```

### Permanent fix (stable dev certificate)

Ad‑hoc (`codesign --sign -`) produces a new signature every build, so
TCC re‑prompts forever. Create a one‑time self‑signed code‑signing
certificate and reuse it. No Apple Developer account needed.

**Scripted (recommended):**

```sh
cd mac
./create-signing-cert.sh   # creates "MeetGPT Dev" in your login keychain
./build.sh                 # auto-detects and signs with it
```

`create-signing-cert.sh` is idempotent (re-running is a no-op). It asks for
your macOS **login** password once so `codesign` can use the key without a
dialog on every build.

**Manual (Keychain Access GUI), if you prefer:**

1. Open **Keychain Access** → menu **Keychain Access → Certificate
   Assistant → Create a Certificate…**
2. Name: `MeetGPT Dev`, Identity Type: **Self Signed Root**,
   Certificate Type: **Code Signing**, then Create.
3. Find the cert in Keychain, mark it **Always Trust** for code signing.
4. Rebuild:
   ```sh
   ./build.sh          # auto-detects "MeetGPT Dev" in codesigning identities
   ```
   or pin it explicitly:
   ```sh
   MEETGPT_SIGN_ID="MeetGPT Dev" ./build.sh
   ```

Either way, from now on TCC remembers the permission across rebuilds.

## Ask & attach

The assistant panel has a chat composer. Type any question (press ↵) — it runs
against the live transcript + context like the Quick Prompts do. The **+**
button is an attach / tools menu:

- **Image** — pinned as a thumbnail and sent to the OpenAI **vision** model with
  your question (needs a vision-capable `chatModel`, e.g. `gpt-4o`).
- **File** — text/PDF/Word/RTF/Markdown extracted into **Context**.
- **Audio / Video** — the audio track is decoded to 16 kHz mono and
  transcribed, then added to **Context**.
- **Start from a prompt** / **Save as a prompt** — load any built-in or custom
  prompt into the box to tweak before sending, or save your text as a reusable
  custom prompt. Custom prompts also appear as chips with right-click edit/delete.

## Context sources & sets

The sidebar **Context** block (folded into every AI prompt) accepts more than
files. **Add source** ▸:

- **Files** — text/PDF/Word/RTF/Markdown.
- **Google Doc / Sheet / Slides / Form** — paste an explicit link; text is
  pulled through your Google sign-in. Forms includes a bounded page of responses
  and omits provider email metadata; Slides includes visible text and speaker
  notes. If you connected before these scopes existed, **reconnect Google**.
  Settings has per-service checkboxes: a disabled service is excluded from the
  OAuth grant itself, so the token cannot touch it.
- **Notion page** — paste the link; fetched through your Notion connection
  (Settings → Connected apps → Notion → **Connect**, one click, no keys).
- **Fireflies / Agenda** — quick buttons when those connections exist.

**Sets** ▸ **Save current as set…** pins the current files + notes as a reusable
bundle; apply or delete saved sets from the same menu — so recurring calls start
from a fixed context instead of rebuilding it each time.

## Team sources (token connectors — the no-MCP fallback)

When a tool hosts **no MCP server** (Slack's bot APIs) — or MCP is impractical — Cruxwing falls back to direct **API-token connectors**
(keys in `.env`; Settings → Team sources shows what's configured):

- **Slack** (`SLACK_BOT_TOKEN` + `SLACK_CHANNEL_IDS`) — reads designated
  channels, posts alerts.
- **Confluence** (`CONFLUENCE_SITE/EMAIL/TOKEN`) — CQL search over docs;
  prefer the **Atlassian** entry in Connected apps when MCP is available.

All configured connectors join the co-pilot's **Research fan-out** alongside
MCP servers, aggregating team data around the call goal.

**Channel watcher** (Settings → Team sources): a bot-style scanner polls the
designated Slack channels (~60 s) for your **keyword rules** (e.g.
`incident, outage, security`). New matches trigger a notification, append an
auditable line to `team-watch.log` (Application Support/MeetGPT), and can
optionally auto-acknowledge into the channel (`TEAM_WATCH_AUTO_ACK=on`,
default off).

## Connected apps (MCP)

`Settings → Connected apps` links orakul to work apps through their hosted
**MCP servers**. Servers with dynamic client registration use a keyless flow;
providers such as Asana V2 and HubSpot require their own pre-registered OAuth
app at build time:

1. Click **Connect** → the SDK discovers the server's OAuth metadata
   (RFC 9728/8414), registers Cruxwing on the fly as a public client
   (RFC 7591 dynamic client registration), and opens your browser for consent
   (OAuth 2.1 + PKCE, loopback redirect on `127.0.0.1`).
2. The token lands in your **Keychain**; reconnects are silent.
3. Use it: Context → **Add source → Connected app…** picks a server + one of
   its tools (e.g. Notion `notion-fetch`, Fireflies `fireflies_get_transcripts`)
   and folds the text result into the meeting context.

Built-in catalog (endpoints live-verified 2026-08): **Notion, Fireflies,
Linear, Atlassian (Jira), Intercom, Sentry** — plus **Asana V2** (appears once
`ASANA_CLIENT_ID/SECRET` are in the private `.env`; register exactly
`http://127.0.0.1:52703/callback`) and **HubSpot** (appears once
`HUBSPOT_CLIENT_ID/SECRET` are present; register redirect
`http://127.0.0.1:52700/callback`) — plus **Add custom server…** for any other
Streamable-HTTP MCP server. Adding a catalog app is one line in
`MCP/MCPCatalog.swift`.

> Google Analytics and Yandex Metrica host **no MCP servers** (probed): a
> meeting app also cannot rewire HubSpot↔GA/Metrica linkage — that lives in
> those platforms' own admin consoles. To pull GA/Metrica data into meeting
> context, run any community GA/Metrica MCP bridge and add it via **Add custom
> server…**; HubSpot data flows in natively via the HubSpot connection above.

> Why loopback instead of a `meetgpt://` redirect: some servers (Fireflies)
> reject custom-scheme redirect URIs at authorize time; every probed server
> accepts loopback, so it's the one pattern that works everywhere.

Fireflies and Notion connect **exclusively** this way — the old token sheets
and backend proxies (Fireflies key broker, Notion OAuth proxy) are retired.

## Integrations

Configure them in `Settings → Integrations` (⌘,). Calendar folds its result
into the meeting **Context** (used by every AI prompt); AssemblyAI re-labels
the transcript by speaker.

### Fireflies

Settings → Connected apps → Fireflies → **Connect** (keyless, per-user OAuth in
the browser). The sidebar **Fireflies** button then imports your latest
transcript through the MCP tools (`fireflies_get_transcripts` →
`fireflies_get_transcript`).

### Notion

Settings → Connected apps → Notion → **Connect** (keyless — PKCE + dynamic
client registration; no integration to create, no backend). "Add source →
Notion page…" fetches pasted links through the `notion-fetch` MCP tool.

### Speaker diarization (AssemblyAI)

Paste an AssemblyAI API key. Live captions stay on the fast chunked path; when
you **Stop**, the recorded remote audio is sent to AssemblyAI with speaker
diarization and the `[them]` side of the transcript is replaced with clean
**Speaker A / B / C** turns (your mic lines stay **You**), merged by time. A
**Diarize** button in the transcript header re-runs it on demand. Each
speaker gets a stable distinct color; right-click any diarized line to
**rename the speaker** (Speaker A → a real name) — the rename applies across
the transcript and in everything the AI sees. Async REST
(upload → `speaker_labels` → poll); the full-session audio is capped at ~60 min.

### Live diarization (Deepgram)

For **live** inline speaker labels instead of at-stop, set
`Settings → Transcription → Engine` to **Deepgram** and paste a Deepgram key.
The captured audio is streamed over a WebSocket (`nova-3`, `linear16`); the
system side is diarized into **Speaker A / B / C** and your mic stays **You**,
with transcript lines appearing in real time, speakers already attached. Whisper
and AssemblyAI are bypassed in this mode. Two sessions run (system + mic); a
`KeepAlive` holds the socket open and `CloseStream` flushes finals at stop.

### Google Calendar, Docs, Sheets, Slides, and Forms

One button — **Sign in with Google** — uses OAuth 2.0 Authorization Code with
PKCE. Cruxwing starts a loopback listener on a random local port for each
attempt and supplies `http://127.0.0.1:<random-port>/callback` as the redirect.
There is no backend callback or custom URL scheme. The token exchange sends the
Desktop client's ID and client secret in addition to its PKCE verifier. Access
is limited to the services enabled in Settings. Explicit-link imports do not
request Drive-wide discovery. `drive.file` is used only to create/manage files
the app itself creates, such as a new spreadsheet export.

It needs exactly **one** Google OAuth client, configured a single time (not
per user):

1. In [Google Cloud Console](https://console.cloud.google.com/), create or select
   a project and enable the **Google Calendar API**, **Google Docs API**,
   **Google Sheets API**, **Google Slides API**, **Google Forms API**, and
   **Google Drive API**.
2. Configure the OAuth consent screen / Google Auth Platform audience. For an
   External app in **Testing**, add each developer or tester under **Test
   users**. Alternatively publish the app when its consent configuration is
   ready. Google Workspace organizations may use an Internal audience where
   appropriate.
3. Go to **APIs & Services → Credentials → Create credentials → OAuth client
   ID** and choose application type **Desktop app**.
4. Put both values from the Desktop credential in the build-time environment
   and rebuild:

   ```sh
   # .env
   GOOGLE_CLIENT_ID=your-desktop-client-id.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=your-desktop-client-secret
   ./build.sh
   ```

   Do not add an iOS reversed scheme to `Info.plist`. Google permits the random
   loopback redirect for Desktop-app clients, so there is no fixed redirect URI
   to enter in the credential form.

   The Desktop client secret is embedded in Cruxwing. Under Google's
   installed-app model, native apps cannot keep client credentials
   confidential, so this value identifies the OAuth client but must not be
   treated like a confidential server credential. Never substitute the
   backend Web client's secret; that separate secret remains server-side only.

After that, **Settings → Connected Apps** shows **Sign in with Google** /
**Disconnect**. Calendar provides the current event and agenda; Docs, Sheets,
Slides and Forms import the explicitly pasted resource. Project-wide Drive
search is intentionally disabled because its metadata scope is restricted.

> OAuth tokens are stored in the macOS Keychain. The Desktop client ID and
> secret are build-time native-app credentials; neither is a substitute for a
> confidential backend secret.

## Not yet

- **Managed backend gateway** — proxy LLM/transcription per tier so keys and
  tariff enforcement move server-side (the `LLMGateway` seam is ready)
- **Brainstormer data enrichment** — the worker + backend `/api/brainstorm`
  endpoint ship LLM-only; the remaining depth is wiring the backend's held
  MCP/tool/data connections into `enrich()` so suggestions cite real external
  data, plus tier/auth on the endpoint
- Local `whisper.cpp` integration (protocol + audio pipeline already ready)
- Voice‑activity detection (trims silent chunks to save API cost)
- Per-speaker colors / speaker renaming in the transcript

---

The macOS meeting co-pilot: SwiftUI app, on-device and streamed transcription,
the always-on blind-spot loop, MCP connectors and the decision ledger client.

## Build

```bash
swift build
swift test
```

## Why there is JavaScript in a Swift repository

`npm test` runs a small suite that parses Swift **as text** and asserts the
copies of server truths embedded here — the goal taxonomy, the credit table —
match `contract/contract.json`. Reading Swift from JavaScript is exactly what
lets these checks survive the repository split: they never needed to compile
anything.

## The contract

`contract/contract.json` is a **vendored copy** of a document published by
`cruxwing-api`. Do not hand-edit it.

While everything lived in one repository, the copies of server truths kept here
were pinned by tests that read the server's JavaScript directly, and those pins
caught real bugs — four goal contracts the Mac app could never emit, a landing
page advertising a model the catalog no longer served. Across repositories that
is impossible, so the pin became the contract: the API generates it from the
modules it actually runs on, this repo vendors a copy, and CI fails when the
copy falls behind.

To update it: copy `contract/contract.json` out of `cruxwing-api` and run the
suite. If a test fails, that failure is the point — something here is describing
a server behaviour that no longer exists.

CI needs one repository variable, `CONTRACT_SOURCE_REPO`, set to the
`owner/name` of the `cruxwing-api` repository. The drift job fails loudly when
it is unset rather than skipping, because a check that passes when it cannot
reach the source reports "no drift" for the one reason that guarantees it cannot
know.
