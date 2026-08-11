# Cruxwing App — Project Status

## 1. Goal of this stage
Reconcile the large uncommitted macOS app/test change set against the end-to-end quality goal. (`Tests/E2E/TEST_PLAN.md`)
Record what is implemented, what has execution evidence, and what is still only mapped in source. (`Tests/E2E/coverage-manifest.json`)
Preserve the explicit scope boundary: `cruxwing-app` and its API contract are in scope; `cruxwing-web` is excluded. (`Tests/E2E/coverage-manifest.json`)
Leave a fail-closed path to fresh build, Swift, live-media, vendor, accessibility, and ≥90% executed-coverage proof. (`testlib/verify_e2e_coverage.py`)

## 2. Completed

- The end-to-end manifest contains 164 requirements: 110 critical, 48 high, and 6 normal. (evidence: parsed `Tests/E2E/coverage-manifest.json`)
- The manifest explicitly includes `cruxwing-app` and `cruxwing-api` and excludes `cruxwing-web`. (evidence: `Tests/E2E/coverage-manifest.json` `scope`)
- No tracked or untracked changed path resolves into `cruxwing-web`, matching the written scope boundary. (evidence: `Tests/E2E/TEST_PLAN.md`; `git diff --name-only`; `git ls-files --others --exclude-standard`)

- Direct-provider orchestration now classifies retryable failures and can try another vendor before output starts. (evidence: `Sources/MeetGPT/AI/AutoOrchestrator.swift`; `Tests/MeetGPTTests/AutoOrchestratorFailoverTests.swift`)
- Failover candidates are deduplicated by provider, filtered by tier and vision support, and bounded by the selected request's tariff. (evidence: `Sources/MeetGPT/AI/AutoOrchestrator.swift`; `Tests/MeetGPTTests/AutoOrchestratorFailoverTests.swift`)
- Funding failures and OpenRouter-style alternatives are represented in sanitized attempt evidence rather than raw provider errors. (evidence: `Sources/MeetGPT/AI/AutoOrchestrator.swift`; `Tests/MeetGPTTests/DevCallDiagnosticsTests.swift`)
- Backend streaming has correlated request lifecycle logging and explicit output budgets. (evidence: `Sources/MeetGPT/AI/BackendGateway.swift`; `Sources/MeetGPT/AI/OutputTokenBudget.swift`)
- User-facing output is configured for a larger explicit budget instead of silently truncating to a small default. (evidence: `Sources/MeetGPT/AI/OutputTokenBudget.swift`; `Tests/MeetGPTTests/UserFacingOutputBudgetTests.swift`)

- Local-to-Instant transcription switching now uses a recording-settings snapshot and production handoff path. (evidence: `Sources/MeetGPT/Transcription/RecordingSettingsSnapshot.swift`; `Sources/MeetGPT/AppState.swift`)
- The handoff retains pending Local chunks and the partial accumulator until Instant is ready. (evidence: `Sources/MeetGPT/Audio/AudioChunkBuffer.swift`; `Tests/MeetGPTTests/DeepgramHandoffIntegrationTests.swift`)
- Failed pre-ready Instant startup has an explicit rollback path instead of leaving the selected and active engines divergent. (evidence: `Sources/MeetGPT/AppState.swift`; `Tests/MeetGPTTests/TranscriptionEngineLiveSwitchTests.swift`)
- Retiring transcribers use route leases so delayed results can drain without being admitted into a later recording. (evidence: `Sources/MeetGPT/AppState.swift`; `Tests/MeetGPTTests/DeepgramHandoffIntegrationTests.swift`)
- Cumulative mic/system echo suppression and cleaner-system-final preference are implemented. (evidence: `Sources/MeetGPT/Transcription/TranscriptDeduplicator.swift`; `Tests/MeetGPTTests/TranscriptDeduplicatorTests.swift`)
- Private/local transcripts no longer infer a person label solely from capture track. (evidence: `Sources/MeetGPT/Models/TranscriptEntry.swift`; `Tests/MeetGPTTests/LocalTranscriptAttributionTests.swift`)
- Transcript viewport follow/manual-scroll policy has dedicated regression coverage. (evidence: `Sources/MeetGPT/Views/LiveScrollSupport.swift`; `Tests/MeetGPTTests/LiveScrollPolicyTests.swift`)

- Prompt submission publishes an immediate user-turn preview before clarification or provider work completes. (evidence: `Sources/MeetGPT/AppState.swift`; `Sources/MeetGPT/Views/AIResponseView.swift`; `Tests/MeetGPTTests/ComposerImmediateFeedbackTests.swift`)
- Finished follow-up buttons are archived with their exchange and rendered for older answers. (evidence: `Sources/MeetGPT/Models/AIExchange.swift`; `Sources/MeetGPT/Views/AIResponseView.swift`; `Tests/MeetGPTTests/AssistantDialogHistoryTests.swift`)
- Connected write actions are staged for review and revalidate connection scope before commit. (evidence: `Sources/MeetGPT/AI/AnswerActionDispatch.swift`; `Sources/MeetGPT/AppState.swift`; `Tests/MeetGPTTests/ConnectedWriteCommitDispatchTests.swift`)
- Folder attachment UI exposes indexing, cancellation, error, persistent chip, and removal states. (evidence: `Sources/MeetGPT/Views/AIStudioView.swift`; `Tests/MeetGPTTests/ChatFolderAttachmentSourceContractTests.swift`)
- Folder scans are bounded and query-time retrieval selects excerpts rather than sending a whole project tree. (evidence: `Sources/MeetGPT/Context/ContextFolder.swift`; `Tests/MeetGPTTests/ContextFolderTests.swift`)

- Recording context supports meeting, tutorial, lecture, interview, podcast, presentation, and bounded custom labels. (`video` was retired: it was the fallback every unmarked media title fell into and its guidance only repeated what lecture/podcast/presentation already said.) (evidence: `Sources/MeetGPT/Models/RecordingContext.swift`; `Tests/MeetGPTTests/RecordingContextTests.swift`)
- A manual recording type remains authoritative over automatic title/application detection. (evidence: `Sources/MeetGPT/Models/RecordingContext.swift`; `Tests/MeetGPTTests/RecordingContextTests.swift`)
- Meeting-oriented quick prompts are adapted for media into source-grounded learning and project-application prompts. (evidence: `Sources/MeetGPT/Models/RecordingContext.swift`; `Sources/MeetGPT/Views/QuickPromptsView.swift`)
- The live workspace exposes stable accessibility identifiers for recording-type selection and custom entry. (evidence: `Sources/MeetGPT/Views/BrainstormPanel.swift`)
- Deterministic tutorial and generic-video fixtures plus a media continuity/response verifier are present. (evidence: `testlib/tutorial_script.json`; `testlib/generic_video_script.json`; `testlib/verify_media_recording.py`)
- The live harness plays media with `ffplay`, switches `recording.context` during capture, and scores WER and terminology. (evidence: `videotest.sh`; `testlib/score_transcript.py`)

- Connected-app grounding now has tariff-aware source and character budgets, relevance ranking, near-duplicate removal, and fair packing. (evidence: `Sources/MeetGPT/AI/GroundingContextPolicy.swift`; `Tests/MeetGPTTests/GroundingContextPolicyTests.swift`)
- Blind Spot avoids a separate query-derivation model call while interactive grounding retains that option. (evidence: `Sources/MeetGPT/AI/GroundingContextPolicy.swift`; `Tests/MeetGPTTests/GroundingContextPolicyTests.swift`)
- Connected glossary suggestions are bounded, privacy-filtered, cached, and require explicit Add or Dismiss. (evidence: `Sources/MeetGPT/AI/ConnectedGlossarySuggestionService.swift`; `Tests/MeetGPTTests/ConnectedGlossarySuggestionTests.swift`)
- Blind Spot cadence, backoff, tier cost, and active-time accounting have dedicated policy types and tests. (evidence: `Sources/MeetGPT/AI/BackgroundSpendPolicy.swift`; `Sources/MeetGPT/Tariff/CopilotActiveTimeMeter.swift`; `Tests/MeetGPTTests/BackgroundSpendPolicyTests.swift`)
- Development call diagnostics use a nonce-confined, owner-only JSONL stream with bounded and sanitized fields. (evidence: `Sources/MeetGPT/Dev/DevCallDiagnostics.swift`; `Tests/MeetGPTTests/DevCallDiagnosticsTests.swift`)
- Settings AI promo automation reaches the bottom promo field through stable accessibility identifiers. (evidence: `Sources/MeetGPT/Views/Paywall/PaywallView.swift`; `videotest.sh`)
- Promo requests emit bounded lifecycle metadata without placing the code in the privacy-safe network schema. (evidence: `Sources/MeetGPT/Views/Paywall/PaywallAPI.swift`; `Tests/MeetGPTTests/PromoRedemptionReceiptTests.swift`)

- Contract tariff copy now asserts that visible compute credits equal enforced allowances. (evidence: `Tests/contract/creditTariffMirror.test.js`; `contract/contract.json`)
- `contract/contract.json` changed in this stage, and the app-vendored copy was re-synced byte-for-byte with the 8,044-byte, 375-line API authority. (evidence: `git status --short`; `cmp -s contract/contract.json ../cruxwing-api/contract/contract.json`; `wc -c -l`)
- The API/app copies share SHA-256 `780bd6492048520678787501416fe20ad27dee68378e63b000b2c6e7dce2b97f`; the web-vendored copy was not re-synced and retains hash `e78e626a8ebf8a7190db6c025b10693cb9cd5c07dca611f10f803e62a221d696`. (evidence: `shasum -a 256 contract/contract.json ../cruxwing-api/contract/contract.json ../cruxwing-web/contract/contract.json`)
- CI is configured to run scorer self-tests, Swift xUnit output, critical Swift coverage, and evidence upload. (evidence: `.github/workflows/ci.yml`)

## 3. Key technical decisions

- Decision: keep source-marker mapping separate from executed requirement coverage. Rejected alternative: count a referenced test as a passed test. Reason: implementation presence does not prove execution. (evidence: `Tests/E2E/TEST_PLAN.md`; `testlib/verify_e2e_coverage.py`)
- Decision: make missing, stale, skipped, malformed, or failed evidence contribute zero to the 90% gate. Rejected alternative: award partial credit without valid artifacts. Reason: the gate must fail closed. (evidence: `Tests/E2E/TEST_PLAN.md`; `testlib/verify_e2e_coverage.py`)
- Decision: snapshot active recording settings and use explicit handoff for supported live changes. Rejected alternative: let every Settings write mutate active capture implicitly. Reason: session identity and engine readiness must remain coherent. (evidence: `Sources/MeetGPT/Transcription/RecordingSettingsSnapshot.swift`; `Sources/MeetGPT/AppState.swift`)
- Decision: permit provider failover only before visible output. Rejected alternative: switch vendors after partial text. Reason: two streams can splice or duplicate one answer. (evidence: `Sources/MeetGPT/AI/AutoOrchestrator.swift`; `Tests/MeetGPTTests/AutoOrchestratorFailoverTests.swift`)
- Decision: cap fallback by the selected model's admitted cost, including output budget. Rejected alternative: silently spend more after a vendor failure. Reason: orchestration must preserve tariff economics. (evidence: `Tests/MeetGPTTests/AutoOrchestratorFailoverTests.swift`; `Sources/MeetGPT/Models/CreditCostEstimate.swift`)
- Decision: separate retrieval budget from prompt-attachment budget. Rejected alternative: send all connected-app or folder content whenever available. Reason: relevance and token economy require independent bounds. (evidence: `Sources/MeetGPT/AI/GroundingContextPolicy.swift`)
- Decision: treat capture source as transport metadata, not speaker identity. Rejected alternative: label mic as “You” and system audio as another person. Reason: only genuine diarization can support participant attribution. (evidence: `Sources/MeetGPT/Models/TranscriptEntry.swift`; `Tests/MeetGPTTests/LocalTranscriptAttributionTests.swift`)
- Decision: use recording type as compact behavioral orientation. Rejected alternative: inject a long taxonomy into every prompt. Reason: manual type should guide behavior without recurring context cost. (evidence: `Sources/MeetGPT/Models/RecordingContext.swift`; `Tests/MeetGPTTests/RecordingContextTests.swift`)
- Decision: require confirmation and revalidation for external writes. Rejected alternative: execute connector actions directly from model output. Reason: the reviewed connector identity and scope can change before commit. (evidence: `Sources/MeetGPT/AI/AnswerActionDispatch.swift`; `Tests/MeetGPTTests/ConnectedWriteConfirmationTests.swift`)
- Decision: keep development content logs opt-in and owner-only while production network logs stay closed-schema. Rejected alternative: persist raw prompts globally. Reason: useful debugging must not create a production privacy leak. (evidence: `Sources/MeetGPT/Dev/DevCallDiagnostics.swift`; `Sources/MeetGPT/AI/BackendGateway.swift`)
- Decision: generate deterministic media fixtures. Rejected alternative: depend on arbitrary YouTube playback. Reason: ads, availability, accounts, copyright, and content drift make regression evidence irreproducible. (evidence: `videotest.sh`; `testlib/make_meeting_video.py`)
- Decision: keep the extension repository outside this stage. Rejected alternative: place or execute the new suite in `cruxwing-web`. Reason: the explicit scope excludes that repository. (evidence: `Tests/E2E/coverage-manifest.json`; `Tests/E2E/TEST_PLAN.md`)

## 4. Main files changed

