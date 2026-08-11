# Whisper deployment roadmap — large-v3 on the VPS, serving every user

Goal: `POST /api/transcribe` returns best-quality transcripts from YOUR
infrastructure; signed-in app users get it by default (already wired in the
app + backend — this roadmap is the ops path only).

What already exists (code, done):
- Upstream service definition: `deploy/api/whisper-compose.yml` (speaches /
  faster-whisper, large-v3 int8, model preloaded, bound to 127.0.0.1:8971)
- Backend gateway: `functions/transcriptionGateway.js` → `/api/transcribe`
  (auth + per-user metering; env: `WHISPER_UPSTREAM_URL`, `WHISPER_MODEL`,
  optional `WHISPER_ALLOW_OPENAI_FALLBACK`)
- App: Cruxwing Whisper engine live; dist default for signed-in users;
  on-device fallback for signed-out.

Legend: **You** = server/console. **Me** = repo/verification. Total: ~2–4 h
active (+ model download wait), assuming the backend API is already deployed.

---

## Stage 0 — Gate: where are you relative to the backend? (5 min)

The gateway requires the backend (auth + Postgres metering). Pick your lane:

| Situation | Lane |
|---|---|
| Backend already live on `api.<domain>` | → Stage 1 |
| Backend NOT deployed yet, want quality NOW | → Bridge: set `WHISPER_ALLOW_OPENAI_FALLBACK=1` + `OPENAI_API_KEY` when you deploy the backend (zero extra infra; OpenAI `whisper-1` quality ≫ on-device base). Do Stages 2–7 later to move off OpenAI. |

## Stage 1 — Choose the box (decision, 10 min · You)

| Option | Cost feel | Realtime headroom | Verdict |
|---|---|---|---|
| **CPU VPS, ≥8 vCPU / 16 GB** | $40–80/mo | large-v3 int8 ≈ ~2 live chunk streams | MVP default |
| CPU VPS, 4 vCPU | $20–40/mo | large-v3 lags → use `distil-large-v3` (~6× faster, near-large quality) | acceptable compromise |
| GPU box (any NVIDIA ≥8 GB, e.g. RTX 4000/T4) | $150–300/mo | large-v3 × many streams | scale-up path |
| OpenAI bridge (no box) | per-minute API | n/a | stopgap only |

Disk: ≥10 GB free for the model volume (large-v3 CT2 ≈ 3 GB + cache).

- ✅ *Done when:* box chosen; SSH access works; it can reach the internet
  (model download from Hugging Face).

## Stage 2 — Provision the runtime (15 min · You)

```bash
# on the VPS
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER && newgrp docker
```
- ✅ `docker run --rm hello-world` prints its greeting.

## Stage 3 — Launch the upstream (10 min active + download wait · You)

```bash
# repo already on the server from the backend deploy
docker compose -f deploy/api/whisper-compose.yml up -d
docker compose -f deploy/api/whisper-compose.yml logs -f   # watch the model preload
```
First start downloads ~3 GB (one-time; persisted in the `whisper-models`
volume). GPU box: switch the image tag to `latest-cuda` and add the nvidia
runtime before this stage.
- ✅ Logs show the model loaded; `curl -s localhost:8971/health` (or `/v1/models`)
  answers; **the port is NOT reachable from outside** (`curl http://<vps-ip>:8971`
  from your Mac must fail — it's 127.0.0.1-bound by design).

## Stage 4 — Direct upstream smoke test (10 min · You + Me)

On your Mac, make a spoken test file and ship it up:
```bash
say -o /tmp/wt.aiff "The budget for project Falcon is forty thousand dollars."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/wt.aiff /tmp/wt.wav
scp /tmp/wt.wav <vps>:/tmp/
```
On the VPS:
```bash
curl -s http://127.0.0.1:8971/v1/audio/transcriptions \
  -F file=@/tmp/wt.wav -F model=large-v3 -F response_format=json
```
- ✅ JSON contains the sentence, correctly, in English. **Time it** (`time curl…`):
  a 5 s clip should transcribe well under 5 s. If it's slower → Stage 7 tuning
  now, not later.

## Stage 5 — Wire the gateway (10 min · You)

In `deploy/api/.env.production` (starter already carries the block):
```
WHISPER_UPSTREAM_URL=http://127.0.0.1:8971/v1/audio/transcriptions
WHISPER_MODEL=large-v3
# remove/comment WHISPER_ALLOW_OPENAI_FALLBACK once the upstream is live
```
```bash
sudo systemctl restart cruxwing-api
```
- ✅ Signed-in `POST https://api.<domain>/api/transcribe` with the same WAV
  returns the text (I'll give you the exact authed curl once the backend is
  up); unauthenticated returns 401 — never text.

## Stage 6 — App end-to-end (15 min · Me + You)

- Point a build at prod (`.env → BACKEND_URL=https://api.<domain>`), sign
  in, record with speakers while I run the scripted call:
  `SKIP_BUILD=1 bash livetest.sh` — marker recognition + language check
  now grade **server large-v3** instead of on-device.
- Settings → Transcription must show **Cruxwing Whisper** selected (default);
  signed-out relaunch must fall back to on-device silently.
- ✅ Live test green; transcript noticeably cleaner than the old on-device base
  (the RU-drift class of garbling should disappear).

## Stage 7 — Performance validation & tuning (20 min · You + Me)

Sustained reality check: one meeting = two 6 s chunk streams (mic + system).
- Measure: 10 consecutive 6 s chunks through `/api/transcribe`; p95 must be
  **< 6 s** (else the transcript falls behind live).
- If lagging, in order: `WHISPER__MODEL=Systran/faster-distil-whisper-large-v3`
  + `WHISPER_MODEL=distil-large-v3` (compose + env, restart both) → bigger CPU
  → GPU image. Each step is a 2-line change; the app needs nothing.
- ✅ p95 under budget at your expected concurrency (users × 2 streams).

## Stage 8 — Ops guardrails (15 min · You, once)

- Restart policy: compose already `restart: unless-stopped`; backend already
  systemd.
- Disk watch: the model volume is static (~3 GB) — put a 90% disk alert on the
  box (whatever monitor you use; even a cron `df -h` mail).
- Update path: `docker compose pull && docker compose up -d` (model persists).
- Rollback: comment `WHISPER_UPSTREAM_URL`, restart backend →
  gateway 503s with a clear message; set `WHISPER_ALLOW_OPENAI_FALLBACK=1` to
  bridge via OpenAI; app users can always switch to on-device in Settings.
- ✅ You know the two-line rollback and the two-line upgrade.

---
Order: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Stages 2–4 are independent of the
backend and can be done any time after the VPS exists. When you're at Stage 4,
ping me — I generate the test audio + verify each gate from here.
