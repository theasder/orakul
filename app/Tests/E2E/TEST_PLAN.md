# Cruxwing end-to-end UI/UX verification

This plan covers the macOS application and its authoritative API. The Chrome
extension repository (`cruxwing-web`) is intentionally excluded from test
changes per the operator's instruction.

## Coverage model

No finite suite can enumerate every possible sentence, timestamp, network
packet, or event ordering. The suite therefore combines three kinds of
coverage, and labels them separately instead of collapsing them into one vague
percentage:

1. **Exhaustive finite state coverage.** Every point in the 2^5 workspace flag
   product and all 4! action orders run in Swift. Boundary sets (empty, one,
   threshold−1, threshold, threshold+1, maximum, overflow) are exhaustive for
   each bounded input.
2. **Interaction coverage.** The real installed app plays a generated MP4
   through ScreenCaptureKit while prompt surfaces arrive at seeded, changing
   timestamps. Unit/integration layers deterministically inject disconnects,
   timeouts, malformed responses, concurrent reservations, stale completions,
   and cancellation races that are unsafe or too slow to create by changing a
   developer's machine-wide network.
3. **Executed requirements coverage.** `coverage-manifest.json` maps every
   requirement below to evidence, but a surviving source marker is reported
   only as *mapping coverage*. It contributes zero to the 90% gate.
   `verify_e2e_coverage.py` enforces fresh machine-readable execution evidence:
   every test declared in each cited Swift/Vitest file must appear and pass in
   xUnit, installed-app requirements must pass requirement-specific assertions
   over a successful live artifact directory, scorer self-tests must execute in
   the verification run, and the commercial-core coverage requirement must
   have a fresh Istanbul summary. Missing, skipped, failed, malformed, or stale
   evidence fails closed. Unautomated hardware/screen-reader checks remain in
   the denominator and are reported by name.

Source coverage is reported independently. The API has a 90% gate for the
goal-critical tariff, cost-meter, and credit-pool modules; the full
repository figure remains visible and is never substituted with the focused
number. Swift's full-target coverage is also reported, with risk-critical file
coverage called out separately because generated SwiftUI/accessor code makes a
single app-wide percentage misleading. The Swift gate additionally requires
90% over declaration-anchored bug-critical symbols in AppState advice/engine
handoff, AutoOrchestrator failover, AudioChunkBuffer live rerouting, and
Deepgram readiness/terminal setup; stale coverage data or an uninstrumented
symbol fails closed.

## Combinatorial axes

| Axis | Equivalence classes / boundaries |
| --- | --- |
| Workspace | recording, transcript, answer, history, title; all 32 states |
| Action order | speak, ask, title, quota latch; all 24 permutations |
| Navigation | live → history → new call, repeated reopen, rapid record toggle |
| Video | clean, pink-noise, 1.25×; built-in speaker route + concurrent physical microphone and ScreenCaptureKit; Apple Silicon live playback and retained Intel manual check |
| Prompt surface | quick prompt, free-form input, interactive poll, mandatory notice, contextual question |
| Prompt timing | independently armed seeded points across 12–88% of playback; async overlaps allowed |
| Transcription | Local/private anonymous attribution, managed server fallback, Deepgram live speakers, cumulative cross-track echo, large Instant provisional→final replacement, follow/manual-scroll viewport state |
| Recording context | automatic titles/apps, tutorial/video/lecture/interview/podcast/presentation/meeting, media title containing call words, unrelated YouTube playback, manual preset/custom override before and during capture, stale detector completion, saved-session restore |
| Chat folder | picker/importing/ready/error/cancel/remove; empty/nested/project/binary/hidden/package/symlink/unreadable/deleted inputs; file/byte/character/count overflow; unmatched/relevant/rapidly changing queries |
| Connected glossary | grounding off/disconnected/empty, 1/3/overflow sources, credential-shaped excerpts, fast ranker success/failure/timeout, five-minute cache, Add/Dismiss, idle/live-call review |
| Blind Spot | Free/Pro/Premium/Ultra cadence and 1/3/4/5-credit scans; Settings idempotence; OFF/snooze/Stop/New Call during token, connector, pack, and provider awaits; queue rejection/retry; cache hit; 429; managed failover; clean/noisy/fast live terminal card |
| Network | healthy, refused/offline, timeout, 4xx, 5xx, malformed SSE, mid-stream failure, reconnect |
| Input | empty, whitespace, baseline, threshold±1, maximum, overflow, unknown model/type |
| Accessibility | normal/large text × regular/bold × left-to-right/right-to-left × light/dark; live OS contrast/motion/color-independent/VoiceOver state |
| Economy | Free/Pro/Premium/Ultra × monthly/annual × regional multipliers × every model/feature/add-on |
| Settings lifecycle | five Settings tabs × idle/starting/recording/stopping/history × open/change/reopen/restore |
| Settings effect | immediate/live, next recording, next request/job, reconnect-required, confirmation-required |

The live runner uses a reproducible seed but changes that seed by default on
every run. A failure prints the seed, so the exact prompt schedule can be
replayed with `VIDEOTEST_SEED=<seed>`.

## Live transcript attribution, acoustic echo, and viewport stability

Capture track is not speaker identity. The Local/private engine therefore
renders, exports, and sends mic/system lines to AI without fabricated `You` or
`Them` labels. A genuine diarizer label, such as Deepgram `Speaker A` or a
post-call AssemblyAI label, still wins. Restoring a legacy saved Local session
must apply the session's engine provenance before rendering so old calls do not
regain false labels.