- Central state, AI lifecycle, recording lifecycle, settings reconciliation, persistence, and diagnostics: `Sources/MeetGPT/AppState.swift`. (evidence: `git diff --stat`)
- Vendor routing and failover: `Sources/MeetGPT/AI/AutoOrchestrator.swift`. (evidence: `git diff --stat`)
- Backend streaming, timeouts, budgets, and lifecycle logging: `Sources/MeetGPT/AI/BackendGateway.swift`. (evidence: `git diff --stat`)
- Connected context economy: `Sources/MeetGPT/AI/GroundingContextPolicy.swift` and `Sources/MeetGPT/AI/BlindSpotContextCompressor.swift`. (evidence: `git status --short`; `git diff --stat`)
- Background economy: `Sources/MeetGPT/AI/BackgroundSpendPolicy.swift`, `Sources/MeetGPT/AI/CopilotCadence.swift`, and `Sources/MeetGPT/Tariff/CopilotActiveTimeMeter.swift`. (evidence: `git status --short`; `git diff --stat`)
- Output and tariff estimates: `Sources/MeetGPT/AI/OutputTokenBudget.swift` and `Sources/MeetGPT/Models/CreditCostEstimate.swift`. (evidence: `git diff --stat`)
- Live engine handoff: `Sources/MeetGPT/AppState.swift`, `Sources/MeetGPT/Audio/AudioChunkBuffer.swift`, and `Sources/MeetGPT/Integrations/DeepgramStreamer.swift`. (evidence: `git diff --stat`)
- Transcript fidelity: `Sources/MeetGPT/Transcription/TranscriptDeduplicator.swift` and `Sources/MeetGPT/Models/TranscriptEntry.swift`. (evidence: `git diff --stat`)
- Recording classification and media prompt adaptation: `Sources/MeetGPT/Models/RecordingContext.swift`. (evidence: `git status --short`)
- Folder scanning and import: `Sources/MeetGPT/Context/ContextFolder.swift` and `Sources/MeetGPT/Context/ContextImporter.swift`. (evidence: `git diff --stat`)
- Composer and attachment UI: `Sources/MeetGPT/Views/AIStudioView.swift` and `Sources/MeetGPT/Views/AIResponseView.swift`. (evidence: `git diff --stat`)
- Recording-type and Blind Spot UI: `Sources/MeetGPT/Views/BrainstormPanel.swift`. (evidence: `git diff --stat`)
- Transcript scrolling/rendering: `Sources/MeetGPT/Views/LiveScrollSupport.swift`, `Sources/MeetGPT/Views/SelectableTranscriptText.swift`, and `Sources/MeetGPT/Views/TranscriptTextRenderer.swift`. (evidence: `git diff --stat`)
- Settings and connected-app UI: `Sources/MeetGPT/Views/SettingsView.swift` and `Sources/MeetGPT/Views/MCPAppsView.swift`. (evidence: `git diff --stat`)
- Promo UI/API: `Sources/MeetGPT/Views/Paywall/PaywallView.swift` and `Sources/MeetGPT/Views/Paywall/PaywallAPI.swift`. (evidence: `git diff --stat`)
- Dev automation and logs: `Sources/MeetGPT/Dev/LiveTestHooks.swift` and `Sources/MeetGPT/Dev/DevCallDiagnostics.swift`. (evidence: `git diff --stat`; `git status --short`)
- Live runners: `videotest.sh` and `edgetest.sh`. (evidence: `git status --short`)
- Scorers/verifiers: `testlib/score_transcript.py`, `testlib/response_quality.py`, `testlib/verify_e2e_coverage.py`, and `testlib/verify_media_recording.py`. (evidence: `git ls-files --others --exclude-standard`)
- Requirement map and test plan: `Tests/E2E/coverage-manifest.json` and `Tests/E2E/TEST_PLAN.md`. (evidence: `git status --short`)
- Contract mirror and tariff contract test: `contract/contract.json` and `Tests/contract/creditTariffMirror.test.js`. (evidence: `git diff --stat`)
- CI evidence pipeline and packaging: `.github/workflows/ci.yml` and `build.sh`. (evidence: `git diff --stat`)
- Test surface: 160 Swift test files contain 1,482 syntactic test declarations; 50 Swift test files are currently untracked. (evidence: Python declaration count; `git ls-files --others --exclude-standard`)

## 5. Verification

- `git diff --check` — PASS with exit 0 for tracked changes. (actual command: `git diff --check`)
- `bash -n build.sh edgetest.sh videotest.sh` — PASS with exit 0. (actual command: `bash -n build.sh edgetest.sh videotest.sh`)
- Manifest JSON parse and scope check — PASS: 164 requirements and `cruxwing-web` excluded. (actual Python parse of `Tests/E2E/coverage-manifest.json`)
- Bare `npm run test:contract` — FAIL with exit 127 because `npm` is absent from the default shell `PATH`. (actual command: `npm run test:contract`)
- `PATH=/opt/homebrew/bin:$PATH npm run test:contract` — PASS: 5 files and 49/49 tests passed. (actual command: `PATH=/opt/homebrew/bin:$PATH npm run test:contract`)
- The successful contract run warned that npm 11.3.0 does not support the active Node 18.20.5. (actual command output: `PATH=/opt/homebrew/bin:$PATH npm run test:contract`)
- Contract mirror byte comparison — PASS with `cmp` exit 0. (actual command: `cmp -s contract/contract.json ../cruxwing-api/contract/contract.json`)
- Contract SHA-256 comparison — PASS with identical hashes. (actual command: `shasum -a 256 contract/contract.json ../cruxwing-api/contract/contract.json`)
- Python testlib suite — PASS: 22 tests. (actual command: `python3 -m unittest discover -s testlib -p 'test_*.py'`)
- Media verifier self-test — PASS. (actual command: `python3 testlib/verify_media_recording.py --selftest`)
- Tutorial fixture render — PASS at 24.35 seconds with AAC audio and H.264 video. (actual commands: `testlib/make_meeting_video.py`; `ffprobe`)
- Generic-video fixture render — PASS at 22.41 seconds with AAC audio and H.264 video. (actual commands: `testlib/make_meeting_video.py`; `ffprobe`)
- `./build.sh` — PASS: native release Swift build completed in 99.88 seconds, packaged, Developer-ID signed, and installed `/Applications/Cruxwing.app`. (actual command: `./build.sh`)
- Build output explicitly reports Sign in with Apple disabled because `Support/embedded.provisionprofile` is absent. (actual command output: `./build.sh`; file check of `Support/embedded.provisionprofile`)
- The fresh staged and installed binaries share SHA-256 `f53b28ac0d70e76eef364ccc716360f751059a77350443e0d2cbd66c557dadda`. (actual command: `shasum -a 256 build/Cruxwing.app/Contents/MacOS/MeetGPT /Applications/Cruxwing.app/Contents/MacOS/MeetGPT`)
- Staged and installed executables are byte-identical (`cmp` exit 0) and were installed at 22:34:53 after source/test edits through 22:26:20. (actual commands: `cmp -s`; `stat`)
- The fresh installed app passes `codesign --verify --deep --strict` with Developer ID Application authority and Team ID `WQ9JR8SW55`. (actual commands: `codesign --verify --deep --strict`; `codesign -dvv`)
- `swift test --quiet --xunit-output /tmp/cruxwing-app-status-swift-tests.xml` — FAIL with exit 1: 1,481 tests, 1 failure, 0 errors, 0 skipped, and therefore 1,480 passes in 27.878 seconds. (actual command and xUnit `testsuite` attributes)
- The failing test is `a visible user answer has priority over a new Blind Spot wake`; its scheduler evaluation did not reach one within the test wait. (actual command output; `/tmp/cruxwing-app-status-swift-tests.xml`; `Tests/MeetGPTTests/BlindSpotSchedulerRaceTests.swift`)
- Repository file `coverage/swift-tests.xml` is still only a 52-byte XML header and contains no test suites, so it is not valid pass evidence and was not replaced by the temporary failing xUnit result. (actual commands: `stat`; `sed -n '1,80p' coverage/swift-tests.xml`)
- `default.profraw` exists at 1,775,880 bytes but was not evaluated into a current coverage report. (actual command: `stat default.profraw`)
- No completed installed-app live artifact was found for transcript scores, response quality, screenshots, or network summaries; the temporary Swift xUnit is unit-test evidence only. (actual artifact search; `/tmp/cruxwing-app-status-swift-tests.xml`)
- Fail-closed verifier with command self-tests — expected FAIL with exit 1: mapping 99.5% and execution 2.1%. (actual command: `python3 testlib/verify_e2e_coverage.py --manifest Tests/E2E/coverage-manifest.json --run-command-checks --minimum 0.9`)
- Mapping result is 163/164 requirements and weighted 430/432. (actual verifier output)
- Execution result is 3/164 requirements and weighted 9/432 because no xUnit, live artifact, or API coverage summary was supplied. (actual verifier output)
- The three execution-covered requirements are the transcript scorer, response threshold, and connected-grounded response self-tests. (actual verifier output)
- The only unmapped requirement is `OBS-REQUEST-CORRELATION`. (actual verifier output)
- Four requirements remain explicitly manual: Intel live playback, spoken VoiceOver, live vendor credentials, and Calendar reminder OS delivery. (actual verifier output; `Tests/E2E/coverage-manifest.json`)

## 6. Known issues

> **Build/test unblock (2026-08-10, operational note).** The main working tree
> has carried a large set of UNCOMMITTED local-transcription changes (FluidAudio
> SPM dep, Parakeet, DomainLexicon, EmailDomainGlossary) for many sessions, which
> makes `swift build`/`swift test` in the main tree compile that in-flight work.
> This does NOT block clean app work: because those changes are uncommitted, an
> isolated worktree at HEAD is a clean checkout without them —
> `git worktree add --detach <scratch> HEAD`, then copy the gitignored
> `Sources/MeetGPT/Secrets.swift` in (build.sh generates it; a fresh checkout
> lacks it), and `swift test` runs normally there. This is how the anchored
> transcript-window fix (`BrainstormService.cacheStableWindow`, `312346ad`) was
> built and tested. Commit collision-free changes from the main tree by staging
> only your own files, leaving the uncommitted local-transcription work untouched.
>
> **Friend distribution builds BOTH architectures (2026-08-10).** The build step
> for a shippable release is now `./dist-all.sh`, which runs the full
> notarize.sh pipeline for arm64 AND x86_64 — so friends on Apple Silicon and on
> Intel Macs both get a Gatekeeper-ready build. Output in `dist/`:
> `Cruxwing-AppleSilicon.zip` and `Cruxwing-Intel.zip`, each with a `.sha256`.
> arm64 runs first, so an Intel-leg failure still leaves the Apple Silicon build
> shippable. (Single-arch quick turn remains `MEETGPT_ARCH=arm64 ./notarize.sh`.)

> Most entries below are a frozen snapshot from an E2E-verification session that
> predates the current backlog work. Corrected entries are struck through with
> the verified update; the remaining ones (Sign in with Apple, live installed-app
> artifacts, hosted-provider OAuth, manual OS checks) are genuinely still open.

- Executed coverage is 2.1%, far below the required 90%; source mapping must not be reported as completion. (evidence: fail-closed verifier output; `Tests/E2E/TEST_PLAN.md`)
- `OBS-REQUEST-CORRELATION` is unmapped because the manifest expects `closed-schema request-correlated prepare/start/terminal`, while the harness currently says `closed-schema assistant and promo request lifecycles...`. (evidence: `Tests/E2E/coverage-manifest.json`; `videotest.sh`; verifier output)
- ~~The fresh Swift run is red: 1 of 1,481 tests failed in `BlindSpotSchedulerRaceTests`.~~ **Resolved (verified 2026-08-10):** the suite is green at **2,306** tests. The race was fixed (see Next steps item 1, 980c98c) and the suite has grown ~800 tests since this snapshot.
- No fresh Swift critical-coverage JSON exists in `coverage/`. (evidence: `find coverage -maxdepth 2 -type f`)
- No API critical `coverage-summary.json` was supplied to the app verifier. (evidence: verifier `evidenceInputs`; `Tests/E2E/coverage-manifest.json`)
- No completed installed-app live artifact is available for WER, latency, prompt, Settings, promo, Blind Spot, network, or media requirements. (evidence: `/tmp` artifact search; verifier `evidenceInputs`)
- Sign in with Apple is unavailable in this build until `Support/embedded.provisionprofile` is supplied. (evidence: `./build.sh` output; provisioning-profile file check)
- Bare contract verification is not reproducible on the default `PATH`; it currently needs `/opt/homebrew/bin/npm`. (evidence: failed bare command and successful absolute command)
- The npm/Node toolchain is version-mismatched: npm 11.3.0 warned against Node 18.20.5. (evidence: contract command output)
- ~~`default.profraw` and `testlib/__pycache__/*.pyc` untracked and not ignored.~~ **Resolved (verified 2026-08-10):** both are `git check-ignore`d now. `coverage/swift-tests.xml` is tracked deliberately as retained evidence.
- Branch `feat/assistant-actions-and-context` is at `a6644d0e3496` and matches its remote, but the working tree remains too mixed for one commit: 112 modified tracked entries and 68 untracked entries. (evidence: `git rev-list --left-right --count`; `git status --porcelain`; `git diff --stat`)
- The syntactic declaration count is inventory only and does not equal executed tests. (Still true as a principle; the specific 1,481-with-one-failure figure is stale — the run is green at 2,306.)
- Real hosted-provider OAuth/read/write checks still require operator credentials and approved destinations. (evidence: manual `CONNECTED-LIVE-VENDOR-CREDENTIAL-MATRIX` in `Tests/E2E/coverage-manifest.json`)
- Spoken VoiceOver and Calendar notification delivery remain interactive OS checks. (evidence: manual requirements in verifier output)
- Intel live playback remains manual even though Intel build artifacts exist. (evidence: manual `VIDEO-INTEL-LIVE-PLAYBACK`; `.build/x86_64` inventory)
- The promo-code UI path is implemented and mapped, but no fresh live receipt/screenshot artifact is present. (evidence: `videotest.sh`; `Tests/MeetGPTTests/PromoRedemptionReceiptTests.swift`; `/tmp` artifact search)

## 7. Tried and rejected

- Treating mapping coverage as executed coverage is rejected; the verifier reports 99.5% mapping but only 2.1% execution. (evidence: verifier output; `Tests/E2E/TEST_PLAN.md`)
- Treating the 52-byte xUnit header as a Swift pass is rejected because it contains no suites or cases. (evidence: `coverage/swift-tests.xml`; `stat`)
- Treating the earlier signed app as current was rejected; the fresh build now postdates the latest source/test edits. (evidence: pre-build and post-build `stat` comparisons; `./build.sh`)
- Running bare `npm run test:contract` was rejected by the shell environment with exit 127; the explicit Homebrew npm path succeeded. (evidence: both actual command outputs)
- Treating a successful build as a full Swift test pass is rejected; the build passed but the fresh 1,481-test Swift run has one Blind Spot scheduler failure. (evidence: successful `./build.sh`; `/tmp/cruxwing-app-status-swift-tests.xml`)
- Relying on source log markers alone for request correlation is rejected; the manifest also requires fresh live artifacts. (evidence: `OBS-REQUEST-CORRELATION` in `Tests/E2E/coverage-manifest.json`)
- Pairwise transcript deduplication alone is rejected for cumulative acoustic echo. (evidence: `Sources/MeetGPT/Transcription/TranscriptDeduplicator.swift`; `Tests/E2E/TEST_PLAN.md`)
- Capture-track labels as speaker identity are rejected for the private/local engine. (evidence: `Tests/MeetGPTTests/LocalTranscriptAttributionTests.swift`)
- Config-only transcription-engine switching is rejected in favor of explicit handoff, readiness, drain, and rollback state. (evidence: `Sources/MeetGPT/AppState.swift`; `Tests/MeetGPTTests/DeepgramHandoffIntegrationTests.swift`)
- A single-provider terminal funding error is rejected when a tariff-compatible alternate vendor can be tried before output. (evidence: `Sources/MeetGPT/AI/AutoOrchestrator.swift`; `Tests/MeetGPTTests/AutoOrchestratorFailoverTests.swift`)
- Sending all connected-app or folder text on every prompt is rejected in favor of bounded, relevant, deduplicated excerpts. (evidence: `Sources/MeetGPT/AI/GroundingContextPolicy.swift`; `Sources/MeetGPT/Context/ContextFolder.swift`)
- Depending on arbitrary live YouTube playback is rejected for deterministic media regression evidence. (evidence: `videotest.sh`; `testlib/tutorial_script.json`; `testlib/generic_video_script.json`)
- Unattended real-account writes are rejected; writes remain staged and confirmation-required. (evidence: `Sources/MeetGPT/AI/AnswerActionDispatch.swift`; `Tests/MeetGPTTests/ConnectedWriteConfirmationTests.swift`)

## 8. Next steps