Instant has a separate cumulative-echo boundary. A room microphone can hear
several already-finalized remote turns and return their concatenation as one
large hypothesis; pairwise line deduplication cannot recognize that shape. The
regression fixture reproduces a long Russian Speaker A block, tolerates ordinary
ASR substitutions, drops echo-only provisional and final mic text, and retains
only an exact genuinely new user suffix. System speech and an expired/different
mic turn remain untouched.

Viewport state is crossed with that changing transcript shape. While follow
mode is active, a large multi-line provisional becoming a shorter final and
subsequent lines must remain pinned to the visual bottom after NSTextKit layout.
When the reader scrolls away, the same interim/final mutations must preserve the
exact clip origin and selection. A real wheel/trackpad gesture beats follow
hysteresis, while the explicit Latest action re-engages and anchors even if no
text changed between scrolling away and clicking it.

| Requirement | Execution-backed proof |
| --- | --- |
| `TRANSCRIPT-PRIVATE-ATTRIBUTION` | `LocalTranscriptAttributionTests`: anonymous Local render/prompt/export/restore plus preserved real diarized labels |
| `TRANSCRIPT-CUMULATIVE-CROSS-TRACK-ECHO` | `LocalTranscriptCapturePipelineTests` and `CumulativeCrossTrackEchoTests`: Russian interim/final echo, ASR substitutions, and novel suffix retention |
| `TRANSCRIPT-INSTANT-SCROLL-STABILITY` | `SelectableTranscriptLiveScrollTests`: large provisional→final pinning, manual viewport preservation, Latest re-engagement, and explicit-reader detachment |
| `OBS-DEV-CALL-DIAGNOSTIC-JSONL` | `DevCallDiagnosticsTests` plus requirement-specific semantic checks over the installed-app live artifact directory |

## Connected-app transcription glossary suggestions

Settings → Transcription may propose terminology from connected apps, but it is
a review queue rather than an automatic dictionary rewrite. The production
request admits at most three readable sources and 1,600 characters per source,
caps the combined grounding at 4,800 characters and the whole prompt at 6,000,
and never accepts the live transcript as an input. Credential-like keys and
values, bearer/API keys, JWTs, private keys, email addresses, URLs, and opaque
secret-shaped values are removed before local extraction or model ranking.

The optional ranker uses the orchestrated background model with at most 384
output tokens. Its compute-credit estimate comes from that model's tariff, the
connector fan-out consumes one grounded research cycle, and the result is cached
for five minutes. Disabled grounding, no readable connector, or no candidates
must perform no unnecessary model work. Provider failure, malformed output, or
timeout falls back to the local allow-list; model output may retain only terms
whose spelling is present in bounded source evidence. Existing/rejected terms
are deduplicated and the review list is capped at 24 rows.

No suggestion changes `Config.transcriptionGlossary` until the user selects Add;
Dismiss never mutates it. Add during a call changes only the configured
next-recording dictionary, while the active engine keeps its captured glossary.
The nonce-gated installed-app fixture runs generate → Add → Dismiss while audio
capture continues, records the source/prompt/token/cost caps and zero transcript
characters, captures the real Settings review UI, and restores the original
dictionary and empty review state afterward without connector traffic.

`CONNECTED-TRANSCRIPTION-GLOSSARY-SUGGESTIONS` requires all ten tests in
`ConnectedGlossarySuggestionTests`, including the exact privacy, tariff/cache,
explicit-review, mid-call isolation, and dev-fixture cases, plus semantic live
state and screenshot evidence for every executed condition.

## Recording type for calls, tutorials, and other playback

Audio shape alone cannot determine whether the user is in a meeting or playing
a tutorial, an unrelated YouTube video, a lecture, an interview, a podcast, or
a product presentation. Automatic classification therefore uses visible window
titles and application identity only as a suggestion. Media-host evidence takes
priority over meeting words inside the title: “How to implement Zoom meeting
webhooks — YouTube” is a tutorial, while an unrelated YouTube title is generic
video. Local media-player applications classify as video even without a useful
title; unknown and ordinary Zoom/Meet sources retain the compatible meeting
default.

The recording-type chip is present in the live workspace, not hidden in global
Settings. It exposes Auto, every preset, and Other. Custom labels collapse
whitespace and stop at 80 characters. A manual choice always wins over later
window changes. Changing it while recording must leave capture state and the
session ID unchanged, while a detector completion from an earlier session is
discarded. An explicit choice persists with the saved recording and restores
with History.

Every assistant request receives one compact type-orientation line before the
transcript and request. For non-meeting media, the eight meeting-oriented quick
actions (`summary`, `agenda`, `whattoask`, `answer`, `advice`, `tasks`,
`logdecision`, and `commitments`) are rewritten into source-grounded learning,
analysis, and project-application prompts. Adapted prompts stay below 1,000
characters and must not demand fictional meeting decisions, owners, deadlines,
ledgers, or a next meeting. Tutorial guidance stays below 420 characters and
every preset orientation below 520; meeting shortcuts remain byte-for-byte
compatible. This bound is both a hallucination control and a token-economy
contract: selecting a type must not add a long taxonomy to every request.

| Requirement | Execution-backed proof |
| --- | --- |
| `RECORDING-CONTEXT-AUTODETECT-MEDIA` | `RecordingContextDetectorTests`: media precedence, random YouTube, learning platforms, local players, specialized formats, and meeting fallback |
| `RECORDING-CONTEXT-MANUAL-CHOICE` | `RecordingContextSelectionTests` plus the recording-chip source contract: Auto/preset/custom precedence, sanitization, bounded labels, and accessible controls |
| `RECORDING-CONTEXT-MIDCALL-CONTINUITY` | `RecordingContextLifecycleTests`: active-state/session continuity, stale completion rejection, and saved-session round trip |
| `RECORDING-CONTEXT-MEDIA-PROMPT-ECONOMY` | `RecordingContextSelectionTests` and `RecordingPromptAdapterTests`: compact orientation, ordering, all eight adapted actions, project grounding, and meeting compatibility |

## Chat folder attachments and query-time project context

The chat composer’s add menu accepts a folder directly. Selection synchronously
renders the folder name and an `Indexing…` state with Cancel before scanning
finishes. Success becomes a standing removable folder chip owned by `AppState`,
so sending another prompt or reconstructing the view does not hide it. Failure
remains visible and removable instead of disappearing. The existing single-file
attachment path remains unchanged.

Folder permission is not permission to crawl indefinitely. Indexing is detached
from the UI actor and cancellation is atomic. It never follows symlinks, enters
packages, hidden/build/dependency directories, unsupported binaries, or an
unreadable file. Enumeration stops at 2,000 entries and 400 candidate files;
each folder retains at most 40 files, reads at most 2 MiB per file and 8 MiB in
aggregate, extracts at most 40,000 characters per file and 240,000 per folder,
and deduplicates byte-identical content deterministically. Anything left out is
reported. Intentional cancellation publishes no partial folder/grant and no
global error; other errors are bounded and never reveal the selected raw path.

The scan is a local index, not request context. Each prompt independently ranks
against its own bounded query (4,000 characters/24 terms), attaches at most six
files, 2,400 characters per excerpt, and 12,000 folder characters total. An
unmatched query gets one small README fallback rather than a folder dump. Two
rapid unrelated prompts must retrieve different relevant files while the same
folder chip and ordinary loose-file context remain attached.

| Requirement | Execution-backed proof |
| --- | --- |
| `UI-COMPOSER-FOLDER-IMMEDIATE` | `ComposerImmediateFeedbackTests` and `ChatFolderAttachmentSourceContractTests`: picker route, immediate/cancel/error states, persistent chip, and removal |
| `CONTEXT-FOLDER-TRAVERSAL-SAFETY` | `ContextFolderTests` plus the scanner source contract: recursive project reads and symlink/package/hidden/unreadable/dependency rejection off the UI actor |
| `CONTEXT-FOLDER-RESOURCE-BOUNDS` | `ContextFolderTests`: raw-byte, candidate/file-count, deduplication, per-file character, and aggregate character boundaries |
| `CONTEXT-FOLDER-CANCELLATION-ATOMIC` | `ContextFolderTests`: worker cancellation, no partial publish/grant/error, deleted access, and path-redacted failure |
| `CONTEXT-FOLDER-RELEVANCE-RAPID-PROMPTS` | `ContextFolderTests` and request source contract: bounded relevant snippets, README fallback, per-prompt reranking, persistent folder, and loose-file preservation |

## Settings lifecycle coverage

Settings is a separate macOS window, but it shares mutable application state
with capture, transcription, AI work, account sessions, and connector OAuth.
For every lifecycle state below, open each of the five tabs, traverse every
enabled control by keyboard and pointer, close and reopen Settings, and assert
there is exactly one Settings window. Rapid tab cycling and rapid repeated
writes must not stop capture, duplicate background tasks, resurrect canceled
work, or mutate the selected History item.

The lifecycle states are defined precisely:

- **idle:** no active capture and a fresh or cleared workspace;
- **starting:** consent/permission checks and capture startup are in flight,
  before the recording snapshot is fully committed;
- **recording:** microphone, system capture, transcription, and any enabled
  co-pilot loops are active;
- **stopping:** capture teardown, final transcript flush, persistence, and
  optional post-call jobs are in flight;
- **history:** a saved call is selected and rendered read-only while no live
  recording owns that workspace.

| Tab | Idle | Starting | Recording | Stopping | History |
| --- | --- | --- | --- | --- | --- |
| General | Changes persist immediately; notification/reminder services reconcile once. | A racing write has one deterministic winner and never partially changes the recording snapshot. | Appearance and service preferences update live; role changes affect only later AI requests; capture stays continuous. | Changes do not alter the session being finalized or its stored metadata. | Stored transcript/answer/title/context remain byte-identical; preferences apply to later work. |
| Transcription | The next recording snapshot exactly matches the selected engine, language, model, AEC, glossary, and diarization settings. | Each field belongs wholly to either the starting snapshot or the next recording; no mixed engine/configuration is allowed. | Snapshot fields remain unchanged and show honest pending state; no streamer is recreated mid-call. | Final chunks and optional uploads use the completed call's snapshot; late Settings writes cannot reinterpret it. | Controls remain editable but affect only a future recording, never the saved transcript. |
| AI | Provider/version selection applies to the next request; co-pilot switches persist without starting tasks. | Live-watch switches reconcile after recording becomes active; no duplicate timer/task is created. | Five watch switches start/stop only their own task immediately; provider/version and role changes do not retarget an in-flight answer. | Disabling a watch prevents a new cycle and preserves already-accounted active intervals; a finishing response obeys its captured model. | No watch task starts; a new request from History may use the newly selected model without rewriting the saved answer. |
| Connected Apps | Search, custom-server validation, connect/reconnect/disconnect, Google scopes, copy URL, and team-watch controls render their true states. | OAuth or disconnect can overlap startup without blocking capture; any connector result is admitted only under the current identity scope. | Connector changes affect the next grounding request, invalidate old caches, and never disturb audio/transcription; in-flight old-account results are discarded. | A connector completion cannot be appended to the call after its generation closes; disconnect remains effective. | Connecting is allowed for future work, but must not silently reground or rewrite the opened saved call. |
| Account & Privacy | All sign-in methods, sign-out, consent, analytics, plan preview, and destructive confirmations show the correct availability. | Sign-in/out cannot strand startup; consent is evaluated at the recording boundary. | Sign-out leaves local recording alive, invalidates account-scoped evidence, and affects the next managed request; consent revocation applies next recording. | Account/session changes cannot corrupt persistence or late post-call callbacks. | Account changes never delete local meetings; delete-account requires explicit confirmation and reports server failure without closing History. |