1. ~~`BlindSpotSchedulerRaceTests`~~ — **done (980c98c)**. The counter sat below the decline gates, so a wake that correctly deferred to a visible answer was indistinguishable from a dead scheduler. Moved above them; `BackgroundSpendPolicyTests`'s one-second poll for a MainActor start was de-flaked at the same time.
2. ~~`OBS-REQUEST-CORRELATION`~~ — **done (e4ebd49)**. It pointed at a `videotest.sh` string that never existed; repointed at the four literals that actually enforce prepare/start/terminal correlation. All 164 markers now resolve, and `testlib/test_verify_e2e_coverage.py` fails loudly if one drifts again instead of silently unmapping the requirement.
3. ~~Artifact policy~~ — **done (3e09c60)**. `coverage/` is published as evidence; profraw and `__pycache__` are ignored.
4. ~~`npm run test:contract`~~ — **done**. 49/49 on Node v24.1.0.
5. ~~xUnit evidence~~ — **done**. 1481/1481 passing, retained at `coverage/swift-tests.xml`.
6. ~~Critical Swift coverage~~ — **done**. Lines 97.21% (592/609), bug-critical symbols 94.74% (324/342), both against a 90% target.
7. ~~API coverage summary for `coverageChecks`~~ — **done (5ae6d91)**. `bash verify-evidence.sh` regenerates every deterministic artifact in dependency order and verifies. Executed coverage 0% to **63.7%**; the 0% was a freshness rejection, not a coverage gap — the verifier discards any report older than the sources it covers. Every requirement reachable without the installed app is now covered; the remaining 59 are live-gated or manual and the script names them as such.
8. `Support/embedded.provisionprofile` — supply the correct profile and rerun `./build.sh` if Sign in with Apple is required in this validation stage.
9. `Sources/MeetGPT/AI/BackendGateway.swift` — restart the matching local API after contract/provider changes before installed-app work.
10. `videotest.sh` — **clean condition RUN (first live evidence in this session).** Artifacts at
    `/tmp/cruxwing-videotest-20260808-075333/`. Screen Recording and microphone capture are confirmed working end to
    end; Accessibility is NOT granted, so the AX-driven promo check is skipped and entitlement comes through the dev
    hook (see 01ff2c0 — one permission no longer gates the whole matrix).

    **Passing:** recording start/stop correlation, capture continuity through Settings, Local→Instant engine switch
    mid-call, Instant caption causality, speaker attribution **1.0**, viewport pinning, the full Settings-during-call
    matrix (General, AI, Transcription, Connected apps, Account/Privacy), deferred next-recording isolation, network
    lifecycle NDJSON, dev prompt/workflow diagnostics.

    **Failing, and these are product signals rather than harness bugs:**

    | Check | Measured | Bar |
    |---|---|---|
    | WER | **0.5726** | 0.35 |
    | system-track duplication | 0.1111 | 0.10 |
    | response relevance/grounding | 0.4307 | — |
    | non-error completion | 0.375 (3 of 8 attempts) | — |
    | Blind Spot terminal attempt | no terminal outcome in 75s | — |

    Read with care before acting: this is ONE run against synthetic TTS played through the speakers and recaptured,
    which is a harder path than a real call — but the 0.35 bar was set for this same harness, so 0.57 is a genuine
    miss against its own yardstick. Of the 8 prompt attempts, 4 were superseded and 1 cancelled, which is the
    unpredictable-timing schedule working as designed; the 3 that completed scored 0.975 fulfilment and 0.963
    coherence, so what lands is good and the problem is how much lands. Max latency 42s.

    **Transcription accuracy work (measured, not guessed).** Two fixes, both far outside measurement noise:

    | Change | WER | Note |
    |---|---|---|
    | starting point | 0.5726 | 53 of 124 words captured |
    | overlapping decode windows + `ChunkStitcher` | ~0.38 | hard 6s cuts split utterances; the halves decoded without context and the short-fragment filter then deleted them |
    | relaxed short-fragment bar | ~0.10–0.16 clean, 0.3548 noisy | dropped-segment count tracked WER almost monotonically across four runs |

    **The live metric is noisy — read every LIVE comparison with this.** Three runs of an IDENTICAL configuration
    measured 0.1048, 0.1613 and 0.1452. Within a single session the spread is tighter (0.008 over two runs) but
    ACROSS sessions it moves much more. `testlib/wer_trials.sh` runs N repeats and prints mean and spread; treat any
    difference smaller than the spread as unmeasured. Two hypotheses were accepted and one rejected on gaps smaller
    than that before this was noticed.

    **That noise is now solved for A/B work — the cause was the acoustic path, not the engine.**
    `Tests/MeetGPTTests/RealCallTranscriptionHarness.swift` feeds a real recorded call straight into the same
    `AudioChunkBuffer` the live capture feeds, so chunking, the VAD gate and stitching are all still exercised, but
    the speaker-to-microphone path is gone. Two runs of the same audio produced **byte-identical scores** (same S, D
    and I). Tuning decisions belong on this harness; the live path stays as the acoustics check.

    Ground truth comes from AssemblyAI (own confidence 0.980 on both segments), so the absolute number means
    "distance from a good cloud engine", not "distance from truth". Build a fixture with
    `testlib/build_real_call_fixture.sh <recording>`; it picks the speech-densest window automatically. The fixture is
    real speech by real people and is gitignored — it must stay that way.

    **What the real call showed, and the fix it produced.** The first deterministic run scored WER 0.1810 with a
    breakdown no single number would have revealed: **S 6, D 7, I 113** — 90% of the error was insertions, while
    recall was 0.981 and term recall 20/20. The pipeline was hearing the call almost perfectly and then padding the
    output. 8 of the 12 largest inserted spans turned out to duplicate text the reference says elsewhere: they were
    overlap regions the two decodes worded differently ("like using the back" vs "like using the background"), and
    `ChunkStitcher`'s exact-match requirement missed every one of them — a single disagreeing word broke the match.

    Fuzzy seam matching (LCS agreement ≥ 0.55, best-agreeing length rather than longest-above-bar) fixed it:

    | | exact only | fuzzy 0.55 |
    |---|---|---|
    | WER, tuning segment | 0.1810 | **0.0963** |
    | WER, holdout segment | 0.1786 | **0.1169** |
    | insertions (tuning) | 113 | 41 |

    Swept over five thresholds on both a tuning and a holdout segment; the full table and the reason for choosing
    0.55 over the marginally-better-on-mean 0.45 are in `ChunkStitcher.swift`. Short version: WER counts a deletion
    and an insertion the same, and this product should not — a duplicated word is skimmed past, a deleted one is
    speech the user never sees. 0.45 is where deletions start accelerating.

    Rejected on measurement: overlap 2.5s (worse), 10s windows (worse). Implemented but DEFAULTED OFF because it did
    not beat the clock: pause-aware chunk boundaries (`TRANSCRIPTION_BOUNDARY_SLACK_SECONDS`), which end a window at
    silence instead of on time.

    **One recording was not enough, and the corpus changed the conclusion.** Five recordings — the Zoom call plus four
    that ship their own subtitles (`testlib/build_srt_fixtures.py`, human captions, nothing uploaded) — differing in
    accent, acoustics and format:

    | recording | `small` WER | recall |
    |---|---|---|
    | Zoom call (US) | 0.0963 | 0.963 |
    | Seattle U-Law webinar | 0.1081 | 0.937 |
    | Interview (Morrell) | 0.1770 | 0.901 |
    | Wikimedia onboarding | 0.2690 | 0.834 |
    | ISOC Zimbabwe | 0.4199 | 0.701 |
    | **mean** | **0.2141** | |

    The single-fixture 0.0963 was not representative. The spread is not chunking either: on the worst recordings the
    error is dominated by SUBSTITUTIONS (189 against 67 deletions on ISOC) — speech heard and got wrong, not speech
    lost. That tracks accent, and it is invisible on a US-English fixture.

    **Model sweep over the whole corpus** (`testlib/model_sweep.sh`, results accumulate in
    `testlib/model_sweep_results.tsv`):

    | model | mean WER | worst (ISOC) |
    |---|---|---|
    | `large-v3` | **0.1425** | **0.2749** |
    | `small` (current default on plain chips) | 0.2141 | 0.4199 |
    | `base` | 0.2600 | 0.5146 |
    | `medium` | *(ISOC only)* — | 0.4222 |

    `large-v3` wins on mean AND worst case, which is the bar: a better mean with a worse worst case only means the
    model fits the easy recordings harder. It is not a smooth size curve — `medium` was no better than `small` on the
    accent case while `large-v3` cut it by a third, which is large-v3's multilingual training rather than capacity.

    **Not yet actionable as a default change.** `LocalWhisperModel.recommendedDefault` already gives `large-v3` to
    Max/Ultra and recent Pro, and `small` to plain chips. Widening it needs the realtime factor, not just accuracy:
    `medium` took 365s for 300s of audio (1.2x realtime) and could never run a live call however it scored. The
    corpus test now reports a per-recording realtime factor for exactly this decision.

    **Accented speech is the real weakness, and the cause is the model — not any setting.** Five EdAcc conversations
    (Indian, Ghanaian, Romanian, Chinese pairings) with human gold references now sit in the corpus, making ten
    recordings and ~8,300 reference words. On `small`:

    | recording | WER | S | D | I | recall |
    |---|---|---|---|---|---|
    | Chinese × Chinese | 0.3452 | 107 | 108 | 18 | 0.681 |
    | Indian × Indian | 0.3329 | 89 | 168 | 20 | 0.691 |
    | Indian × Ghanaian | 0.3007 | 67 | 136 | 46 | 0.755 |
    | Indian × Romanian | 0.2735 | 105 | 108 | 63 | 0.789 |
    | Chinese × American | 0.2287 | 82 | 85 | 26 | 0.802 |

    20–32% of accented speech is DROPPED rather than misheard — the opposite profile to ISOC, which was
    substitution-dominated. Across the ten-recording corpus deletions (754 on `small`, 638 on `large-v3`) are now the
    single largest error category, ahead of substitutions.

    **Three plausible causes were tested and all three are wrong.** Recorded so nobody re-runs them:

    - The short-fragment confidence gate (`isReliableShortFragment`, `avgLogProbability >= -0.75`). Relaxing to
      -1.10 moved deletions only 164→154 on Indian × Indian, and -1.60 and -9.00 — the gate fully disabled — produced
      results IDENTICAL to -1.10. It is not binding.
    - Overlapping conversational speech. Zero overlapping utterance timestamps in the references.
    - The VAD gate. Disabling `vadEnabled` produced byte-identical scores on both accent fixtures.

    What remains is Whisper emitting less text for accented audio, which no pipeline setting reaches. `large-v3` is
    the only lever that moved it: Indian × Indian 0.3329 → 0.2620 with deletions 168 → 107.

    | model, ten recordings | mean WER | worst | subs | dels | ins |
    |---|---|---|---|---|---|
    | `large-v3` | **0.1912** | 0.3007 | 573 | 638 | 374 |
    | `small` | 0.2551 | 0.4199 | 861 | 754 | 508 |

    **Decode window length is the largest lever found, larger than model choice — and the earlier rejection of it
    was made on the noisy live metric.** "10s windows (worse)" was concluded before the deterministic harness
    existed, using a metric whose own spread was wider than the differences being compared. Re-measured:

    | window | Canva call | Indian × Indian | Chinese × Chinese |
    |---|---|---|---|
    | 6s (current) | 0.0977 | 0.3329 | 0.3630 |
    | 12s | 0.0489 | 0.3462 | 0.3615 |
    | 20s | 0.0374 | 0.3666 | 0.3304 |
    | **30s** | **0.0302** | **0.2680** | **0.2919** |

    30s wins everywhere — 69% off the clean call and 20% off both accent cases, beating the entire `small` to
    `large-v3` upgrade. The curve is NOT monotonic: on Indian × Indian, 12s and 20s are both WORSE than 6s and only
    30s helps, because 30s is Whisper's native training window and anything shorter fights its internal padding. A
    coarse sweep that stopped at 10s or 20s would have concluded windows do not help, which is what happened.

    **The latency objection is real and the obvious workaround only half-works.** A 30s window means a 30s wait for
    a line. `AudioChunkBuffer` already supports overlap, so chunk 30s with overlap 24s advances 6s and gives 30s of
    context at today's cadence. Measured (needs the overlap cap raised past `chunkSeconds / 2`, and
    `ChunkStitcher.maximumOverlapWords` raised from 24 to ~140 or the 24-second repeat is far beyond the seam search
    — left at 24, WER was 3.56 with 2,471 insertions):

    | config | Canva | Indian × Indian | line latency |
    |---|---|---|---|
    | 6s windows | 0.0977 | 0.3329 | 6s |
    | 30s sliding, 6s cadence | 0.0517 | 0.3257 | 6s |
    | 30s hard windows | 0.0302 | 0.2680 | 30s |

    Sliding recovers about half the gain on clean audio and essentially none on accented audio. The reason is
    structural: sliding keeps only the LAST 6s of each 30s decode, which is the region Whisper handles worst because
    it sits at the window boundary, while hard windows keep the well-contextualised middle. Sliding also costs 5x the
    decode compute for that half-gain.

    So this is a genuine latency/accuracy tradeoff rather than a free win, and the shape of it points somewhere
    specific: **the best available design is to keep 6s windows live and re-transcribe the saved audio at 30s windows
    after the call**, where latency does not exist. That would give the archived transcript — the one Blind Spots,
    search and export all read — the 0.0302/0.2680 numbers rather than 0.0977/0.3329. Not implemented; recorded as
    the next substantial piece of work.

    **Local Whisper has a ceiling on accented speech that no setting reaches; a cloud engine clears it.** Measured on
    the five EdAcc recordings against their human gold references, using the same scorer as every local number:

    | engine | mean WER, accented |
    |---|---|
    | AssemblyAI (cloud) | **0.1496** |
    | Whisper `large-v3` (local) | 0.2398 |
    | Whisper `small` (local default) | 0.2962 |

    38% better than the best local model, 49% better than the shipped default. Caveat kept deliberately: AssemblyAI's
    errors are ALSO deletion-dominated (D 59–94 against S 16–47), because the gold references are linguist
    transcriptions carrying backchannels and disfluencies that every ASR omits. Part of the deletion count on every
    engine is therefore irreducible rather than a defect.

    **Four causes of the accent deletions have now been tested and eliminated** — recorded so nobody re-runs them:
    the short-fragment confidence gate (disabling it entirely changes nothing), overlapping speech (no overlapping
    timestamps), the VAD gate (disabling it is byte-identical), and `temperatureFallbackCount` (0 and 2 are
    byte-identical on Indian × Indian). The remaining gap is the model's own output on accented audio.

    **Dictation apps are not a route.** Wispr Flow and superwhisper are microphone-only, push-to-talk, and deliver
    text by typing into the focused field. Cruxwing needs continuous dual-track capture — system audio via
    ScreenCaptureKit is where the other participants are — with per-source attribution. They also run the same
    Whisper weights already used here, so there is no accuracy to gain.

    **On accented WORK calls the gap is decisive, and the reference tier is what makes it readable.** Fixtures 10–15
    are accented people doing real work — registry operations, IPv6 deployment, IoT architecture, routing-protocol
    design — so they carry the domain acronyms and product names that casual benchmarks never contain. They ship in
    three reference tiers, and the tier changes how far the number can be trusted:

    | fixture | reference | Whisper `small` | AssemblyAI |
    |---|---|---|---|
    | 10 ICANN gTLD (Chinese) | CART human | 0.2153 | **0.0652** |
    | 11 ICANN gTLD (Indian × Chinese) | CART human | 0.1962 | **0.0523** |
    | 12 GFCE IPv6 (Indian) | auto-caption | 0.1825 | 0.1540 |
    | 15 IETF PCE BFD (Indian) | terms-only | 0.3875 | 0.3271 |
    | 14 IETF CATS (Chinese) | terms-only | 0.5510 | 0.4014 |

    On the two human-captioned fixtures — the only ones where WER is a real number — AssemblyAI is **70–73% better**.
    The gap narrows precisely where the reference is weakest, which is itself informative: an auto-caption reference
    was produced by an ASR that shares Whisper's failure modes, so it flatters Whisper and understates the gap. Do
    not read 12/13/14/15 as evidence that the engines are close.

    **Decision: route this audio to AssemblyAI rather than the local model.** No local Whisper configuration
    measured here comes near it, and four separate causes of the local deletions have already been eliminated
    (confidence gate, overlap, VAD, temperature fallback). Implementation is NOT a drop-in: `assemblyai` currently
    appears only in `USAGE_ENGINES` for metering, with no provider behind it. It needs the streaming API — the async
    file API would mean upload-and-poll per 6-second chunk — plus the same credit metering, key handling and offline
    fallback the Deepgram path already has. `functions/transcriptionGateway.js` and the Deepgram token grant are the
    shape to copy.

    **The decoder-prompt glossary is the largest single win on work calls, and it already exists unused.**
    `LocalWhisperTranscription.glossaryPromptTokens` feeds the configured glossary to WhisperKit as prompt tokens.
    It had never been measured. Against the two fixtures carrying `expectedTerms`:

    | fixture | glossary off | glossary ON | WER off → on |
    |---|---|---|---|
    | 14 IETF CATS (Chinese) | 8/15 terms (0.53) | **14/15 (0.93)** | 0.5510 → 0.5476 |
    | 15 IETF PCE BFD (Indian) | 4/7 terms (0.57) | **7/7 (1.00)** | 0.3875 → 0.4246 |

    It also removes the *corruptions*, which matter more than the misses: without it, "PCE" came back as "piece",
    "CATS" as "cast", plus "MPLS-TE", "YANG model" and "OAM". A corrupted term is worse than a dropped one because it
    reads as a confident real word and no reader can tell it was wrong.

    Two honest limits on that result:

    - It is a TRADE on fixture 15 — every term recovered, but WER rose 0.3875 → 0.4246 with deletions 196 → 217. A
      prompt biases the decoder, and it spent some common words to buy the domain ones. For a work call that trade is
      right; it is still a cost, not a free win. Both WER numbers here are against references the corpus marks
      "not scoreable", so the WER side is weak evidence in either direction.
    - The glossary was built FROM `expectedTerms`, i.e. the answer key. This measures the CEILING the mechanism can
      reach when given the right terms, not what a user gets by default.

    That second point is the product work, and `GlossaryMiner` now extracts candidates from user-supplied text
    (acronyms, hyphenated technical compounds, product names), refusing sentence openers, everyday initialisms and
    ordinary prose. Its 14 tests include recovering the exact vocabulary fixtures 14 and 15 needed.

    **But the SOURCE decides whether it helps, and a meeting title alone does not.** Mining a glossary from only the
    pre-call topic line — what a calendar invite carries — and measuring end to end:

    | glossary | 14 CATS | 15 PCE | WER |
    |---|---|---|---|
    | off | 8/15 (0.53) | 4/7 (0.57) | 0.5510 / 0.3875 |
    | mined from the topic line | 10/15 (0.67) | 4/7 (0.57) | 0.6003 / 0.4258 |
    | full term list (the ceiling) | 14/15 (0.93) | 7/7 (1.00) | 0.5476 / 0.4246 |

    A title yields two or three terms. It recovered "PCE" and "CATS" and nothing else, and a thin prompt made WER
    WORSE on both fixtures — recall fell 0.566 to 0.478 on 14 — so it paid the decoder-bias cost without buying the
    vocabulary. Auto-populating from the meeting title alone would be a regression.

    The lever is real but it needs a RICH source: attached context documents, connected-app project vocabulary
    (`connectedGlossarySuggestionStatus`), or a pasted agenda. **Now wired to attached documents**
    (`AppState.refreshContextGlossarySuggestions`), which is the only automatic source satisfying both conditions —
    the terms are correct because the user wrote or attached them, and they come from outside the audio. Unlike the
    connected-app path it spends no model call, and it proposes rather than applies: the glossary biases every future
    recording, so it stays the user's to change. Wiring it to the title remains rejected on measurement.

    **A partial glossary generalises, which is what makes mining prose worth doing.** The 0.53→0.93 result handed the
    decoder a curated term list; real context documents are prose. Mining a plausible prose agenda instead:

    | fixture | key terms present in the prose | terms recovered | baseline | curated ceiling |
    |---|---|---|---|---|
    | 14 CATS | **5 of 15** | **13/15 (0.87)** | 8/15 (0.53) | 14/15 (0.93) |
    | 15 PCE | 5 of 7 | 5/7 (0.71) | 4/7 (0.57) | 7/7 (1.00) |

    On CATS the document contained a third of the answer key and recovered nearly all of it — priming with SOME
    domain vocabulary helps the decoder get OTHERS right. A context document does not have to be complete to pay.

    The WER cost is real and consistent: 0.5510 → 0.6139 and 0.3875 → 0.4432, matching every other glossary
    configuration tested. On a work call that trade is right — a corrupted acronym is unreadable while a dropped
    "the" is not — but it is a trade. Both WERs are against references the corpus marks "not scoreable", so that
    side stays weak evidence.

    Deliberately NOT mined from the LOCAL transcript: if the engine already misheard "PCE" as "piece", its own
    transcript teaches it "piece".

    **An imported Fireflies past call is different, and is now mined** (`proposeGlossaryFromPastTranscript`). It is a
    DIFFERENT engine, so its mistakes do not correlate with the local one's, which is the property self-priming
    lacked. It is also the cheapest rich source available — no upload, no credits, and a past call from the same team
    carries the vocabulary of the calls still to come. It is still ASR, so a term must recur at least twice in one
    transcript before it is offered; a written agenda can name a term once and mean it, a machine transcript saying
    something once may simply have misheard it. Fireflies transcript quality has never been measured against this
    corpus, so that bar is doing real work rather than being belt-and-braces.

    **That is measured, not assumed.** Two-pass self-priming — transcribe, mine the output with `GlossaryMiner`, then
    re-transcribe primed with what the first pass found — is an appealing idea because Whisper often gets a term right
    in one chunk and wrong in another, and post-call it costs only time. It makes things worse:

    | fixture | terms | WER |
    |---|---|---|
    | 14 CATS | 8/15 → **7/15** | 0.5510 → **0.5918** |
    | 15 PCE | 4/7 → 4/7 | 0.3875 → **0.4780** |

    The first pass yielded 17–18 candidates, but they include the corruptions themselves — "piece" and "cast" are
    shaped exactly like the acronyms the miner is looking for. Priming on them reinforces the errors it was meant to
    fix. The glossary only pays when the terms are CORRECT and come from outside the audio.

    **Live run triage (2026-08-08, 71 passed / 25 failed).** The failures are not 25 problems:

    - **16 are one root cause.** The Settings mutation worker cannot drive the Settings window without Accessibility
      for the *test-running* process, and every `…=missing` failure descends from it — General preferences, engine
      switch, Instant causality/diarization/viewport, deferred isolation, control matrix, glossary-during-call,
      grounding-during-call, Account and Privacy, restoration, capture continuity, closing Settings. Granting
      Accessibility (System Settings → Privacy → Accessibility) should clear all of them at once.
    - **`media-tutorial vocabulary recall 0.4` is a fixture mismatch, not a regression.** The live glossary fixture
      (`LiveTestHooks`, `transcription.glossary-fixture`) supplies `CruxwingLiveFixture, Falcon-SLA, Kubernetes,
      idempotent, Postgres, SLA`, while `testlib/tutorial_script.json` is scored on `idempotent, Postgres,
      idempotency, jitter, deduplication`. The fixture supplies two of the five and omits exactly the three that
      failed. Deliberately NOT fixed by pasting the missing three in: that makes the check tautological — it would
      then test the glossary rather than the transcriber. The measured finding that a PARTIAL glossary generalises
      suggests extending the fixture with domain-ADJACENT terms and re-measuring, which is a real experiment; copying
      the answer key is not.
    - **`media-tutorial WER 0.4615` against a 0.45 bar** is marginal and sits inside the live harness's own measured
      spread of 0.056. Not evidence of anything on its own.

    **The live evidence chain cannot credit any of this yet, by design.** `verify-evidence.sh` never passes
    `--live-artifacts`, and the verifier rejects the run anyway on two counts: the report predates the manifest and
    harness sources, and the suite did not finish with zero failed checks. So the ~64% ceiling holds until a videotest
    run passes cleanly — which needs Accessibility first.

    **Correction: the cloud-transcript path already exists, and two earlier claims here were wrong.**
    `AppState.diarizeSession` replaces the system-track transcript with a cloud one —
    `transcript = (diarized + mine)` — keeping only the mic track from local Whisper. The system track is where
    everyone ELSE on the call is, which is exactly where the accented-speech problem lives. So "route accented audio
    to a cloud engine" is substantially implemented, not unbuilt.

    Two things previously recorded here are wrong and are retracted:

    - "`assemblyai` exists only in `USAGE_ENGINES` with no provider behind it." There is a full `AssemblyAIService`
      client in the app, used as the BYO-key diarization fallback, and its utterances carry text.
    - "It needs the streaming API built." For the archived transcript it does not: the post-call replacement path is
      already there, `/api/diarize` takes the whole call as one upload, and `ServerDiarizationService` already
      handles auth, the 600 s timeout and the multipart body. Streaming would only be needed for LIVE captions.

    **Do NOT make it automatic when Fireflies is connected.** Fireflies records the same meeting itself, and
    `scheduleFirefliesEnhance` already merges its transcript automatically after the call — default on, retried on a
    widening schedule (5, 5, 10, 20 min) because Fireflies needs time to leave, upload and transcribe. For those
    users the better transcript already arrives with no second upload and no transcription credits, because they
    have already paid Fireflies. An automatic cloud pass would bill them for work in progress.

    That also exposes a gap in every engine ranking in this document: **Fireflies transcript quality has never been
    measured here.** The comparisons cover only engines that could be run against the fixtures. The right default
    order is Fireflies when connected, the cloud pass when it is not, local Whisper offline — and only the second and
    third of those are backed by numbers.

    **What is actually missing is that it never runs (for users WITHOUT Fireflies).** `diarizeSession` has one caller, `diarizeNow`, documented as
    "on demand (e.g. from a button)". It is not triggered when a recording stops. It also bills —
    `reserveTranscriptionCredits(userId, 'openai-diarize', chunks)` — which is why it is manual, and why making it
    automatic is a pricing decision rather than a code change. The same discoverability failure as the connected-app
    glossary button, but worth far more: on human-referenced work calls the cloud transcript measured 70% better.

    **And the production path is NOT the engine that was measured.** `canDiarizeOnServer` is
    `llmViaBackend && wheesprConnected`, so a signed-in user gets `/api/diarize`, which uses
    `gpt-4o-transcribe-diarize` — chosen deliberately to remove the AssemblyAI vendor relationship. The 0.1496 accent
    mean and the 0.0652/0.0523 work-call figures are AssemblyAI's. `gpt-4o-transcribe-diarize` has NOT been measured
    against this corpus, so it is unknown whether the shipping path carries that gain. Measuring it is the next step
    and needs only a signed-in token against `/api/diarize`.

    **The shipping engine is now measured, and it is worse than AssemblyAI but far better than local.**
    `gpt-4o-transcribe-diarize` run with the exact request `/api/diarize` sends (`diarized_json`,
    `chunking_strategy=auto`), scored by the same scorer against the same references. Compared on the 9 fixtures
    both engines transcribed — the earlier per-engine means covered different subsets and were not comparable:

    | | AssemblyAI | `gpt-4o-transcribe-diarize` (ships) | local `small` | local `large-v3` |
    |---|---|---|---|---|
    | 9 common fixtures | **0.1379** | 0.1726 (+25%) | — | — |
    | accented conversation (EdAcc, 5) | **0.1496** | 0.2024 | 0.2962 | 0.2398 |
    | work calls, human refs (10, 11) | **0.0587** | 0.0890 | 0.2057 | — |

    Three things follow:

    - **The shipping path is a large win over local**: 57% better than `small` on the human-referenced work calls,
      32% better on accented conversation. Better than `large-v3` too, without the 0.89x realtime cost. So surfacing
      the existing button is worth doing on its own merits.
    - **AssemblyAI is still better by 25%** overall and 26% on accented speech. Switching `/api/diarize` to it is a
      real gain, but it reintroduces the vendor relationship `gpt-4o-transcribe-diarize` was chosen to remove — a
      commercial decision, not a technical one.
    - **The earlier "70% better" figure was AssemblyAI, not the shipping path.** For what users actually get today
      the number is 57% on those fixtures. The claim is corrected here rather than left standing.

    **Fireflies is now measured, on one fixture, and the clouds are effectively tied.** Uploaded the IETF PCE
    fixture (CC BY 4.0, already public) and scored the result with the same scorer against the same reference:

    | engine | 15 PCE | S | D | I |
    |---|---|---|---|---|
    | Fireflies | **0.3179** | 48 | 201 | 25 |
    | AssemblyAI | 0.3271 | 51 | 199 | 32 |
    | `gpt-4o-transcribe-diarize` (ships) | 0.3353 | 48 | 201 | 40 |
    | local `small` | 0.3875 | 68 | 196 | 70 |

    Read it as a tie between the three clouds — 0.018 separates them on ONE recording — and as a clear 15–18% win for
    any of them over local. It does NOT establish a cloud ranking; the other engines were measured over 9–16
    recordings and this is n=1.

    All three clouds land on **D ≈ 200 deletions**, differing almost only in insertions. That is the strongest
    evidence yet that the deletion floor belongs to the REFERENCE — a linguist transcript carrying backchannels and
    disfluencies every ASR omits — rather than to any engine.

    Two process notes worth keeping. The upload dialog defaults to **Russian**; submitting that would have produced a
    meaningless transcript scored as if it meant something. And the first upload silently produced a transcript with
    no sentences because the account was over its free-tier storage cap — the record existed, the content never did.

    **Rejected on measurement: loudness normalisation.** Levels across the corpus range −26.3 to −21.1 LUFS, so
    normalising to −16 looked worth trying. Two of three fixtures got WORSE (0.3875 → 0.3968, 0.3630 → 0.3807); only
    CATS improved (0.5510 → 0.5340). No consistent gain.

    **Fixed: a notetaker listing meetings was detected as a meeting.** `CallDetector.scanWindows` matched any
    window's TITLE against the call-service fragments and never checked which app owned the window, so the Fireflies
    desktop app showing its meeting list — a row reading "… Zoom Meeting" — triggered a record prompt with no call in
    progress. A match now also requires an owner that can HOST a call (meeting client or browser); apps that LIST
    meetings are refused outright (Fireflies, Otter, Fathom, Granola, tl;dv, Read, Slack, Notion, calendar and mail).
    An unknown owner is refused rather than allowed: a false prompt interrupts focused work and teaches people to
    dismiss the app, while a missed offer costs one click and the acoustic and activation detectors still cover a
    real call.

    **Fixed: an intermittent ViewInspector failure.** `MCPAppsConnectionStateViewTests` failed roughly one full run
    in five with "Search did not find a match", and passed in isolation every time. Not a state race — the suite is
    already `.serialized` and touches no globals — but a 2-second `waitUntil` deadline that is ample on an idle
    machine and marginal when the whole suite loads every core. Raised to 10s; the loop exits the instant the
    condition holds, so it costs nothing when things are fast. Worth noting 8 of the 13 ViewInspector suites are not
    serialized, so the same shape can recur elsewhere.

    **The two working levers do NOT compound — they interfere, and the bigger model is the wrong choice for
    domain-heavy calls.** Glossary was measured on `small` and `large-v3` was measured without one; combined:

    | config | 14 CATS terms | 15 PCE terms | 15 WER |
    |---|---|---|---|
    | `small`, no glossary | 8/15 (0.53) | 4/7 (0.57) | 0.3875 |
    | **`small` + glossary** | **14/15 (0.93)** | **7/7 (1.00)** | 0.4246 |
    | `large-v3` + glossary | 12/15 (0.80) | 4/7 (0.57) | 0.4745 |

    On fixture 15 the glossary took `small` from 4/7 to a perfect 7/7, while `large-v3` stayed at 4/7 — exactly its
    score WITHOUT a glossary — and "PCE" came back corrupted again. Deletions rose too (D 291 against 217). The
    likely mechanism is that `large-v3` has stronger internal language priors and weights the decoder prompt far
    less than `small` does.

    Consequence for the recommendation, which is counterintuitive enough to be worth stating plainly: for a
    domain-heavy call with a good glossary, **`small` beats `large-v3`**. Reaching for the biggest model AND the
    glossary gets a worse result than the glossary alone on the smaller one. `large-v3` remains the better choice
    when there is no glossary to supply (mean 0.1912 against 0.2551 across the corpus).

    Caveat: two fixtures. The effect on 15 is large (7/7 against 4/7) and reproduces the no-glossary score exactly,
    which is what makes it credible rather than noise.

    **A single whole-file pass beats the live 6s pipeline on EVERY fixture, and the audio for it is already
    retained.** Post-call there is no latency constraint, so the recording can be decoded in one call instead of
    being handed 6-second slices:

    | | chunked 6s | whole-file, one pass |
    |---|---|---|
    | mean over 12 fixtures | 0.2541 | **0.1731** |
    | ICANN Indian × Chinese | 0.1962 | **0.0828** |
    | ISOC Zimbabwe | 0.4199 | **0.2632** |
    | Chinese × Chinese | 0.3452 | **0.2844** |
    | fixtures where chunking wins | — | **0** |

    32% better, on `small`, which also beats `large-v3`'s chunked mean of 0.1912 — and at 0.12–0.16x realtime, so a
    60-minute call re-transcribes locally in about 8 minutes with no upload and no credits.

    **Correction to what was recorded here earlier: this does NOT need an audio-retention decision.**
    `sessionRecorder.makeWAV()` already exists and the cloud diarize path already calls it, so the whole recording
    is in memory when the call ends. The privacy question was answered before this work started; nothing new is kept.

    That makes local post-call re-transcription the cheapest large win left: no vendor, no credits, no new retention,
    no upload, and it improves the archived transcript that Blind Spots, search and export all read. It does not
    replace the cloud pass — Fireflies/AssemblyAI/OpenAI still measure 0.14–0.18 against this 0.17 — but it is the
    only one of them that costs nothing and works offline.

    **The glossary does NOT transfer to the whole-file pass — measured after shipping it there by instinct.**
    In the live chunked path a glossary is the largest lever measured (term recall 0.53 to 0.93). In one pass over
    the whole recording it is a bad trade:

    | fixture | glossary | WER | recall | terms |
    |---|---|---|---|---|
    | 14 CATS | off | 0.4014 | 0.626 | 9/15 |
    | 14 CATS | on | 0.5289 | **0.488** | 14/15 |
    | 15 PCE | off | 0.3202 | 0.711 | 5/7 |
    | 15 PCE | on | 0.3480 | 0.684 | 6/7 |

    On CATS it bought 5 terms and cost 14 points of recall — output fell from 467 words to 372 against a 588-word
    reference. That is speech disappearing, and a fuller transcript is exactly what the post-call pass exists to
    produce. `retranscribeSessionLocally` therefore passes NO glossary; the live path keeps it.

    Plausible mechanism, and it matches the earlier `large-v3` result: a decoder prompt competes with a long,
    self-consistent context, and one pass over a whole recording has far more of that context than a six-second
    window. Two independent observations now point the same way — the glossary helps exactly when the model has
    little else to go on.

    Still to run: fast, tutorial, generic-video.