For starting and stopping races, run both orderings around the commit barrier:
`setting → transition` and `transition → setting`. Repeat with the transition
paused before and after its first suspension point. The assertion is an atomic
old-or-new result, never a hybrid configuration.

## Settings application semantics and control inventory

The suite treats the application point as part of each control's public UX
contract. Merely proving that a value reached `UserDefaults` is insufficient.

| Application point | Controls and required behavior |
| --- | --- |
| Immediate/live | Theme; call detection, ignore-media dependency, reminders and lead time; five co-pilot watches; team watcher and keyword rules; analytics opt-in; connector availability and grounding after a completed connection transition. Repeated writes are idempotent. |
| Next AI request | Role/custom role, provider, model version, account entitlement, connected-app source set, and developer plan preview. An already-started request and its audit/follow-up keep their captured model, role, tier, and source generation. |
| Next recording | Transcription engine, language, local model, Apple noise/echo reduction, AssemblyAI diarization permission, and custom vocabulary. The active call exposes configured versus active values and pending/reverted state. |
| Next post-call job | Fireflies enhancement and adaptive-local recommendations may affect the next eligible enhancement/model-selection job, but never replace active streamers or rewrite an already persisted transcript silently. |
| Reconnect required | Changes to Google Calendar/Docs/Sheets/Drive scopes are staged and visibly request reconnect; the existing grant is not presented as containing the new scopes. Provider-account switching is disconnect/reconnect and rotates cache identity first. |
| Confirmation/external authorization | Manage plan/checkout, OAuth browser consent, account deletion, and any connected-app write action. Cancellation is a first-class terminal state. Account deletion and writes are never issued by unattended live tests against real accounts. |
| Next recording consent boundary | Revoking recording consent does not interrupt the active call; the next start must show and require the consent surface. |

Every visible or conditional Settings control is inventoried below. Tests must
fail when a new control is added without an application-point classification
and evidence marker.

### General

- Theme: Auto, Light, Dark, including change while the Settings window and live
  transcript are both visible.
- Role: Not set, every `RoleSkillMatrix.positions` entry, and “Write my own…”.
  Role selection is crossed with idle/recording/history and with an in-flight AI
  request. The next request must contain exactly the selected role method.
- Custom role: hidden outside the custom choice; empty, whitespace, one
  grapheme, Unicode/RTL, punctuation, multiline paste, a normal job description,
  maximum accepted length, and overflow. Switching custom → built-in →
  custom must preserve only the intended draft and never leak custom text into
  a built-in role prompt or privacy-safe logs.
- Notify me about calls; Ignore music/video enabled and disabled dependency;
  Remind me before meetings with Google connected/disconnected; all lead times
  1/5/10/15/30 minutes. Service reconciliation is single-shot under rapid
  toggles and cannot prompt to record while already starting/stopping.

### Transcription

- Every selectable engine and unavailable/withheld engine presentation; every
  language option; every local model option; adaptive performance; Apple
  noise/echo reduction; Fireflies enhancement; conditional AssemblyAI
  diarization; and custom vocabulary.
- Vocabulary boundaries: empty/whitespace, one term, comma/newline mixtures,
  duplicates, Unicode technical terms, punctuation, maximum accepted payload,
  and overflow. Normalize the displayed count while preserving the exact
  immutable glossary handed to every active streamer.
- Connected-app term proposals: unavailable/empty/loading/ready/failed states;
  bounded privacy-redacted source evidence; cheap fast ranking and local
  fallback; cache hit; Add/Dismiss review; manual-edit deduplication; and
  configured-versus-active glossary counts while recording.
- For every field, record configured, active, pending, and next-recording
  values. Changing away and back clears pending UI. Start/stop races must never
  mix an old engine with a new language, AEC, model, or glossary.

### AI

- Manage plan sheet open/cancel/return; every plan entitlement presentation;
  real scroll to the bottom-only promo form; exact `DEV-UNLIMITED-LOCAL`
  submission through the production API into Founder/Ultra; and a fresh
  nonce-correlated receipt proving developer preview was disabled;
  provider Auto, every configured provider, every available council, unavailable
  provider state, version Auto, and every version allowed by the selected tier.
  Changing provider resets version exactly once.
- Brainstorm, agenda/framing, fact-check, rhetoric, and facilitation switches:
  both values in all lifecycle states, all 5! rapid enable orders and reverse
  disable orders, repeated same-value writes, aligned timer wakes, and credit
  accounting over the union of enabled intervals.
- Change provider/version, role, tier preview, and connector source set while a
  response and its audit are blocked. The current chain stays on its captured
  contract; the next independent request uses the new one.

### Connected Apps

- Google Connect/Cancel/Disconnect/Reconnect and Calendar/Docs/Sheets/Drive
  checkboxes, including missing client ID, missing secret, browser cancellation,
  changed-scope banner, partial grants, stale scope version, refresh, and 401.
- Work-app search by name and every alias, clear-search, no-results copy, every
  catalog row/state/action, and tool/workflow counts. Add custom server covers
  empty/whitespace name, invalid scheme/URL, HTTPS boundary lengths, duplicate
  display names, cancel, add, reconnect, disconnect, and remove.
- Cruxwing MCP URL copy verifies exact clipboard text and transient Copied state
  without putting the URL or account identity in network logs.
- Team Sources disclosure, configured/off connector rows, watcher on/off,
  no-channel and no-keyword states, keyword empty/duplicate/case/Unicode/max/
  overflow, chip removal, match count, auto-ack presentation, and Audit Log.
  The watcher is independent of recording and remains single-instance.

### Account & Privacy

- Account unavailable, signed out, signing in, signed in with/without display
  email, refresh in flight, expired, and explicit sign-out. Cover email-code
  send/back/verify, password login/register with the 7/8-character boundary,
  phone send/back/verify, and conditional Apple/Google account login. Account
  Google login remains distinct from the Connected Apps Google grant.
- Delete button availability, confirmation cancel, confirmed success, 401, 5xx,
  timeout, and retry. Automated destructive success uses only an isolated test
  account/database; installed-app real-account runs stop at the confirmation.
- Recording consent not-yet-affirmed/affirmed/revoked; anonymous analytics on/
  off and next-event suppression; developer-only Real entitlement plus every
  tier preview and exact model/hour/credit/grounded-cycle summary.

## Connected-app provider, account, tool, and error matrix

The complete provider inventory is a contract, not a representative sample:

- Dynamic registration: Notion, Fireflies, Linear, Asana, Atlassian, Intercom,
  Sentry, Zapier, Attio, PostHog, Amplitude, and Mixpanel.
- Pre-registered OAuth: HubSpot (`52700`), Affinity (`52701`), Zoom (`52702`),
  Gmail (random loopback), and Google Analytics (random loopback).
- Custom: one deterministic local HTTPS MCP fixture plus malformed and
  unreachable endpoints. `cruxwing-web` is not a provider or a test target.

Every provider ID is checked against its exact HTTPS endpoint, OAuth mode,
loopback contract, aliases, connector-specific research query/read-for purpose,
and credential gating. Then cross the following finite classes:

| Dimension | Classes | Required assertions |
| --- | --- | --- |
| Connection state | disconnected/no token, authorized cached token, connecting, connected with 0/1/many tools, failed, reconnecting, disconnecting | Correct button/progress/status; one in-flight connect; late connect cannot undo disconnect; teardown exposes no Connect/Reconnect action until old client/token work finishes; duplicate disconnect cannot publish a premature terminal state; stopping an authorized reconnect is labelled Disconnect because it revokes the grant; exact tool/workflow count after verified `tools/list`. |
| Account identity | anonymous, Cruxwing account A, token refresh for A, sign-out, account B, provider account A→B reconnect | Connector tokens remain separately stored where intended, but grounding/cache keys never cross account or connection generations; old in-flight results are dropped. |
| Tool inventory | empty, safe reads only, writes only, destructive only, mixed, duplicate names, changed list, missing/malformed schema, conflicting annotations | One-click Import shows only positively read-shaped tools. `get_or_create`, writes, destructive tools, and ambiguous tools remain hidden and are rejected again at execution. Untrusted `readOnlyHint` never overrides the classifier. |
| Read call | fresh success, empty text, structured/non-text content, MCP `isError`, timeout, cancellation, stale-cache fallback | Imported context is request-correlated and bounded; stale evidence is age-labelled; empty/error bodies never become context. |
| Transport/auth error | refused/offline, DNS/TLS, server timeout, 400/401/403/404/429/5xx, malformed JSON/SSE, OAuth cancel/timeout/state mismatch/PKCE/session binding, corrupt or revoked token | Bounded terminal state, actionable redacted message, correct retry/re-authorize path, no browser loop, no token resurrection, audio and transcription remain live. |
| Rapid action order | Connect→Disconnect, Disconnect→late Connect, Reconnect→account change, scope change→prompt, prompt→disconnect, remove-custom→late callback | Final state follows the last user intent; capability/cache revisions are monotonic; no stale result or credential is committed. |

One-click Import is read-only. Write-capable tools may be exercised only through
a dedicated confirmation-backed workflow using a deterministic test server or
sandbox tenant. No test may infer safety solely from a server-provided MCP
annotation.

Every write confirmation captures the connector/account generation displayed in
its preview. Commit requires that exact generation to remain live, forbids a
lazy reconnect, and rechecks immediately before each side effect. If the account
changes between items in a multi-item tracker write, already-linearized items are
reported, every remaining item is skipped, and the user must review a new
confirmation. The common injected dispatch seam proves edited-payload and
exactly-once behavior; separate schema/policy tests pin Notion nesting, tracker
argument mapping, Calendar proposal gating, CRM selection, and Gmail draft-only
behavior so provider labels on the fake are never mistaken for vendor E2E proof.

## Deterministic automation and real-credential scope

The default suite is deterministic, offline-capable, and safe to run on a
developer machine or CI worker:

- in-memory Keychain stores and private notification centers isolate tests;
- URL-protocol/local-server doubles produce OAuth callbacks, `tools/list`, tool
  responses, timeouts, disconnect races, and every HTTP/error class;
- seeded dev hooks mutate a strict allowlist of reversible settings and restore
  the captured baseline even after failure;
- account deletion, checkout, messages, issue creation, and other writes target
  an isolated test database/server only; and
- no machine-wide network, microphone, appearance, account, or accessibility
  preference is changed by deterministic unit/integration tests.