11. `videotest.sh` and `Tests/E2E/coverage-manifest.json` — exercise Local-to-Instant switching, rollback/drain, private attribution, cumulative echo, and scroll pinning.
12. `Tests/MeetGPTTests/SettingsDuringCallTests.swift` — verify live Settings changes preserve capture/session identity and restore the launch baseline.
13. `Tests/MeetGPTTests/PromoRedemptionReceiptTests.swift` and `videotest.sh` — exercise the Settings → AI → Manage promo path and retain receipt, screenshots, and sanitized network lifecycle.
14. `Tests/E2E/coverage-manifest.json` — complete the approved manual checks for spoken VoiceOver, Calendar delivery, Intel playback, and real vendor credentials.
15. `python3 testlib/verify_e2e_coverage.py` — **63.7% of 90%** via `verify-evidence.sh`. The remaining 26 points are entirely live artifacts: steps 8-14 must run first, and every one of them needs the installed app with Screen Recording and Microphone granted.
16. ~~Reviewable commits~~ — **done**. Split into contract (791aac6), implementation (7c8a31d), tests/harness (e4ebd49), evidence (865a3cb), and policy (3e09c60); pushed to `feat/assistant-actions-and-context`.
17. `Tests/E2E/TEST_PLAN.md` — keep `cruxwing-web` untouched throughout follow-up execution.

18. **Fireflies past-call import — DONE, including the entry point.**
    The picker landed as `FirefliesImportPicker` reached from the History
    header next to New call (aa8e5495): both answer "give me a different
    meeting to work on", one from this Mac and one from Fireflies. Picking a
    meeting imports it, saves it, opens it, and proposes a glossary from its
    vocabulary. Gated on a connected Fireflies and an idle session. View + gate
    + no-connection guards covered by `FirefliesImportPickerTests` (8 tests) on
    top of the core's 24.

    Original state for the record: core done (22d1d33, 055b89f), UI seam open. `FirefliesPastCalls` turns a past
    Fireflies meeting into an ordinary `SavedSession`, so Blind Spots, the assistant, prompt buttons and export work
    on it unchanged; a parallel read-only viewer would have meant reimplementing all of them against a second model.
    Speakers and timing are preserved, every line is attributed to the remote side, and an import sorts by when the
    meeting HAPPENED. Registered as `CONNECTED-FIREFLIES-PAST-CALL-IMPORT` with eight proofs; 24 tests.

    **Remaining: the entry point.** `MCPConnectionManager.firefliesRecentMeetings(limit:)` and
    `firefliesImportMeeting(_:goal:)` are what a picker calls. Deliberately not wired to a view yet — where the
    "Import from Fireflies" affordance belongs (History, Settings → Connected apps, or the new-call screen) is a
    product decision, and guessing it would put a feature somewhere it has to be moved from.

19. `python3 testlib/verify_e2e_coverage.py` — **63.8% of 90%**, 165 requirements all mapping. Unchanged conclusion:
    the remaining points are live artifacts behind steps 8-14, every one of which needs the installed app with Screen
    Recording and Microphone granted.