Real-credential checks are opt-in and manual. Use disposable provider tenants,
a disposable Cruxwing account, a dedicated macOS test user, and the exact
provider row under test. They cover browser consent wording, redirect URI,
Keychain persistence across relaunch, refresh/revocation, real rate limits, and
provider-specific tool contracts. Run write/destructive confirmation only in a
sandbox tenant. Record pass/fail and redacted metadata, never credentials or
content. The Zoom-like audio fixture remains local; a true Zoom vendor smoke
requires a second client/device and separate disposable Zoom credentials.

## Safe logging and artifact verification

Before each run, seed unique canaries in Authorization, refresh/access tokens,
OAuth code/state/verifier, cookies, account email, custom role, glossary,
transcript, connected-app query, and tool result. Afterward recursively scan all
telemetry-shaped artifacts and unified-log extracts; finding a secret canary,
or finding a content canary in production/network telemetry, is a hard failure.

Allowed network fields are timestamp, request ID, provider category/opaque
server ID, method, normalized path template, status/error category, duration,
and byte counts. Never log headers, query strings, bodies, prompts, transcript,
tool arguments/results, raw endpoint credentials, email/phone, OAuth material,
or Keychain bytes. Errors are reduced to an allowlisted category plus a bounded
user-facing message; upstream bodies are not echoed. Screenshots and semantic
state can legitimately contain the test fixture's visible meeting text, so they
remain owner-only and are excluded from telemetry publication.

An explicitly authorized dev live run additionally writes
`synthetic-evidence.jsonl`. It retains the fixed synthetic goal, transcript,
user prompts, terminal answers, visible workflow steps, Blind Spot cards, and
safe provider/billing trace so a failure can be reconstructed. The Blind Spot
record also contains its exact bounded goal/transcript/prior/guidance/context
request JSON plus token lookup, connector workflow, deterministic packing, and
provider stage timings. It never serializes the bearer/access token. This file
is not production telemetry: the hook exists only in a dev build, requires a
per-run high-entropy nonce, accepts only compiled bounded fixtures, confines
output to the launch-time owner-owned `0700` artifact root, and writes the file
as `0600`. Never enable this capture for a real customer call or publish its
contents.

The same explicit dev gate may also write one
`dev-call-diagnostics/call-<uuid>.jsonl` stream per test call. Unlike production
telemetry, this review artifact intentionally contains the assembled assistant
request, workflow transitions/results, backend route terminal, Blind Spot
request/terminal cost trace, and final user-facing answer. It is enabled only
by a dev build plus `CRUXWING_DEV_CALL_LOGS=1`, the live-test nonce, and the
owner's existing `0700` artifact root. Every file is `0600`, is capped at 4 MiB,
uses bounded strings/events/collections, rotates to at most eight calls, and
recursively redacts credential keys and bearer/API-key/JWT/private-key shapes.
The live coverage gate requires exactly one complete, contiguous, consistently
correlated trace per executed condition and scans it without copying captured
call content into the coverage report. Production and opt-out runs must create
no diagnostic artifact.

Connected-app operations use a closed structured record:
`event=connector_operation`, operation, UUID request ID, allowlisted built-in
provider ID (or `custom`/`unknown`), provider category, read/write/destructive
tool class, cache result and numeric age, terminal status, elapsed milliseconds,
retry ordinal, and retry eligibility. Deterministic canaries prove that raw tool
names, endpoint/custom-server identity, tokens, queries, arguments, imported
content, result bodies, and error text cannot enter either the record model or
its unified-log rendering. Timeout, offline, 401, 429, 5xx, malformed response,
fresh/stale cache, and reconnect failure→success each have pinned categories.

Settings runs add these artifacts to the general contract:

- `<condition>.settings.{general-open,general-mutated,ai-open,ai-live-mutated,
  transcription-local-live,transcription-deferred,connected-apps-mutated,account-privacy-open,
  account-privacy-mutated,restored,closed}.state.json`;
- `screenshots/<condition>.settings-{general-mutated,ai-open,ai-live-mutated,
  transcription-deferred,connected-apps-mutated,account-privacy-mutated,
  restored}.png`;
- `<condition>.settings.result.json`, with booleans for single-window behavior,
  General mutation, live-watch reconciliation, deferred transcription,
  full transcription controls, connected-app grounding, Account/Privacy,
  restoration, capture continuity, and close-without-stop; and
- `events.jsonl` entries containing the seeded schedule, lifecycle state,
  setting identifier, requested application point, terminal latency, and
  pass/fail category, but never the setting's sensitive free-text value.
- `promo-redemption.state.json`,
  `screenshots/promo-redemption-{pricing-bottom,success}.png`, ordered
  `promo-ui`/`promo-redemption` events, and a request-correlated
  `promo_redeem_*` lifecycle in `network.log`. The state must say exact code,
  Founder/Ultra, real entitlement, and no preview; the network log must never
  contain the code or a request/response body.

The broader lifecycle campaign uses the same naming with
`settings.<lifecycle>.<tab>.before/after` prefixes. Each after-state records both
configured and active snapshots, request/recording/account/cache generations,
task activity, capture counters, and the selected History session ID as an
opaque run-local value.

## Grounded response quality under Settings changes

Response scoring is run both before and after model/role/connector/account
mutations. Ground truth assigns each fact to a source and a reveal timestamp.
In addition to the general response gate, connected-app cases require:

- at least one expected fact from every selected, successful source and no fact
  uniquely belonging to an unselected, disconnected, future, or previous-account
  source;
- evidence precision and target-evidence coverage in the scorer output, with
  aggregate relevance/grounding, fulfillment, coherence, and overall meeting
  quality each explicitly thresholded rather than only a blended score;
- exact treatment of contradictions: quote the authoritative number/status,
  identify transcript-versus-source disagreement, and do not average or invent
  a compromise;
- stale fallback labelled with source and age, while timeout/error bodies and
  OAuth instructions never appear as answer evidence;
- no unsupported numeric claim, no future-turn leakage, bounded repetition,
  and a non-error terminal response for every required prompt type; and
- changing role/model/source while a response is in flight leaves that response
  coherent under its captured contract; the next independent response must
  demonstrate the new contract.

Use the live runner's baseline thresholds (`min successful responses 2`,
required successful IDs `summary` + `advice`, required successful types
`summary` + `freeform`, aggregate overall `MIN_RESPONSE_QUALITY`, non-error
attempt rate `0.25`, per-response overall `0.35`, relevance `0.20`, fulfillment
`0.35`, coherence `0.55`, prompt-to-terminal latency `120s`, and repetition
`0.25`). Superseded attempts remain explicit evidence and lower the completion
rate, but never count as responses. Provider/account isolation and future-fact
leakage are hard zero-tolerance gates regardless of aggregate score.

## Artifact contract

Each live run writes a guaranteed-fresh owner-only directory (override with
`VIDEOTEST_OUT`; a non-empty target is refused). Dev-hook commands carry a
per-run 256-bit nonce, dumps are confined to that directory, and files are
written with owner-only permissions:

- `report.json`: condition metrics and final pass/fail counts;
- `events.jsonl`: timestamped actions, prompt injections, and flow terminal latency;
- `*.state.json`: request-correlated stable UI state at launch, each interrupt, and finish;
- `screenshots/*.png`: the Cruxwing window only, not the entire desktop;
- `network.log`: valid NDJSON containing the privacy-safe request lifecycle
  (method/path/status/duration/bytes), without tokens, bodies, or transcript text;
- `dev-call-diagnostics/call-<uuid>.jsonl`: explicitly armed dev-only,
  content-bearing prompt/workflow/provider/cost/response evidence, one bounded
  credential-redacted and call/session-correlated `0600` file per condition;
- `*.settings.connected-glossary-{generated,accepted,rejected}.state.json` and
  `screenshots/*.settings-transcription-glossary-suggestions.png`: correlated
  bounded proposal, explicit review, active-dictionary isolation, and visible UI;
- `*.score.json`: system-track WER/terminology/latency plus visible all-track
  duplication, cross-track echo, and speaker mapping/coverage;
- `*.duplex.json`: speaker route/mute/volume, physical-mic and system buffer
  counts, sampled RMS, last callbacks, and voice-processing state;
- `*.responses.json`: every model attempt's ID, lifecycle status, prompt and
  terminal timestamps/latency, plus successful answers' temporally bounded
  relevance, fulfillment, coherence, and aggregate quality;
- `*.prompt-overlap.json`: stable IDs and shared supersession timestamps proving
  the intentional `whattoask → advice → summary` overlap chain;
- `*.settings.result.json` and correlated Settings state/screenshot artifacts:
  live Local→Instant engine handoff, configured-versus-active semantics,
  restoration, capture continuity, and
  one-window behavior for all five tabs.
- `promo-redemption.state.json` plus pricing-bottom/success screenshots and
  sanitized network lifecycle: the Settings → AI → Manage → See plans → scroll
  → Redeem path, exact Founder/Ultra result, and non-preview causal receipt.

## Quality gates

- Clean system-track WER ≤ 0.35; noisy system-track WER ≤ 0.55. The
  simultaneously active microphone remains in raw artifacts but is excluded
  from MP4 ground-truth scoring because it represents room speech/echo rather
  than the scripted remote track.
- Built-in speakers must be unmuted at volume ≥ 0.05; microphone and system
  capture must each keep delivering buffers through at least half the playback.
  With raw mic capture, non-silent mic samples prove the speaker→mic acoustic
  path; when AEC is active that echo check is reported as intentionally skipped.
- Technical-term recall ≥ 0.50, system/visible duplication ≤ 0.10, and
  cross-track near-echo leakage ≤ 0.05.
- Local/private transcript, export, restore, and AI context contain no
  source-inferred `You`/`Them` label; genuine diarizer labels remain visible.
  Instant cumulative mic echo is absent, while genuinely novel suffix speech
  remains present exactly once.
- Instant transcript growth never disengages an active live-tail follow or
  changes a manually preserved viewport/selection. Latest re-engages on an
  unchanged transcript, and an explicit reader scroll detaches immediately.
- Connected glossary proposals send zero transcript characters, use 1–3 sources
  within the 4,800-grounding/6,000-prompt bounds, retain only source-backed
  terms, and expose non-zero tariff-derived fast-model cost. Add changes only
  configured next-call terms; Dismiss changes neither configured nor active
  terms; restoration returns the original dictionary and empty review state.
- Automatic media detection must distinguish the tutorial and unrelated-video
  fixtures while preserving the meeting fallback. A manual type change during
  capture must preserve recording/session identity; every adapted media action
  remains below 1,000 characters and cannot request fictional meeting artifacts.
- Folder scans must remain within every raw-byte, file-count, and extracted-text
  ceiling and produce no out-of-root/package/hidden/unreadable content. Every
  prompt receives at most six relevant excerpts and 12,000 folder characters;
  cancellation publishes no partial folder, and rapid prompts cannot reuse an
  irrelevant prior query's selection.
- Transcript p95 post-utterance latency ≤ 20 seconds.
- Speaker accuracy ≥ 0.60 when a diarizing engine is selected; setting
  `REQUIRE_DIARIZATION=1` makes absent labels fail on every engine.