## 9. Backlog intake — 2026-08-08

Raw requests, written up as specifications. Nothing here is started. Each item states what the code does
**today** (checked, with the file that decides it), what is wanted, and what would count as done — because
several of these read like small toggles and are not: barge-in has no subsystem to attach to, and internet
search does not exist anywhere in the product.

Ordering is by dependency and cost, not by the order they were raised. Items 1-5 are self-contained; 6-13
need a design decision first; 14-16 are research that unblocks later work; 17-18 are a new subsystem.

1. **Pause, and a stop button that means stop — DONE.** (This entry predates the fix; verified against the
   code 2026-08-10.) The status enum carries `.paused`; `pauseRecording()` / `resumeRecording()` /
   `isPaused` / `isSessionLive` implement it, and every acceptance sub-criterion holds: capture, the
   blind-spot scheduler and the co-pilot hour meter all suspend (they gate on `isRecording`, false the
   instant status changes, plus an explicit `copilotActiveTimeMeter.transition(to: false)` so a paused call
   never bills an empty room, plus `stopBrainstorming()`); resume keeps the same session id, transcript and
   goal; `recordingElapsed.pause/resume` excludes the paused span so `activeRecordingSeconds` — what the
   clock shows AND what the meter bills — is the same number; and adding pause makes stop unambiguous (stop
   = finish-and-write-up, pause = suspend). A `pauseResume` analytics feature is emitted after the guard.
   *Originally:* one control, `RecordPill`, calling `state.toggleRecording()` over a five-case status
   (`idle · starting · recording · stopping · error`) — no paused state, so stop was the only exit and it
   ended the session. *Acceptance:* a `.paused` case with capture, blind-spot scanning and credit
   consumption all suspended; resume continues the same `SavedSession`; elapsed time excludes the paused
   span; stop from paused produces the same artefacts as stop from recording.
   (`Views/RecordingControls.swift`; `AppState.swift`)

2. **Bigger text — DONE.** Shipped as Settings → General → Appearance → "Reading text size"
   (`Config.readingTextScale`, applied to the transcript and assistant answer via
   `\.readingTextScale`; deliberately not the chrome, so controls cannot collide at the smallest
   window). This entry predates the fix; original text kept below for the record.
   *Originally:* Settings → General → Appearance offers Theme only (Auto/Light/Dark); grep finds
   no `fontSize`, `dynamicTypeSize` or text-scale setting anywhere in `Sources/MeetGPT`. Typography is fixed
   in `Typo`. *Wanted:* a text-size control in that same Appearance section, applied at least to the
   transcript and the assistant answer — the two surfaces people read for an hour. *Acceptance:* a scale
   setting that survives relaunch, changes transcript and answer text without clipping any layout at the
   smallest supported window size, and does not resize chrome so far that controls collide.
   (`Views/SettingsView.swift`; `DesignSystem/Theme.swift`)

3. **Individually configurable window — DONE.** `PaneLayout` + `PaneLayoutStore`
   (`Views/PaneLayout.swift`): independent show/hide for sidebar, transcript and assistant via the
   View menu (⌥⌘1-3), persisted across launches, assistant widens to fill when it is the only
   reading surface. The no-lockout rule is the design: toggling the last visible pane is a no-op,
   a persisted all-hidden layout corrects to all-visible on read, and the toggles live in the menu
   bar — a place no pane can hide. 9 tests enumerate every state × toggle. *Originally:* `ContentView`
   composes fixed-width columns (264 pt sidebar, 420 pt panel) with no visibility state and no persisted
   layout. *Wanted:* independent show/hide for the sidebar, the transcript column and the assistant panel,
   so the window can be a transcript-only reading pane, an assistant-only answer pane, or both.
   *Acceptance:* per-pane toggles with keyboard shortcuts, layout persisted across launches, and every pane
   reachable again once hidden — no state in which the toggle itself is the thing that got hidden.
   (`Views/ContentView.swift`)