- Summary and a separate Advice request must terminate successfully; cancelled,
  failed, still-running, and superseded partial streams cannot satisfy either
  completion or quality. Every successful response independently meets the
  configured relevance/fulfillment/coherence and latency gates.
  Each response is graded only against turns completed before that prompt was
  injected, so a hallucinated future fact cannot receive grounding credit.
- Paid plans must remain profitable under the explicit full-burn COGS model;
  plan cards, server enforcement, app estimates, and add-on economics must agree.
- Every live Blind Spot condition must finish one goal-correlated managed
  attempt with provider/model/correlation/latency, cache and exact tariff-charge
  evidence. Clean playback must render a full visible card. Settings OFF,
  snooze, Stop, New Call, and quota must never merge a stale card or claim a
  retry, and connected evidence must not add a preliminary generic-chat charge.
- Weighted automated requirements coverage must be at least 90%.
- An armed dev live run has exactly one complete ≤4 MiB `0600` diagnostic JSONL
  per condition under a `0700` directory, with contiguous sequence, monotonic
  time, stable call/session correlation, every required terminal event, and no
  unredacted credential shape. Production/opt-out writes zero such files.
- Settings changes must preserve microphone/system capture liveness and the
  immutable active transcription snapshot; provider/account generation leakage,
  unsafe one-click import tools, secret canaries in logs, and History mutation
  are zero-tolerance failures.

## Commands

```bash
# Deterministic app tests, execution evidence, and source coverage
swift test --enable-code-coverage \
  --xunit-output /tmp/cruxwing-swift-tests.xml
python3 testlib/verify_swift_critical_coverage.py \
  --out /tmp/cruxwing-swift-coverage.json

# API suite with execution evidence, then goal-critical 90% source gate
cd ../cruxwing-api
/opt/homebrew/bin/node node_modules/vitest/vitest.mjs run \
  --reporter=junit --outputFile=/tmp/cruxwing-api-tests.xml
npm run test:coverage:critical
npm run test:coverage  # full API census; reported separately, no focused gate

# Pre-live executed-requirements check. This is expected to remain below 90%:
# deterministic evidence cannot stand in for installed-app interaction evidence.
cd ../cruxwing-app
python3 -m unittest -v testlib/test_verify_e2e_coverage.py
python3 testlib/verify_e2e_coverage.py \
  --manifest Tests/E2E/coverage-manifest.json \
  --xunit /tmp/cruxwing-swift-tests.xml \
  --xunit /tmp/cruxwing-api-tests.xml \
  --coverage-summary ../cruxwing-api/coverage/critical/coverage-summary.json \
  --run-command-checks \
  --out /tmp/cruxwing-e2e-coverage.json

# Focused Settings lifecycle, snapshot, connector, and account safety suites
swift test --filter SettingsDuringCallTests
swift test --filter RecordingSettingsIsolationTests
swift test --filter MCPImportSafetyTests
swift test --filter MCPCatalogTests
swift test --filter AccountSessionTests
swift test --filter ConnectedAppsBehaviorTests
swift test --filter PromptWorkflowDesignTests
swift test --filter PaywallViewTests
swift test --filter PromoRedemptionReceiptTests

# Screenshot-regression and dev-debugging safety suites
swift test --filter LocalTranscriptAttributionTests
swift test --filter LocalTranscriptCapturePipelineTests
swift test --filter CumulativeCrossTrackEchoTests
swift test --filter SelectableTranscriptLiveScrollTests
swift test --filter DevCallDiagnosticsTests
swift test --filter ConnectedGlossarySuggestionTests

# Media/call-type classification and bounded chat-folder context
swift test --filter RecordingContext
swift test --filter ContextFolder
swift test --filter ChatFolderAttachmentSourceContract
swift test --filter ComposerImmediateFeedback

# Zoom-like installed-app playback: remote fixture through built-in speakers,
# physical microphone on, and ScreenCaptureKit concurrent (requires ffmpeg/ffplay
# plus Screen Recording + Microphone grants)
VIDEOTEST_OUT=/tmp/cruxwing-live-all \
  CONDITIONS="clean noisy fast" bash videotest.sh

# Final execution-backed requirements gate. Reports and live report.json must
# be newer than the manifest/mapped sources and no older than 24 hours.
python3 testlib/verify_e2e_coverage.py \
  --manifest Tests/E2E/coverage-manifest.json \
  --xunit /tmp/cruxwing-swift-tests.xml \
  --xunit /tmp/cruxwing-api-tests.xml \
  --live-artifacts /tmp/cruxwing-live-all \
  --coverage-summary ../cruxwing-api/coverage/critical/coverage-summary.json \
  --run-command-checks \
  --out /tmp/cruxwing-e2e-coverage.json

# Reproduce one seeded mid-call Settings run and keep artifacts outside the repo
VIDEOTEST_SEED=424242 CONDITIONS=clean \
  VIDEOTEST_OUT=/tmp/cruxwing-settings-424242 bash videotest.sh

# Gate speaker attribution on a configured diarizing run
REQUIRE_DIARIZATION=1 CONDITIONS=clean bash videotest.sh
```

This is a deterministic local Zoom-like audio topology, not Zoom's proprietary
WebRTC transport: it covers real speaker output, physical microphone capture,
AEC/raw-mic behavior, and system audio without signing in to Zoom or contacting
another participant. A true vendor smoke test still requires a second client or
device and remains opt-in/manual.

Machine-wide network disabling is deliberately not automated: it risks other
work on the Mac. Transport failures are injected through URL-protocol/server
test doubles, while the live runner captures real traffic and visible failure
state. Intel playback and spoken VoiceOver output are the two retained manual
hardware checks; both are explicitly reported by the coverage verifier.