4. **Google Drive picker — OBSOLETE as specified; superseded by the scope withdrawal.** The item
   assumed `drive.readonly` (browse and read any of the user's Drive). That scope was withdrawn to
   clear CASA (see the Google-verification work: the client now requests `drive.file` only). There is
   no "browse your Drive" surface left to build a picker against — `drive.file` reaches only files the
   app created or the user hands it through Google's own Picker. If document selection returns, it is
   a Google Picker flow on `drive.file`, a different design from this item. Recorded rather than
   silently dropped. *Original spec:* Drive is connected in
   Settings → Connected apps and grounding pulls snippets through `MCPGrounding`/`ConnectorProbeStrategy`,
   which decide relevance server-side; the user never names a file. Local folders already have the opposite
   model — an explicit picker with indexing, cancel, error and chip states (`Context/ContextFolder.swift`;
   `Views/ContextPanel.swift`). *Wanted:* the same explicit selection for connected storage — pick the docs,
   see them as chips, remove them. *Acceptance:* a Drive file picker that attaches named documents to the
   session context, shows them alongside folder chips, respects the existing bounded-excerpt retrieval
   rather than sending whole documents, and survives a reconnect without silently dropping the selection.

5. **Prompt buttons that follow the configuration — DONE.** `QuickPromptResolver`
   (`Models/QuickPromptResolver.swift`) is the single resolver the acceptance asked for: prompt
   requirements (connector keyword, compute spend, minimum tier) against the whole configuration,
   exclusions returned WITH their reason so tests assert why, bias toward showing. Wired in
   `QuickPromptsBar`; c24a9568 closed the gap the mute feature had opened — a muted app's keywords
   no longer offer its prompts, namespaced so a team connector cannot hide an MCP server of the
   same name. *Originally:* quick prompts already adapt to
   `RecordingContext` (meeting → decision prompts, lecture/tutorial → learning prompts), which is the
   precedent to extend. They do not respond to the rest of the app's state: plan and credit ceiling,
   connected apps, selected model, transcription engine, or the call's goal. *Wanted:* the visible button
   set derived from the whole configuration, so a prompt that cannot run is not offered and one that a
   connector makes newly useful is. *Acceptance:* a single resolver taking context + entitlement +
   connectors + goal and returning the button set, with tests that a disconnected CRM removes CRM-shaped
   prompts and an exhausted credit pool never offers a council. (`Models/RecordingContext.swift`;
   `Views/QuickPromptsView.swift`; `Tariff/TierPolicy.swift`)

6. **Filter sensitive data out of prompts — DONE, hardened this session.** `RedactingGateway`
   wraps every `LLMGateway` at construction (backend, direct Anthropic, orchestrator, ensemble), so
   there is no route to a provider that skips it; `OutboundRedactor` runs on the ASSEMBLED system +
   user text, not UI strings. Covers payment cards (Luhn-gated), API-key prefixes, US gov IDs,
   labelled credentials, a per-session user term list, and — added now — JWTs and PEM private-key
   blocks, the two paste-borne bearer credentials that were missing. On by default
   (`Config.outboundRedactionEnabled`); state and a live redaction count are legible in Settings →
   Account & privacy; findings surface for correction. 29 redactor tests + 10 gateway tests.
   *Original spec:* redaction exists only in logs and in narrow
   model-output sanitisers (`Log.swift`; `GoalSuggestion.sanitizeModelGoal`; `PromptWorkflows`), and the
   funnel endpoint rejects PII-shaped events server-side (`functions/funnel.js`). Nothing inspects the
   transcript, attached context or connector snippets before they are sent to a provider. *Wanted:* an
   outbound filter over everything leaving the machine for a model — card numbers, government IDs,
   credentials, API keys, and a user-managed term list. *Acceptance:* detection runs on the assembled
   request rather than on UI text; a redacted request is visibly marked, so the user knows what the model
   did not see; false positives are correctable per session; the filter is on by default and its state is
   legible in Settings → Account & privacy, beside the existing data-handling copy.

7. **Answer styles — DONE.** `AnswerStyle` (concise / explanatory / formal / standard) applied via
   `answerStyle.applied(to:)` at prompt ASSEMBLY, not as a post-hoc rewrite (AppState); the composer
   picker is in `BrainstormPanel` (`composer.answerStyle`); the choice persists for the session on the
   live `@Published` field; and the invariant is enforced and pinned — a style adjusts DELIVERY and
   NEVER the structural contract, so a DACI stays a DACI (`AnswerStyleTests`, and item 8's decision
   record rests on it). Verified this session; relaunch-persistence was tried and reverted as
   gold-plating — "persists per session" is met by the in-session field, and a global default read at
   AppState init raced parallel test suites for a papercut. *Original spec:* one voice. `CallTheme` and
   `PromptWorkflow` shape *what* is produced, not how it reads.

8. **Socratic mode.** *Done 2026-08-09.* The item said to settle first whether this is an answer style
   (item 7) or a separate mode. `AnswerStyle` answers it in its own doc comment: *a style adjusts DELIVERY
   and never the contract* — every style still answers. Socratic withholds the answer, so putting it there
   would break the invariant that makes styles safe to apply to fact checks and DACIs, where a Socratic
   variant is not a shorter answer but a broken one. It is a mode. The tell is that it needs three things no
   style needs: a bound, an escape hatch, and a control you cannot miss. Nobody needs an escape from
   "concise". A test pins the decision so it is not relitigated.

   *Bounded*, because an unbounded Socratic mode is indistinguishable from a broken assistant — you ask, you
   get a question, and nothing tells you whether it is thinking or failing. Three exchanges idle; **one while
   recording**, because withholding during a live call costs other people's time, not only the user's.
   Structured prompts are out of scope entirely.

   *Visible*: a chip in the composer row that names what the NEXT ask will do ("2 questions left"), not what
   the setting is called — a menu toggle is not "obviously modal" when you cannot see it without opening the
   menu. *Escapable*: ⌘⇧A, a real menu command rather than a key handler buried in the composer, since a
   shortcut nobody can find does not count as one keystroke. Breaking out answers the current ask plainly and
   keeps the mode on — making the escape also disable the feature would punish using it.

9. **Reflection after the call — not a summary.** *Done 2026-08-09.* `AI/Reflection/PostCallReflection.swift`
   plus `AppState.runPostCallReflection`. It reuses the live blind-spot provider, so the same judge and the
   same evidence requirement apply — this code decides only what SURVIVES the judge, and re-implements no
   part of judging.

   All three acceptance criteria hold and are tested. It never duplicates a summary bullet (via the existing
   `ReflectionDedup`, not a second definition of "the same claim"). Every point carries its transcript quote,
   and an un-evidenced suggestion is dropped rather than shown bare — a claim about a call with no quote
   cannot be checked. And a call with nothing worth saying produces **nothing**: the artefact is nil rather
   than empty, so the UI renders no section at all. An empty heading reads as a broken feature, and a
   reflection that always emits three points would pad — which is worse than silence here, because padding
   retroactively devalues the real observations.

   Two smaller decisions. It refuses while recording: half a meeting yields observations the room was about
   to address anyway, which is exactly the wrong-but-plausible output that teaches people to stop reading a
   feature. And it reads `transcriptText`, which automatically gets the better words when a local whole-file
   re-transcription has run — that pass replaces the remote side in place, so no special case is needed.

10. **Tool use from ordinary prompts, and from blind spots.** *Done 2026-08-09 for the ordinary-prompt half;
    blind spots still consume only what was already fetched.* All four acceptance criteria are met and
    tested: per-turn budget of 3 (refusals are free — a model asking for a write tool has not spent a
    lookup), every call attributed with its source and with "looked and found nothing" distinguished from
    "did not look", read/write classification delegated to the EXISTING `MCPImportToolPolicy` rather than a
    second classifier, and a latency ceiling of 4s live against 20s idle, checked *before* a call starts
    because cancelling costs the time anyway.

    Four pieces: `AgenticReadStep` (the bounds), `AgenticToolRequest` (the protocol),
    `AgenticReadExecutor` (resolve + run, injected caller so connector failures are testable), and
    `AgenticReadGateway` (the loop). The loop is a **decorator**, the same shape `RedactingGateway` uses —
    wrap once at construction and every caller is covered, and a retry loop stays out of `AppState.run`,
    which is the riskiest place in the app to put one.

    Two ordering decisions worth keeping. The loop sits **inside** the redactor: a tool result re-enters the
    conversation as user text, so it must be filtered on the way out like anything else — outside, the second
    round trip would carry an unredacted inbox or CRM record straight to the provider. And deltas are held
    until the first non-whitespace characters rule out the protocol marker, so a request line never reaches
    the user; the hold costs a few characters on the first token and nothing after.

    The protocol is text rather than provider-native tool calling: twelve models across seven providers with
    different tool schemas would be seven integrations and no capability at all on models without tools. It
    degrades to exactly today's behaviour when a model ignores it.

    *Wiring DONE (2026-08-10):* `AgenticReadContext.configure` is now called at startup
    (`MeetGPTApp.onAppear`) with a live executor built from the connected servers — so a prompt (and
    any future blind-spot caller) can resolve and run a read tool against real connectors instead of
    the inert nil the loop shipped with. The provider was made ASYNC to close a concurrency hole:
    the manager is `@MainActor`, the gateway calls the provider off-main, so the executor is built
    inside `await MainActor.run` and the tool list is snapshotted there as value-type `[Tool]` (read
    safely from any thread); the async Caller hops to the manager cleanly. Round-trip + per-request
    rebuild tested.

    *Measured gap (2026-08-10, parked) — the blind protocol rarely resolves.* `scripts/eval-tool-refusal.js`
    (api `921474a`) ran the real `AgenticToolRequest` protocol against the model with NO catalog: ~0% of
    tool attempts resolve to a connected server. The model has no way to know the server ids, so it names
    category words (`crm`, `email`, `bugs`) that `AgenticReadExecutor.server(named:)` refuses on its exact,
    deliberately-non-fuzzy match; and when handed server names it drops the required `/tool`, so the line
    fails `AgenticToolRequest.parse` and would LEAK to the user as the answer. Caveats: the eval used
    app-name-free prompts (a real transcript that says "HubSpot" lets the model copy the id, so production
    is likely better than this worst case), and it is the paid/connected path, not the anonymous floor.
    *Decision parked, not taken:* the three fixes — advertise connected server names, advertise a minimal
    server+read-tool catalog, or relax the parser to accept a server-only request (executor picks the
    default read tool) — all make tools fire MORE, i.e. spend tokens to make the feature work. That is a
    correctness/token tradeoff to weigh against the freemium "minimize cost" mandate, so it is recorded
    here rather than shipped. Re-run the harness after whichever fix is chosen.

    *Blind-spot half — SERVER done (2026-08-10, api `79c0c65`), design #2.* The right shape was not the
    ordinary-prompt agentic loop (that scan is a server call, not the app gateway): the API call is cheap,
    the agentic loop around it is not. So the scan now emits an OPTIONAL top-level `probeQuery` — a short
    connector search string, only when the transcript states a checkable fact — which piggybacks on the
    existing scan output for **zero extra model completions** (a full tool loop, ~2× completions, stays
    paid-lane). Affordable for every tier incl. free. Dormant until the app sends `canProbe:true`, so the
    prompt is byte-identical and the anonymous $0 floor is untouched. Quality measured
    (`docs/blindspot-probe-query.md`, api): a prominent wording regressed the scan −16.2% evidence / −0.50
    surviving/scan, so it ships at lowest salience where it measures no regression — the eval is why the
    wording is load-bearing. 9 new tests, brainstorm suite 55 pass.
    *App half — DONE (2026-08-10, `778d4219`).* `BrainstormService` sends `canProbe` (only when the grounded
    gate is open, so a user with no connectors never triggers it and the request stays byte-identical) and
    decodes the optional `probeQuery`. `AppState` holds the query the last scan asked for and spends the NEXT
    grounded cycle on it instead of the transcript heuristic — that cycle runs anyway, so it is the SAME
    connector call aimed better, not an extra one; **zero new completions AND zero new connector calls**.
    Consumed once, dropped if stale (a live call moves on). 5 new tests (wire decode + backward-compat when
    `probeQuery` is absent, the `SuggestionResult` default, request opts out by default); build clean, full
    BlindSpot suite 52 pass. Full loop is live: scan asks → app searches its own connectors → next scan sees
    the answer. The connector-query-beats-heuristic quality claim is the design intent, measurable only with
    connector fixtures (a follow-up eval, no offline harness exists for it yet).

11. **Internet search.** *Lane built and tested 2026-08-09; provider bound (Exa, api `d4d96e3`) and the
    APP CONTROL shipped 2026-08-10 — the last code half. **FULLY DONE, LIVE, OWNER-VERIFIED
    2026-08-10:** `EXA_API_KEY` set in prod, deploy run (~15:21 UTC boot at /health), and the owner
    exercised "Verify on the web" in-app and confirmed it verifies — the lane works end to end:
    app button → `searchWeb:true` → Exa → mechanical re-grounding → provenance-labelled verdicts with
    linked sources. Every acceptance rule held in production exactly as tested (never silent, always
    sourced, labelled apart). *Marketing copy is now UNBLOCKED* — the page may finally claim web
    fact-check (cruxwing-web repo, untouched pending the owner's go). One ops nit remains: the deploy
    does not export a commit var to the runtime, so /health still says `commit:"unknown"`; one
    `CRUXWING_GIT_COMMIT=$(git rev-parse HEAD)` line in the deploy step closes it.* `functions/webSearch.js`
    plus provenance in `functions/factcheck.js`.

    *App control (2026-08-10):* the never-silent rule as UI. One explicit button on the fact-check sheet —
    "Verify on the web" — is the ONLY path that sends `searchWeb:true`; the background cadence loop cannot.
    `FactCheckService.checkWithSearch` decodes the `search` block (ran/reason/sources/credits) and per-claim
    provenance; the sheet labels web verdicts apart (globe badge — "labelled apart" rule), links each
    web-checked claim's page, lists every source consulted, and surfaces "not configured on this server"
    instead of pretending a plain result was a web-checked one. `FactClaim` gains optional
    provenance/sourceUrl/sourceTitle (optional so pre-lane saved sessions still decode); a non-http(s)
    sourceUrl is dropped before it can reach a claim card as a clickable link. 7 new tests
    (`FactCheckWebLaneTests`): searchWeb-only-when-true wire body, search-block + legacy decode, the
    javascript:/data:/file: URL guard, and the persisted-session round-trip.

    Three rules, each an acceptance criterion. **Never silent:** search runs only when a caller explicitly
    asks, per request — a background lane querying the web every tick would turn "nothing leaves without you
    asking" into continuous egress of meeting content, with no visible symptom. **Always sourced:** a
    web-checked verdict must quote text that actually appeared in a retrieved result, mirroring the existing
    injection defence — and a fabricated web citation is *more* convincing than a fabricated local one,
    because the reader cannot check it against anything they already hold. **Labelled apart:** provenance
    (`attached` / `web` / `none`) travels with every claim, set explicitly rather than inferred, because
    collapsing them lets a web page inherit the trust of a document the user attached themselves.

    Also fail-closed on configuration (missing key reports why rather than returning empty results, which
    read as "the web says nothing"), and results are treated as untrusted input — `javascript:`, `data:` and
    `file:` URLs are rejected outright, snippets and counts capped.

    One rule worth keeping: only a claim that came back `needs_context` is re-checked against the web. A
    claim the user's own documents already settled must not be sent to a search engine for no gain.

    *Remaining (updated 2026-08-10):* the handler flag is DONE — `/api/factcheck` reads `body.searchWeb === true`
    (strict) and `generateClaims` gates the once-per-batch web pass on it. The integration is now tested too
    (`cruxwing-api/test/factcheckWebSearch.test.js`, a058b5b): never runs unless asked, searches only the
    `needs_context` claims so settled ones never leave the machine, and degrades to a plain check when the
    provider is unconfigured. **Provider adapter — DONE (2026-08-10, Exa, api `d4d96e3`).** The human chose
    Exa; `cruxwing-api/functions/exaSearch.js` is the binding (POST api.exa.ai/search, mapped to
    `{url,title,snippet}`, dormant without `EXA_API_KEY`), wired as `factcheck`'s default `fetchSearchResults`,
    `webSearch.isConfigured` activates on `EXA_API_KEY`. 8 unit tests + a LIVE smoke (a claim query returned 6
    real sources). So the API side is complete and verified. **Still remaining before it is USER-facing:** (1)
    the **app-side control** — the app must send `searchWeb:true` (a toggle/affordance), still an app build
    behind the in-flight local-transcription work; (2) `EXA_API_KEY` set in production. The marketing copy still
    must NOT move until the app can invoke it (until then "claims verified only against the context you attach"
    stays TRUE); it changes in the same commit that ships the app control — what the acceptance asked for.

12. **Token-maxxing mode — up to 1M tokens per request.** *Done 2026-08-09.* Opt-in per request, priced
    before the send. Eligibility is fail-closed on `contextTokens`, present in the catalogue only for models
    whose window is verified against provider docs — absent means NOT OFFERED, because guessing sells credits
    for a request the provider then rejects. Default ceilings do not move, so anyone who never opts in sees
    no change in cost or behaviour. A refused request says why; falling back silently would leave the user
    believing a two-hour call had been sent.

    The composer chip names the price and what gets sent, and when it is *off* it says "Transcript is being
    clipped" — the fact that makes turning it on a considered choice rather than a guess. It is hidden
    entirely for models that cannot do it, because an always-visible control that is usually disabled teaches
    people to stop reading the row. The flag is spent on send, so it cannot survive into a second request
    even if the user forgets it was on.

    Two things worth recording. Wiring it surfaced that the prompt envelope is bounded by
    `INCLUDED_PROMPT_TOKENS`, a *tariff* boundary — so rather than raise that constant (which would widen the
    envelope for every request, paid or not), the boundary now scales with the credits charged: envelope and
    price move together. And the rule is implemented twice, Swift and JS, because the price is shown before
    the send and charged after; `FullContextRequestTests` pins the app's catalogue and base rates against the
    server's rather than trusting they were written to match.

13. **Product analytics for in-app behaviour.** *Done 2026-08-09, except aggregation.* Event coverage
    now answers the three questions the item asked: which surfaces are reached (`surface_opened`), which
    prompts are run (`prompt_run`), and where sessions are abandoned (`session_ended`,
    `recording_abandoned`, plus `feature_used`/`feature_failed`). The full list is documented in
    `cruxwing-api/docs/analytics-events.md`.

    The payload guarantee moved from convention into the type. `FunnelTracker` used to take
    `[String: Any]`, so "no meeting content, goal text or connector data" rested on every future call site
    behaving; the server's defence was a PII-shaped-KEY filter, which says nothing about a key called `v`
    carrying a sentence, and it TRUNCATED long values to 64 characters — storing a fragment of the
    sentence rather than refusing it. Now `AnalyticsEvent` has no case that accepts free text, and the
    endpoint rejects any value that is not dimension-shaped (no whitespace, ≤40 chars, `[A-Za-z0-9_.-]`).
    Two traps found on the way: a custom prompt's id is a per-user UUID and its title is the user's own
    words, so user-defined prompts collapse to the constant `custom`; and the landing page was sending raw
    button copy as `cta_click.label`, which forked the metric whenever marketing reworded a button — now a
    slug.

    Emission was also unobservable (a detached POST whose result is ignored), so the analytics sink is now
    injected per `AppState`. That caught a real defect immediately: `pauseRecording` and
    `retranscribeLocallyNow` reported the feature BEFORE their guards, counting refused calls as uses.

    *Aggregation — DONE (2026-08-10, cruxwing-api).* Events now go to BOTH `logEvent` and the
    `funnel_events` table (`funnelRepository`, wired at auth/index.js so the write path fills the table
    without adding latency — the DB write is not awaited). The table is queried by `stageCounts`,
    `dimensionBreakdown` and `funnelConversion`, and those are reachable over HTTP as owner-only
    `GET /api/analytics/{stages,dimension,funnel}` (`functions/analyticsRoutes.js`, gated by
    `CRUXWING_ANALYTICS_TOKEN`, fail-closed to 404 when unset). 90-day retention via `purgeOlderThan`.
    So the acceptance criterion — a queryable `funnel_events` table — is met, and readable without a psql
    prompt. api commit `e0add06`; 20 route tests + `funnelRepository.test.js`.

14. **Fireflies integration parity sweep — DONE (2026-08-10).** Gap table in
    `docs/fireflies-integration-gap.md`, with MCP-availability per gap verified against the 2026
    vendor-hosted server list and a per-gap verdict. Two reframes shrink the list before it starts: video
    platforms are NOT gaps (Cruxwing captures the call directly via ScreenCaptureKit — it is already inside
    every meeting Fireflies needs a bot to join), and the automation tail is already covered by the Zapier
    connector. What remains is a short depth list: **Slack → Salesforce → Airtable → Monday/Dropbox** are all
    official-MCP drop-ins and the recommended order; **Microsoft 365** is the one bespoke bet, gated on
    enterprise being the target (no MCP shortcut); ATS/niche-CRM/dialers are skips for a general co-pilot.
    Demand is INFERRED — item 13's `funnel_events` is where the real signal will come from, and the ranking
    should be re-cut against it once connector-request telemetry exists. *Original sweep 2026-08-08:*
    `fireflies.ai/integrations` claims
    "100+ apps" across twelve categories: CRM (HubSpot, Salesforce, Redtail, Affinity, Wealthbox,
    Supersales) · Project management (Any.do, Microsoft To Do, Airtable, Linear) · ATS (BambooHR, Greenhouse,
    Lever) · Storage (OneDrive, Dropbox, Box, Google Drive) · Collaboration (SharePoint, Confluence,
    Workplace, Slack) · Dialers (OpenPhone, Zoom Phone, RingCentral, Aircall) · Videoconferencing (Meet,
    Teams, GoToMeeting, Webex, Dialpad, Lifesize) · Note-taking (OneNote, Google Docs, Notion) · Audio
    recording (Zoom) · Calendaring · Email · Custom (Skyvia, Latenode, MindStudio, Keragon). *Wanted:* a gap
    table against `MCP/MCPCatalog.swift`, sorted by how often each missing app is actually asked for.
    *Acceptance:* the table exists and records, per gap, whether an MCP server is available or a bespoke
    connector would be needed. **Explicitly not a goal:** matching the count — the landing-page argument is
    depth, and a long shallow tail is the competitor's game.

15. **Fireflies paid-tier UI and information-architecture walkthrough.** *Done 2026-08-09* —
    `docs/fireflies-walkthrough.md`, with screenshots in `docs/fireflies-walkthrough/`. Taken on a live
    trial account; every screenshot is of a public RIPE conference upload, so no customer call is exposed.

    The finding that matters is not a UI detail. `Voice Agents` is a top-level nav item, NEW, with voice
    cloning and seven prepared roles (screening interview, discovery call, performance review, user
    research…). **Fireflies is no longer competing to record meetings well; it is competing to not need you
    in them.** Read with their MCP surface — soundbites, channels, rule executions, revocable meeting access,
    usergroups — the strategy is a governed searchable archive of everything the company said, and now agents
    that generate the material too.

    Six "they do X, we do Y" observations are written up with a verdict on each. The four worth acting on:
    per-meeting prompt *recommendation* (we already resolve prompts from context — surfacing why is cheap);
    a refine control on an answer already on screen (distinct from item 7's styles, which we deliberately
    made a generation-time parameter); feedback capture on AI output, which we have none of and item 13's
    dimension-only events can now carry; and showing cost at the point of action, which item 12 concluded
    independently and their UI is evidence does not deter users.

    Explicitly rejected, with reasons: integration count (item 14 settles it), the archive itself (their
    market, their head start, and our privacy posture becomes a liability there), and Voice Agents
    (a product that attends meetings *instead of* the user is the opposite of a co-pilot).

16. **Claude desktop settings parity sweep — DONE (2026-08-10).** Inventory in `docs/claude-settings-parity.md`,
    Claude desktop's settings surface (web-sourced) vs Cruxwing's five tabs, verdict per item. Headline: the one
    setting worth ADOPTING is a **global hotkey** (start/stop recording + summon the assistant without leaving
    Zoom — the single gap a live-call user feels every session). Cheap ADAPTs: `⌘N` new call, `⌘K` search
    history, a shortcuts list. Rejected with reasons so they are not re-proposed: profiles (single-user tool), a
    `.mcpb` extension marketplace (depth-not-breadth connector strategy, item 14), voice-mode settings (post-MVP,
    items 18/22). Already had or exceeded: theme, model selection, privacy (outbound redaction is stronger than
    Claude's folder warning). *Original spec:* Settings has five tabs (General, Transcription, AI,
    Connected apps, Account & privacy) with roughly twenty sections. *Wanted:* an inventory of the Claude
    desktop settings surface with a decision per item: adopt, adapt, or reject with a reason. *Acceptance:*
    the inventory is checked in with the verdict recorded per item, so rejections do not get re-proposed
    cold — the discipline `docs/backlog.md` already applies to features.

17. **Blind-spot text notifications (no audio) — DONE.** A SILENT macOS banner when a new blind spot
    lands during a live call, for the user who is looking at Zoom rather than Cruxwing. `sound = nil`
    by design — the directive said text, not audio. `BlindSpotNotifier` splits the DECISION
    (`shouldNotify`: fresh item + recording + app backgrounded + enabled) from the side effect, so
    every rule is tested without a live call; the body leads with the sharpest single spot and a
    "+N more" count. On by default, toggle in Settings → General → During calls
    (`settings.general.blindSpotBanners`). 9 notifier tests. Two bugs found and fixed: the merge path
    reaches this in tests, and `UNUserNotificationCenter.current()` ABORTS outside an app bundle —
    guarded on `Bundle.main` being an `.app`, and the center resolved after the guard, never as a
    default argument (which evaluates at the call site before the guard runs).

**Barge-in for a spoken assistant.** *Prerequisite, and it is the whole story:* **there is no spoken
    assistant today.** Grep finds no TTS anywhere in `Sources/MeetGPT` — no `AVSpeechSynthesizer`, no
    playback path for model output; the audio stack is capture-only (`Audio/MicrophoneCapture.swift`;
    `Audio/AudioChunkBuffer.swift`), and the existing VAD serves chunking for transcription, not turn-taking.
    So this is not an improvement to a voice feature; it is the specification the voice feature must be built
    against, and it should be built barge-in-first rather than retrofitted.

    *Protocol.* `SPEAKING → USER_SPEECH_DETECTED → ABORT_TTS → ACK → LISTENING → NLU → SPEAKING`. Detect user
    speech with streaming VAD/endpointing; stop TTS immediately, including stream and buffer flush; emit a
    one-to-three-word acknowledgement ("yep", "sure", "go on") of at most 300 ms; collect the user's turn
    until 200-300 ms of silence; then answer, taking the interrupted phrase into account.

    *Behaviour rules.* No long concessions — one to three words, or silence. A yes/no interruption gets its
    answer immediately, with no preamble. An interruption during a list resumes with a two-word context tag
    ("On pricing: …"). Two consecutive interruptions shorten subsequent turns to one or two sentences.

    *Engineering constraints.* `tts.stop()` synchronous and instantaneous, with a resume token kept in case
    the utterance should be re-joined. Full-duplex audio, microphone taking priority over playback. Abort
    even when the utterance has under 250 ms left — a tail that finishes anyway is exactly what makes an
    assistant feel deaf. Log every barge-in with reaction latency and pre-answer pause.

    *Privacy.* No-trace by default on the live stream: no audio retained, only transient VAD features.

    *Acceptance.* Mean time from onset of user speech to `tts.stop()` ≤ 150 ms. Acknowledgement ≤ 300 ms and
    free of filler. False barge-in on background noise < 2% over ten minutes, via an adaptive threshold with
    anti-click. Acknowledgement rate-limited to once per two seconds as a VAD-flap fail-safe. Response length
    demonstrably shortens after two consecutive interruptions.

18. **Holding the conversation open through long pauses.** Companion to item 17 and meaningless without it:
    when the user goes quiet mid-thought, the assistant must neither talk over the pause nor treat it as the
    end of the turn. *Wanted:* a silence policy that distinguishes thinking from finishing. *Acceptance:*
    tiered silence thresholds rather than one timeout; nothing spoken during a short pause; at most one
    minimal re-engagement on a long one, never repeated; and an explicit "still there" state that resolves
    silently when speech resumes.

19. **Say why a prompt is being offered — DONE (tooltip surface).** `PromptReason.reason(promptID:
    recentTranscript:goal:)` is a pure, NO-MODEL, high-precision heuristic: it fires only on concrete
    regex-verifiable hooks in the recent transcript — a named weekday/month, "tomorrow"/"next week", a
    money figure, a percentage, the word "deadline" — and only for substance prompts (decision, risk,
    fact-check, summary, tasks, …). "You mentioned Friday", never a category; nil-biased, so a prompt
    with no specific hook is offered WITHOUT a reason. Surfaced in the chip tooltip + VoiceOver hint
    (`state.promptReason(for:)`), and it disappears once the prompt has run this call — a pure
    `aiHistory` read, no new state. 10 tests pin specific-or-silent, recency, word-boundary,
    non-substance-silent, never-category. *Deferred:* an always-visible panel like Fireflies' would be a
    chip-cloud redesign; the reason lives in the tooltip for now. *Original spec:* Their skill panel
    recommends per meeting — on a technical talk it surfaced a "Technical issue tracker" — so the
    recommendation reads the content. We already resolve prompts from context in `QuickPromptResolver`; what
    is missing is the reason. *Wanted:* the offered prompt carries a one-line justification tied to the call.
    *Acceptance:* the reason names something specific from THIS call, never a category ("you mentioned a
    vendor deadline", not "for planning meetings"); a prompt with no specific reason is offered without one
    rather than given a generic sentence; and the line disappears once the user has run that prompt on this
    call, because a justification for something you already chose is noise.

20. **Refine an answer on screen — DONE (Condense / Elaborate).** `AnswerRefine` (pure: kinds,
    reshape-not-reanswer prompts, contract guard) + `AppState.refineCurrentAnswer` / `revertRefine`.
    User-invoked ONLY (a wand menu in the assistant header), never automatic. The original stays
    recoverable: revert is offered while the refined text is still on screen and auto-invalidates when a
    new prompt replaces it (no run site has to clear it). Structured answers REFUSE — the guard hides
    the control for `logdecision` / `factcheck` / `agenda` / `tasks` / `commitments` / `dispute`, whose
    contract a free rewrite would break (item 7's discipline). The refine instruction forbids adding or
    dropping any fact, so it reshapes rather than re-answers. Cost is the visible credit rail's, and it
    is a normal-sized pass the user chose. 12 tests (contract guard, content-preservation, revert
    lifecycle). Free-text refine deferred. *Original spec:* Fireflies puts Condense / Elaborate /
    free-text refine directly above a delivered summary. We rejected a rewrite pass for answer STYLES (item
    7) and that decision stands — a second pass doubles cost on every answer and cannot be trusted to
    preserve a required structure. A user-invoked refine is a different trade: they asked, they pay, and they
    can see both versions. *Acceptance:* refine is only ever user-invoked, never automatic; the original
    answer stays reachable, so a refine that makes it worse is recoverable; structured answers (fact check,
    DACI, agenda) either keep their contract through the refine or refuse it, and refusing is acceptable;
    cost is shown before the second call, per item 12's rule.

21. **Capture whether AI output was useful — PARTLY DONE, and it forked from this spec. Needs a human call.**
    (Verified against the code 2026-08-10; this entry predates the implementation.) A per-answer feedback
    control exists: `AnswerFeedbackRow` (thumbs helpful/unhelpful + an optional bounded note) on archived
    answer exchanges, `AnswerFeedback` (`Models/AnswerFeedback.swift`) stored on `AIExchange.feedback` via
    `AppState.recordAnswerFeedback`, persisted in the session file and **sent nowhere**; `answerFeedbackSoFar`
    feeds the post-call reflection harness. Summaries are covered because a summary IS an answer (prompt id
    `summary`).

    **Three deliberate divergences from the acceptance below — the implementer chose a local private
    annotation over transmitted analytics, which is a real product decision to ratify, not a bug to "finish":**
    - The acceptance wanted a **dimension-only analytics event, queryable per artefact type in aggregate**.
      The shipped design sends nothing — it is the user's own note kept with the transcript — so it is more
      private but is NOT queryable in aggregate and cannot answer "which prompt is worth keeping" across users.
    - The acceptance **explicitly ruled out a comment box** (item 13's leak). The shipped design HAS an optional
      note. That is defensible precisely because it is sent nowhere — a note to yourself on your own machine is
      a different privacy question from a transmitted comment — but it is the opposite of what was written.
    - The acceptance wanted the control on **blind spots** too. It is not there (`BrainstormPanel` has no
      feedback affordance); and it is only on ARCHIVED answers, not the live one still on screen.

    A parallel dimension-only `AnalyticsEvent.artifactFeedback` path was prototyped 2026-08-10 and backed out:
    it duplicated `AnswerFeedbackRow`'s UI and reversed its deliberate "sent nowhere" choice, which is exactly
    the decision that needs a human, not a second silent implementation. **Open for a human:** (a) keep the
    local-private design and mark this done as-built, or add a dimension-only aggregate signal alongside the
    local note (rating + artefact type only, note stays local); and (b) extend feedback to blind spots and to
    the live answer. *Original acceptance:* item 13's event vocabulary carries it, payload dimension-only, no
    free text; control on blind spots, summaries and prompt answers, never blocks dismissal; aggregate
    queryable per artefact type.

22. **Voice agents — an agent that runs the call instead of attending it.** *POST-MVP. Tracked, not
    scheduled.* *From item 15, and recorded with the disagreement intact.* Fireflies ships this as a top-level NEW nav item: voice cloning plus seven
    prepared roles (screening interview, discovery call, progress check-in, user testimonial, performance
    review, user research, customer support). Each is a meeting a human currently attends.

    *The case against, which is what the walkthrough concluded:* a product that attends a meeting INSTEAD of
    the user is the opposite of a co-pilot that makes the user better in the room, and every differentiator
    built so far — live blind spots, in-call prompts, reflection on what the room avoided — assumes a human
    is present.

    *The case for:* the seven roles they chose are all one-to-one, repetitive, and scripted, which is exactly
    the set where nobody wants a human. It is also where the meeting is a data-collection exercise rather
    than a conversation, so "make the human better" has nothing to act on. Cruxwing's local-first stance is a
    real advantage in the sensitive half of that list — a performance review conducted by a cloud vendor's
    cloned voice is a harder sell than one that never leaves the machine.

    *Before any work:* decide which of those two readings the product accepts. Building this without settling
    it produces a feature that contradicts the positioning on the landing page. *If it proceeds:*
    consent is the first problem, not the last — every participant must know they are talking to an agent,
    and voice cloning makes that a legal question in several jurisdictions, not a UX one.

23. **Surface the annual offer — DONE.** App paywall already had the monthly/annual `interval` Picker
    (`PaywallView`); the landing showed only monthly with a prose footnote, which was the real gap. Added
    a monthly/annual toggle on the landing pricing cards (cruxwing-marketing) reading BOTH intervals from
    the same `/api/billing/plans` catalogue, saving stated in money/year ("Save $98 / user / year",
    derived not hardcoded), default monthly, comparison table's "monthly list price" label preserved.
    6 acceptance tests. Needs a landing redeploy to go live. *Original spec:* `TARIFF_PLANS` has
    `pro-annual`, `premium-annual` and `ultra-annual` at ten monthly payments, and the paywall model already
    decodes `interval` — but nothing offers them. The only mention anywhere is a prose footnote under the
    pricing cards: *"Annual billing costs 10 monthly payments."* A discount nobody sees converts nobody, and
    this reads as a missing feature when it is a missing control. *Acceptance:* a monthly/annual toggle on
    the landing pricing cards AND in the app paywall, both reading the same billing catalogue rather than
    hardcoding a second copy; the saving stated in money per year, not only as a percentage, because "$38 a
    year" is legible and "16.7%" is not; the toggle's default is monthly, so nobody is shown a price they
    cannot pay month to month; and the landing comparison table keeps its explicit "monthly list price"
    label, since comparing our annual to a competitor's monthly would be the dishonest version of this.

24. **Decide the annual discount depth deliberately.** *Business decision, recorded so it is made rather
    than defaulted.* Ours is 16.7% (ten monthly payments) across every tier. Fireflies is 44% on Pro and 34%
    on Business, with Enterprise annual-only. Ten payments is the conservative SaaS default; they have
    evidently priced churn reduction and working capital higher than we have. *What makes this NOT a
    straight copy:* their unlimited transcription costs them little at scale, while our tiers bundle copilot
    hours and compute credits with real unit cost (up to $0.0308 a credit), so a deeper discount spends
    margin rather than only shifting cash timing. *Acceptance:* whatever depth is chosen, the allowance
    tables are re-checked against it in the same change, and the reasoning is written down — a discount that
    quietly makes a tier unprofitable is discovered months later in the credit pools, not at the till.

ORGANIZE ULTIMATE TEST COVERAGE FOR ALL FEATURES
