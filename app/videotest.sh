#!/bin/bash
# Video-playback transcription + in-call prompt suite.
#
#   bash videotest.sh                 # build, then all conditions
#   SKIP_BUILD=1 bash videotest.sh    # app already installed
#   CONDITIONS="clean noisy" bash videotest.sh
#   MEDIA_CONDITIONS="tutorial" bash videotest.sh
#   MEDIA_CONDITIONS="" bash videotest.sh  # legacy meeting matrix only
#
# What it does, per condition:
#   1. renders a scripted two-speaker meeting to .mp4 with KNOWN ground truth
#   2. starts recording with the physical microphone on, plays remote voices
#      through built-in speakers (ffplay), and captures ScreenCaptureKit in
#      parallel — the local, deterministic topology of a Zoom call
#   3. injects prompts at UNPREDICTABLE timestamps mid-playback — the schedule
#      is derived from the run seed, not fixed, so a change that only works
#      when the prompt lands between utterances fails here
#   4. scores the captured transcript against ground truth: WER, speaker
#      accuracy, technical-term recall, duplication rate, first-line latency
#   5. scores each in-call answer for relevance against the material
#   6. records short tutorial + generic-video fixtures once per suite, changes
#      their manual recording type during playback without ending capture, and
#      grades WER/vocabulary; the tutorial runs one media-aware project prompt
#
# Meeting conditions: clean | noisy (pink noise) | fast (1.25x). Media
# conditions: tutorial | video. `offline` records deterministic injected-
# transport coverage as skipped in this live runner; it never disables the
# developer Mac's network. The generic video is deterministic instead of
# depending on YouTube availability, ads, account state, or copyrighted audio.
#
# Artifacts (one directory per run):
#   report.json      every metric, machine-readable
#   *.state.json      raw app state dumps
#   *.score.json      scorer output
#   *.duplex.json     mic/system liveness, RMS, output route, AEC state
#   *.responses.json  relevance / fulfillment / coherence per AI answer
#   screenshots/*.png  app-window evidence at launch, every prompt, and finish
#   events.jsonl     timestamped user actions + state/flow completion evidence
#   console.log      app console output for the window
#   network.log      privacy-safe backend HTTP/transcription lifecycle logs
#                    (no bodies, tokens, prompts, or transcript text)
#   dev-call-diagnostics/*.jsonl  explicitly armed dev-only prompt/workflow/
#                    response traces (owner-only, bounded, credential-redacted)
set -u
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Cruxwing.app"
LIB="$ROOT/testlib"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_STARTED_EPOCH="$(python3 -c 'import time;print(int(time.time()))')"
OUTDIR="${VIDEOTEST_OUT:-/tmp/cruxwing-videotest-$RUN_ID}"
case "$OUTDIR" in
    /*) ;;
    *) OUTDIR="$ROOT/$OUTDIR" ;;
esac
CONDITIONS="${CONDITIONS:-clean noisy fast}"
# Short single-speaker media recordings run once per suite, independently of
# the clean/noisy/fast meeting matrix. Set MEDIA_CONDITIONS="" to omit them
# while iterating on the legacy matrix, or choose "tutorial" / "video".
MEDIA_CONDITIONS="${MEDIA_CONDITIONS-tutorial video}"
SEED="${VIDEOTEST_SEED:-$RANDOM}"
RUN_NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
STATE_JSON="$OUTDIR/current.state.json"

# Quality bars. Deliberately loose for a synthesized voice over speakers with a
# real capture path — the point is catching REGRESSION, not certifying an
# absolute accuracy number. Tighten once a baseline exists.
MAX_WER_CLEAN="${MAX_WER_CLEAN:-0.35}"
MAX_WER_NOISY="${MAX_WER_NOISY:-0.55}"
MIN_TERM_RECALL="${MIN_TERM_RECALL:-0.5}"
MAX_DUPLICATION="${MAX_DUPLICATION:-0.10}"
MAX_CROSS_TRACK_ECHO="${MAX_CROSS_TRACK_ECHO:-0.05}"
MIN_SPEAKER_ACCURACY="${MIN_SPEAKER_ACCURACY:-0.6}"
MAX_TRANSCRIPT_LATENCY_P95="${MAX_TRANSCRIPT_LATENCY_P95:-20}"
MAX_WER_MEDIA="${MAX_WER_MEDIA:-0.45}"
MIN_MEDIA_TERM_RECALL="${MIN_MEDIA_TERM_RECALL:-0.5}"
MEDIA_TRANSCRIPT_TAIL_SECONDS="${MEDIA_TRANSCRIPT_TAIL_SECONDS:-10}"
MEDIA_AI_TIMEOUT="${MEDIA_AI_TIMEOUT:-75}"
MIN_RESPONSE_QUALITY="${MIN_RESPONSE_QUALITY:-0.45}"
MIN_RESPONSE_RELEVANCE="${MIN_RESPONSE_RELEVANCE:-0.20}"
MIN_RESPONSE_FULFILLMENT="${MIN_RESPONSE_FULFILLMENT:-0.35}"
MIN_RESPONSE_COHERENCE="${MIN_RESPONSE_COHERENCE:-0.55}"
MAX_AI_RESPONSE_LATENCY="${MAX_AI_RESPONSE_LATENCY:-120}"
AI_TIMEOUT="${AI_TIMEOUT:-90}"
BLIND_SPOT_TIMEOUT="${BLIND_SPOT_TIMEOUT:-75}"
BLIND_SPOT_MATERIAL_TIMEOUT="${BLIND_SPOT_MATERIAL_TIMEOUT:-30}"
INSTANT_CAPTION_TIMEOUT="${INSTANT_CAPTION_TIMEOUT:-30}"
REQUIRE_DIARIZATION="${REQUIRE_DIARIZATION:-0}"
EVENTS_JSONL="$OUTDIR/events.jsonl"
SYNTHETIC_EVIDENCE_JSONL="$OUTDIR/synthetic-evidence.jsonl"
NETWORK_LOG="$OUTDIR/network.log"
NETWORK_RAW_LOG="$OUTDIR/network.raw.json"
NETWORK_LOG_ERRORS="$OUTDIR/network-logger.stderr.log"
SCREENSHOT_DIR="$OUTDIR/screenshots"
LOG_PID=""
PLAY_PID=""
APP_PID=""
DUMP_SEQUENCE=0
RECORDING_ACTIVE=0
RECORDING_STOP_REQUESTED=0
RECORDING_START_UNCERTAIN=0
WORKER_PIDS=()
PROMPT_CAPTURE_LOCK="$OUTDIR/.prompt-capture.lock"

resolve_ffplay() {
    command -v ffplay 2>/dev/null && return 0
    local candidate
    for candidate in /opt/homebrew/bin/ffplay /usr/local/bin/ffplay; do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

FFPLAY="$(resolve_ffplay)" || {
    echo "!! ffplay is required for deterministic video/audio playback (install ffmpeg)"
    exit 2
}

if [ -e "$OUTDIR" ]; then
    [ -d "$OUTDIR" ] || { echo "!! artifact target exists and is not a directory: $OUTDIR"; exit 2; }
    if [ -n "$(find "$OUTDIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "!! refusing non-empty artifact directory (stale evidence risk): $OUTDIR"
        exit 2
    fi
else
    mkdir -m 700 "$OUTDIR"
fi
chmod 700 "$OUTDIR"
mkdir -m 700 "$SCREENSHOT_DIR"
PASS=(); FAIL=(); SKIP=()
EXECUTED_CONDITIONS=0
EXECUTED_MEDIA_CONDITIONS=0
EXECUTED_MEDIA_PROMPTS=0
note()  { printf '   %s\n' "$*"; }
check() { if [ "$2" = "0" ]; then PASS+=("$1"); printf '✅ %s — %s\n' "$1" "$3"
          else FAIL+=("$1"); printf '❌ %s — %s\n' "$1" "$3"; fi; }
skip()  { SKIP+=("$1"); printf '⏭️  %s — %s\n' "$1" "$2"; }

event() { # event <kind> <condition> <detail>
    python3 - "$EVENTS_JSONL" "$1" "$2" "${3:-}" <<'PY'
import json, sys, time
path, kind, condition, detail = sys.argv[1:5]
with open(path, "a") as handle:
    handle.write(json.dumps({
        "at": time.time(), "kind": kind,
        "condition": condition, "detail": detail,
    }, sort_keys=True) + "\n")
PY
}

record_synthetic_evidence() { # <condition> <checkpoint> <state-json>
    local condition="$1" checkpoint_name="$2" state_path="$3"
    python3 - "$OUTDIR" "$SYNTHETIC_EVIDENCE_JSONL" \
        "$condition" "$checkpoint_name" "$state_path" <<'PY'
import fcntl, json, os, stat, sys, time
root, destination, condition, checkpoint, state_path = sys.argv[1:]
root = os.path.realpath(root)
destination = os.path.abspath(destination)
state_path = os.path.abspath(state_path)
root_stat = os.stat(root)
if not stat.S_ISDIR(root_stat.st_mode):
    raise SystemExit("artifact root is not a directory")
if root_stat.st_uid != os.getuid() or stat.S_IMODE(root_stat.st_mode) & 0o077:
    raise SystemExit("artifact root is not owner-only")
if (os.path.realpath(os.path.dirname(destination)) != root
        or os.path.realpath(os.path.dirname(state_path)) != root):
    raise SystemExit("synthetic evidence escaped the artifact root")
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
blind_spot_fields = {
    key: value for key, value in state.items()
    if key.startswith("blindSpot")
}
row = {
    "at": time.time(),
    "condition": condition,
    "checkpoint": checkpoint,
    "dumpRequestID": state.get("dumpRequestID"),
    "callGoal": state.get("callGoal", ""),
    "effectiveCallGoal": state.get("effectiveCallGoal", ""),
    "transcriptFull": state.get("transcriptFull", []),
    "aiResponsePrompt": state.get("aiResponsePrompt", ""),
    "aiResponseFull": state.get("aiResponseFull", ""),
    "aiHistoryFull": state.get("aiHistoryFull", []),
    "aiExchangeEvidenceFull": state.get("aiExchangeEvidenceFull", []),
    "workflowStepsFull": state.get("workflowStepsFull", []),
    "suggestionsFull": state.get("suggestionsFull", []),
    "blindSpot": blind_spot_fields,
}
encoded = json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    handle.write(encoded)
    handle.flush()
    os.fsync(handle.fileno())
    fcntl.flock(handle, fcntl.LOCK_UN)
os.chmod(destination, 0o600)
PY
}

cleanup() {
    local worker cleanup_poll
    # macOS still ships Bash 3.2, where expanding an initialized-but-empty
    # array under `set -u` raises "unbound variable". The `-` default keeps
    # cleanup reliable even when startup fails before workers are armed.
    for worker in "${WORKER_PIDS[@]-}"; do
        [ -n "$worker" ] && kill "$worker" >/dev/null 2>&1 || true
    done
    for worker in "${WORKER_PIDS[@]-}"; do
        [ -n "$worker" ] && wait "$worker" 2>/dev/null || true
    done
    WORKER_PIDS=()
    rmdir "$PROMPT_CAPTURE_LOCK" >/dev/null 2>&1 || true
    [ -n "$LOG_PID" ] && kill "$LOG_PID" >/dev/null 2>&1 || true
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" >/dev/null 2>&1 || true
    if [ -n "$APP_PID" ]; then
        send ai.cruxwing.livetest.restoreSettings finishRun true >/dev/null 2>&1 || true
        send ai.cruxwing.livetest.closeSettings >/dev/null 2>&1 || true
    fi
    if [ "$RECORDING_ACTIVE" = "1" ] && [ "$RECORDING_STOP_REQUESTED" != "1" ] && [ -n "$APP_PID" ]; then
        send ai.cruxwing.livetest.toggleRecording >/dev/null 2>&1 || true
        RECORDING_STOP_REQUESTED=1
    fi
    if [ -n "$APP_PID" ]; then
        # Distributed notifications are asynchronous. Give restoreSettings
        # (including finishRun's process-local entitlement release) and the
        # recording stop request a short, bounded chance to run. A wedged main
        # thread cannot acknowledge either request, so cleanup then terminates
        # only the exact process launched above. Never use killall/pkill here:
        # an unrelated developer app must remain outside this harness's scope.
        for cleanup_poll in $(seq 1 8); do
            kill -0 "$APP_PID" >/dev/null 2>&1 || break
            sleep 0.25
        done
        if kill -0 "$APP_PID" >/dev/null 2>&1; then
            kill -TERM "$APP_PID" >/dev/null 2>&1 || true
            for cleanup_poll in $(seq 1 8); do
                kill -0 "$APP_PID" >/dev/null 2>&1 || break
                sleep 0.25
            done
        fi
        # SIGTERM normally closes the app. SIGKILL is the final fail-closed
        # guard for a process that remains stuck with an audio capture tap.
        if kill -0 "$APP_PID" >/dev/null 2>&1; then
            kill -KILL "$APP_PID" >/dev/null 2>&1 || true
        fi
        RECORDING_ACTIVE=0
        RECORDING_START_UNCERTAIN=0
    fi
    /bin/launchctl unsetenv CRUXWING_LIVETEST_NONCE >/dev/null 2>&1 || true
    /bin/launchctl unsetenv CRUXWING_LIVETEST_ARTIFACT_ROOT >/dev/null 2>&1 || true
    /bin/launchctl unsetenv CRUXWING_LIVETEST_STARTED_AT >/dev/null 2>&1 || true
    /bin/launchctl unsetenv CRUXWING_DEV_CALL_LOGS >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

play_video() { # play_video <absolute mp4 path> <player log path>
    local video_path="$1" player_log="$2"
    # A dedicated process gives the scheduler an exact lifecycle and never
    # closes or reuses the developer's own media-player documents. ffplay
    # still renders the MP4 and sends its audio through CoreAudio, so the app's
    # real ScreenCaptureKit path is exercised.
    "$FFPLAY" -autoexit -loglevel warning -window_title \
        "Cruxwing Video Test · $(basename "$video_path")" "$video_path" \
        >"$player_log" 2>&1 &
    PLAY_PID=$!
}

start_network_log() { # start_network_log <app pid>
    local app_pid="$1"
    # The app logs only method, path, status, duration, and byte counts. Bodies,
    # bearer tokens, transcript text, and provider credentials are deliberately
    # absent, so an artifact can be attached to a bug without leaking the call.
    # NDJSON stays valid when the stream is terminated. Logger diagnostics go
    # to a separate file instead of corrupting the machine-readable artifact.
    /usr/bin/log stream --style ndjson --level info --process "$app_pid" \
        --predicate 'subsystem == "ai.wheespr.meetgpt" && (category == "network" || category == "transcription")' \
        >"$NETWORK_RAW_LOG" 2>"$NETWORK_LOG_ERRORS" &
    LOG_PID=$!
    sleep 0.25
    kill -0 "$LOG_PID" >/dev/null 2>&1
}

send() {
    local name="$1"; shift
    # Pass values as argv, never by interpolating them into JavaScript source.
    # This keeps an artifact path or prompt containing quotes/backticks from
    # becoming executable code in the automation bridge.
    osascript -l JavaScript - "$name" nonce "$RUN_NONCE" "$@" >/dev/null <<'JXA'
function run(argv) {
    ObjC.import('Foundation')
    const info = $.NSMutableDictionary.alloc.init
    for (let index = 1; index + 1 < argv.length; index += 2) {
        info.setObjectForKey($(argv[index + 1]), $(argv[index]))
    }
    $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
            $(argv[0]), $(), info, true)
}
JXA
}

# Real macOS Accessibility actions for the one flow where UI mechanics are the
# bug surface. Values travel as argv (never source interpolation), and every
# lookup is by a stable SwiftUI AXIdentifier rather than coordinates or labels.
ax_element() { # ax_element <press|scroll|set|verify|enabled|exists> <identifier> [value]
    local action="$1" identifier="$2" value="${3:-}"
    osascript -l JavaScript - "$action" "$identifier" "$value" >/dev/null <<'JXA'
function run(argv) {
    const action = argv[0]
    const identifier = argv[1]
    const expectedValue = argv[2] || ""
    const systemEvents = Application("System Events")
    const process = systemEvents.processes.byName("Cruxwing")
    if (!process.exists()) throw new Error("Cruxwing accessibility process missing")
    process.frontmost = true

    const queue = process.windows().slice()
    let target = null
    let visited = 0
    while (queue.length > 0 && visited < 6000) {
        const element = queue.shift()
        visited += 1
        try {
            const attribute = element.attributes.byName("AXIdentifier")
            if (attribute.exists() && String(attribute.value()) === identifier) {
                target = element
                break
            }
        } catch (_) {}
        try {
            const children = element.uiElements()
            for (let index = 0; index < children.length; index += 1) {
                queue.push(children[index])
            }
        } catch (_) {}
    }
    if (target === null) throw new Error("AXIdentifier not found: " + identifier)

    if (action === "exists") return
    if (action === "press") {
        const press = target.actions.byName("AXPress")
        if (!press.exists()) throw new Error("AXPress unavailable: " + identifier)
        press.perform()
        return
    }
    if (action === "scroll") {
        const scroll = target.actions.byName("AXScrollToVisible")
        if (!scroll.exists()) throw new Error("AXScrollToVisible unavailable: " + identifier)
        scroll.perform()
        return
    }
    if (action === "set") {
        target.value = expectedValue
        return
    }
    if (action === "verify") {
        if (String(target.value()) !== expectedValue) {
            throw new Error("AXValue mismatch: " + identifier)
        }
        return
    }
    if (action === "enabled") {
        if (!target.enabled()) throw new Error("AX element disabled: " + identifier)
        return
    }
    throw new Error("unsupported accessibility action: " + action)
}
JXA
}

ax_wait() { # ax_wait <press|exists> <identifier> [attempts]
    local action="$1" identifier="$2" attempts="${3:-40}" attempt
    for attempt in $(seq 1 "$attempts"); do
        ax_element "$action" "$identifier" && return 0
        sleep 0.25
    done
    return 1
}

ax_scroll_to_bottom() {
    # The paywall is a real ScrollView sheet. Command-Down is an accessibility
    # visible user action and deliberately proves the bottom-only promo control
    # remains reachable without relying on window coordinates.
    osascript >/dev/null <<'APPLESCRIPT'
tell application "System Events"
    tell process "Cruxwing"
        set frontmost to true
        key code 125 using command down
    end tell
end tell
APPLESCRIPT
    # Also ask Accessibility to expose the bottom-only control itself. This is
    # still a real scroll action, and makes the result deterministic when focus
    # was retained by the preceding See plans button.
    ax_element scroll paywall.promo-code
}

stop_recording_if_active() {
    [ "$RECORDING_ACTIVE" = "1" ] || return 0
    if [ "$RECORDING_STOP_REQUESTED" != "1" ]; then
        send ai.cruxwing.livetest.toggleRecording >/dev/null 2>&1 || return 1
        RECORDING_STOP_REQUESTED=1
    fi

    # Stop awaits capture and transcriber teardown before the diagnostic writer
    # appends call_ended. Do not let the next condition race that asynchronous
    # work: newCall/toggle are intentionally ignored while AppState is stopping.
    local stop_poll_deadline
    stop_poll_deadline="$(python3 -c 'import time; print(time.time() + 15)')"
    while python3 -c \
        'import sys,time; raise SystemExit(0 if time.time() < float(sys.argv[1]) else 1)' \
        "$stop_poll_deadline" >/dev/null 2>&1
    do
        if dump 4 && python3 - "$STATE_JSON" "$OUTDIR" <<'PY' >/dev/null 2>&1
import json, os, sys
state_path, root = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
if state.get("isRecording") is not False or str(state.get("status", "")).lower() != "idle":
    raise SystemExit(1)
relative = state.get("devCallDiagnosticsRelativePath")
if not isinstance(relative, str) or not relative:
    raise SystemExit(1)
root = os.path.realpath(root)
path = os.path.realpath(os.path.join(root, relative))
if os.path.commonpath([root, path]) != root or not os.path.isfile(path):
    raise SystemExit(1)
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
raise SystemExit(0 if rows and rows[-1].get("event") == "call_ended" else 1)
PY
        then
            RECORDING_ACTIVE=0
            RECORDING_STOP_REQUESTED=0
            RECORDING_START_UNCERTAIN=0
            return 0
        fi
        sleep 0.25
    done
    event stop-timeout all "recording did not reach idle with correlated call_ended within 15s"
    return 1
}

start_recording_and_wait() {
    RECORDING_START_UNCERTAIN=1
    RECORDING_STOP_REQUESTED=0
    send ai.cruxwing.livetest.toggleRecording >/dev/null 2>&1 || return 1
    local start_poll_deadline
    start_poll_deadline="$(python3 -c 'import time; print(time.time() + 20)')"
    while python3 -c \
        'import sys,time; raise SystemExit(0 if time.time() < float(sys.argv[1]) else 1)' \
        "$start_poll_deadline" >/dev/null 2>&1
    do
        if dump 4; then
            if [ "$(jqv isRecording)" = "True" ]; then
                RECORDING_ACTIVE=1
            fi
            if python3 - "$STATE_JSON" "$OUTDIR" <<'PY' >/dev/null 2>&1
import json, os, sys
state_path, root = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
if state.get("isRecording") is not True or str(state.get("status", "")).lower() != "recording":
    raise SystemExit(1)
relative = state.get("devCallDiagnosticsRelativePath")
call_id = state.get("devCallDiagnosticsCallID")
if not isinstance(relative, str) or not relative or not isinstance(call_id, str) or not call_id:
    raise SystemExit(1)
root = os.path.realpath(root)
path = os.path.realpath(os.path.join(root, relative))
if os.path.commonpath([root, path]) != root or not os.path.isfile(path):
    raise SystemExit(1)
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
ok = (rows and rows[0].get("event") == "call_started"
      and rows[0].get("callID") == call_id)
raise SystemExit(0 if ok else 1)
PY
            then
                RECORDING_ACTIVE=1
                RECORDING_START_UNCERTAIN=0
                return 0
            fi
            case "$(jqv status)" in
                error*) RECORDING_START_UNCERTAIN=0; return 1 ;;
            esac
        fi
        sleep 0.25
    done
    event start-timeout all "recording did not reach correlated recording/call_started within 20s"
    return 1
}
dump_to() { # dump_to <unique destination> [max 250ms polls; default 60]
    local destination="$1" max_polls="${2:-60}"
    local request_id="$RUN_ID:$(basename "$destination")"
    rm -f "$destination"
    send ai.cruxwing.livetest.dumpState \
        path "$destination" requestID "$request_id"
    # The request id is the acknowledgement. A delayed older dump can write a
    # file, but it cannot be mistaken for this checkpoint.
    local attempt
    for attempt in $(seq 1 "$max_polls"); do
        if python3 - "$destination" "$request_id" <<'PY' >/dev/null 2>&1
import json, os, sys
path, expected = sys.argv[1:]
if not os.path.isfile(path) or os.path.getsize(path) == 0:
    raise SystemExit(1)
with open(path) as handle:
    state = json.load(handle)
raise SystemExit(0 if state.get("dumpRequestID") == expected else 1)
PY
        then
            return 0
        fi
        sleep 0.25
    done
    event dump-timeout all "request=$request_id destination=$destination"
    return 1
}

dump() { # dump [max 250ms acknowledgement polls]
    local max_polls="${1:-60}"
    DUMP_SEQUENCE=$((DUMP_SEQUENCE + 1))
    local destination="$OUTDIR/.dump-$DUMP_SEQUENCE.state.json"
    dump_to "$destination" "$max_polls" || return 1
    cp "$destination" "$STATE_JSON"
}
jqv() {
    [ -s "$STATE_JSON" ] || return 1
    python3 -c "import json;d=json.load(open('$STATE_JSON'));print(d.get('${1}'))"
}

snapshot() { # snapshot <condition> <name>
    local cond="$1" name="$2" destination
    destination="$OUTDIR/$cond.$name.state.json"
    dump_to "$destination" || return 1
    cp "$destination" "$STATE_JSON"
    local window
    window="$(python3 -c "import json;d=json.load(open('$STATE_JSON'));print(d.get('mainWindowNumber') or d.get('keyWindowNumber') or d.get('frontWindowNumber') or '')")"
    event state "$cond" "$name"
    [ -n "$window" ] && [ -x /usr/sbin/screencapture ] || return 1
    # Allow the render transaction following the state mutation to commit.
    sleep 0.15
    local attempt
    for attempt in 1 2 3 4; do
        /usr/sbin/screencapture -x -o -l "$window" \
            "$SCREENSHOT_DIR/$cond.$name.png" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}

checkpoint() { # checkpoint <condition> <name>
    local cond="$1" name="$2"
    snapshot "$cond" "$name"
    local rc=$?
    check "$cond $name screenshot" "$rc" \
        "$SCREENSHOT_DIR/$cond.$name.png plus state JSON"
    return "$rc"
}

state_matches() { # state_matches <state json> <predicate> [expected] [surface id]
    python3 - "$1" "$2" "${3:-}" "${4:-}" <<'PY' >/dev/null 2>&1
import json, sys
path, predicate, expected, surface_id = sys.argv[1:]
with open(path) as handle:
    state = json.load(handle)
if predicate == "poll":
    matched = (int(state.get("pendingClarificationCount") or 0) > 0
               and state.get("liveTestActivePollSurfaceID") == surface_id)
elif predicate == "mandatory":
    value = state.get("liveTestMandatoryNoticeMessage")
    matched = (isinstance(value, str) and bool(value.strip())
               and state.get("liveTestMandatoryNoticeID") == surface_id)
elif predicate == "prompt-equals":
    matched = state.get("aiResponsePrompt") == expected
elif predicate == "prompt-contains":
    matched = expected in str(state.get("aiResponsePrompt") or "")
else:
    matched = True
if surface_id:
    matched = matched and state.get("liveTestLastSurfaceID") == surface_id
raise SystemExit(0 if matched else 1)
PY
}

glossary_suggestion_action_capture() { # <condition> <action> <command id> <state json>
    local cond="$1" action="$2" command_id="$3" destination="$4" attempt
    send ai.cruxwing.livetest.glossarySuggestions \
        action "$action" commandID "$command_id"
    for attempt in $(seq 1 30); do
        if dump_to "$destination.attempt-$attempt" 4 && python3 - \
            "$destination.attempt-$attempt" "$action" "$command_id" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
action, command_id = sys.argv[2:]
ack = (state.get("liveTestGlossarySuggestionAction") == action
       and state.get("liveTestGlossarySuggestionCommandID") == command_id
       and float(state.get("liveTestGlossarySuggestionAppliedAt") or 0) > 0)
if action == "generate":
    ack = ack and state.get("connectedGlossarySuggestionStatus") == "ready"
raise SystemExit(0 if ack else 1)
PY
        then
            cp "$destination.attempt-$attempt" "$destination"
            event glossary-suggestion "$cond" "action=$action command=$command_id"
            return 0
        fi
        sleep 0.25
    done
    event glossary-suggestion-timeout "$cond" "action=$action command=$command_id"
    return 1
}

model_selection_during_call_capture() { # <condition>
    # Bash 3.2 expands every RHS in one `local` command before assigning any of
    # them. Keep this split under global `set -u` or `$cond` is unbound on macOS.
    local cond="$1"
    local prefix="$OUTDIR/$cond.settings.ai-model"
    local before="$prefix.before.state.json" started="$prefix.started.state.json"
    local after="$prefix.after.state.json" restored="$prefix.restored.state.json"
    local request="$prefix.request.json"
    local surface="$RUN_ID:$cond:settings-model-snapshot"
    local alternate attempt candidate exchange_id

    send ai.cruxwing.livetest.openSettings tab ai
    sleep 0.45
    dump_to "$before" || return 1
    alternate="$(python3 - "$before" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
current = d.get("configuredAIModelID")
print(next((model for model in d.get("availableAIModelIDs", [])
            if model != current), ""))
PY
)"
    [ -n "$alternate" ] || return 1

    # This fixed transcript-only prompt uses the ordinary run() path, which
    # snapshots the real gateway model synchronously. It deliberately has no
    # connected-app workflow, keeping this three-condition proof inexpensive.
    send ai.cruxwing.livetest.runPrompt id livetest-model-snapshot surfaceID "$surface"
    for attempt in $(seq 1 20); do
        candidate="$started.attempt-$attempt"
        if dump_to "$candidate" 4 && python3 - \
            "$candidate" "$surface" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
ok = (d.get("liveTestLastSurfaceID") == sys.argv[2]
      and d.get("aiResponsePromptID") == "livetest-model-snapshot"
      and isinstance(d.get("aiResponseID"), str)
      and bool(d.get("aiResponseID"))
      and d.get("aiResponseStatus") == "inProgress"
      and d.get("aiStreaming") is True
      and d.get("activeAnswerModelID") == d.get("configuredAIModelID"))
raise SystemExit(0 if ok else 1)
PY
        then
            cp "$candidate" "$started"
            break
        fi
        sleep 0.25
    done
    [ -s "$started" ] || return 1

    exchange_id="$(python3 - "$started" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("aiResponseID") or "")
PY
)"
    local result=1
    # The lifecycle label alone is insufficient: wait until this exact exchange
    # has emitted its content-bearing dev `assistant_request`. Its request body
    # records the immutable picker `selection` separately from the base `model`
    # passed into the request pipeline (for example, auto:anthropic vs auto).
    if [ -n "$exchange_id" ]; then
        for attempt in $(seq 1 100); do
            if python3 - "$started" "$OUTDIR" "$exchange_id" "$request" <<'PY' >/dev/null 2>&1
import json, os, sys
state_path, root, exchange_id, destination = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
relative = state.get("devCallDiagnosticsRelativePath")
if not isinstance(relative, str) or not relative:
    raise SystemExit(1)
root = os.path.realpath(root)
path = os.path.realpath(os.path.join(root, relative))
if os.path.commonpath([root, path]) != root or not os.path.isfile(path):
    raise SystemExit(1)
original = state.get("activeAnswerModelID")
if not isinstance(original, str) or not original:
    raise SystemExit(1)
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
row = next((row for row in rows
            if row.get("event") == "assistant_request"
            and row.get("fields", {}).get("exchangeID") == exchange_id
            and row.get("fields", {}).get("requestBody", {}).get("selection") == original), None)
if row is None:
    raise SystemExit(1)
request_body = row["fields"]["requestBody"]
request_model = request_body.get("model")
if not isinstance(request_model, str) or not request_model:
    raise SystemExit(1)
with open(destination, "w", encoding="utf-8") as handle:
    json.dump({
        "exchangeID": exchange_id,
        "configuredSelectionID": state.get("configuredAIModelID"),
        "activeSelectionID": original,
        "requestSelectionID": request_body["selection"],
        "requestModelID": request_model,
        "phase": row["fields"].get("phase"),
        "sequence": row.get("sequence"),
        "timestamp": row.get("timestamp"),
    }, handle, indent=2, sort_keys=True)
PY
            then
                break
            fi
            sleep 0.1
        done
    fi
    if [ -n "$exchange_id" ] && [ -s "$request" ]; then
        # The dev hook applies the whitelisted production setter and cancels the
        # exact active exchange in one main-actor transaction.
        send ai.cruxwing.livetest.cancelPrompt \
            exchangeID "$exchange_id" modelID "$alternate"
        for attempt in $(seq 1 20); do
            candidate="$after.attempt-$attempt"
            if dump_to "$candidate" 4 && python3 - \
                "$before" "$started" "$candidate" "$exchange_id" \
                "$surface" "$alternate" <<'PY' >/dev/null 2>&1
import json, sys
before, started, after = [json.load(open(path)) for path in sys.argv[1:4]]
exchange_id, surface, alternate = sys.argv[4:]
original = before.get("configuredAIModelID")
ok = (
    before.get("isRecording") is True and started.get("isRecording") is True
    and after.get("isRecording") is True
    and alternate in (before.get("availableAIModelIDs") or [])
    and started.get("aiResponseID") == exchange_id
    and started.get("aiResponsePromptID") == "livetest-model-snapshot"
    and started.get("aiResponseStatus") == "inProgress"
    and started.get("aiStreaming") is True
    and after.get("aiResponseID") == exchange_id
    and after.get("liveTestLastSurfaceID") == surface
    and after.get("aiResponsePromptID") == "livetest-model-snapshot"
    and after.get("aiResponseStatus") == "cancelled"
    and after.get("aiStreaming") is False
    and after.get("configuredAIModelID") == alternate
    and after.get("lastSettingMutationID") == "ai.model"
    and started.get("activeAnswerModelID") == original
    and after.get("activeAnswerModelID") == original
)
raise SystemExit(0 if ok else 1)
PY
            then
                cp "$candidate" "$after"
                result=0
                break
            fi
            sleep 0.1
        done
    elif [ -n "$exchange_id" ]; then
        # Keep a failed probe from colliding with later scheduled prompts.
        send ai.cruxwing.livetest.cancelPrompt exchangeID "$exchange_id"
    fi

    if [ "$result" = "0" ]; then
        capture_window_field "$after" settingsWindowNumber \
            "$SCREENSHOT_DIR/$cond.settings-ai-model-mutated.png" || result=1
    fi

    # Restore the launch model before any independently scheduled prompt is
    # armed. Re-enable the fixed glossary fixture: restore intentionally resets
    # every configured field, while the active recording keeps its snapshot.
    send ai.cruxwing.livetest.restoreSettings
    sleep 0.2
    send ai.cruxwing.livetest.applySetting id transcription.glossary-fixture value enabled
    send ai.cruxwing.livetest.closeSettings
    for attempt in $(seq 1 20); do
        candidate="$restored.attempt-$attempt"
        if dump_to "$candidate" 4 && python3 - \
            "$before" "$candidate" <<'PY' >/dev/null 2>&1
import json, sys
before, restored = [json.load(open(path)) for path in sys.argv[1:]]
ok = (
    restored.get("isRecording") is True
    and restored.get("configuredAIModelID") == before.get("configuredAIModelID")
    and restored.get("configuredGlossaryTermCount")
        == before.get("configuredGlossaryTermCount")
    and restored.get("activeGlossaryTermCount")
        == before.get("activeGlossaryTermCount")
    and restored.get("settingsWindowVisible") is False
    and int(restored.get("settingsWindowCount") or 0) == 0
    and restored.get("lastSettingMutationID") == "transcription.glossary-fixture"
)
raise SystemExit(0 if ok else 1)
PY
        then
            cp "$candidate" "$restored"
            break
        fi
        sleep 0.1
    done
    [ -s "$restored" ] || result=1
    event model-selection "$cond" "configured=$alternate active-snapshot-preserved=$result"
    return "$result"
}

acquire_prompt_capture_lock() {
    # Each worker keeps its independently seeded wake-up time, then serializes
    # only the correlated send -> dump -> screenshot -> dump transaction. The
    # app intentionally exposes one global last-surface acknowledgement, so two
    # workers must never overwrite it while either pixel capture is in flight.
    local attempt
    for attempt in $(seq 1 300); do
        if mkdir "$PROMPT_CAPTURE_LOCK" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    event prompt-capture-lock-timeout all "lock=$PROMPT_CAPTURE_LOCK"
    return 1
}

release_prompt_capture_lock() {
    rmdir "$PROMPT_CAPTURE_LOCK" >/dev/null 2>&1 || true
}

scheduled_prompt_capture() { # <condition> <index> <at> <kind> <value> <playback start>
    local cond="$1" prompt_index="$2" at="$3" kind="$4" value="$5"
    local playback_started="$6" name predicate expected surface_id
    surface_id="$RUN_ID:$cond:$prompt_index:$kind"
    case "$kind" in
        poll)       name="prompt-$prompt_index-poll"; predicate="poll"; expected="" ;;
        mandatory)  name="prompt-$prompt_index-mandatory"; predicate="mandatory"; expected="" ;;
        contextual) name="prompt-$prompt_index-contextual"; predicate="prompt-contains"; expected="Act as a sharp meeting coach." ;;
        freeform)   name="prompt-$prompt_index-freeform"; predicate="prompt-equals"; expected="$value" ;;
        quick)      name="prompt-$prompt_index-quick-$value"; predicate="prompt-contains"; expected="Summarize this meeting so far" ;;
        *) return 1 ;;
    esac

    local wait_for
    wait_for="$(python3 - "$playback_started" "$at" <<'PY'
import sys, time
print(max(0.0, float(sys.argv[1]) + float(sys.argv[2]) - time.time()))
PY
    )"
    sleep "$wait_for"
    acquire_prompt_capture_lock || return 1
    event prompt "$cond" "scheduled=$at type=$kind index=$prompt_index"
    case "$kind" in
        poll|mandatory|contextual)
            send ai.cruxwing.livetest.promptSurface \
                type "$kind" surfaceID "$surface_id"
            ;;
        freeform)
            send ai.cruxwing.livetest.ask \
                text "$value" surfaceID "$surface_id"
            ;;
        quick)
            send ai.cruxwing.livetest.runPrompt \
                id "$value" surfaceID "$surface_id"
            ;;
    esac

    # All timers are armed independently, but the short capture transaction is
    # isolated above. Each worker still requests a correlated state file after
    # injection, so delayed notifications cannot satisfy the wrong checkpoint.
    # A few short retries cover notification delivery ordering.
    local state="$OUTDIR/$cond.$name.state.json" attempt candidate matched=1
    for attempt in 1 2 3 4; do
        candidate="$state.attempt-$attempt"
        if dump_to "$candidate" && \
           state_matches "$candidate" "$predicate" "$expected" "$surface_id"; then
            cp "$candidate" "$state"
            matched=0
            break
        fi
        sleep 0.15
    done

    if [ "$matched" = "0" ]; then
        local window
        window="$(python3 - "$state" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    state = json.load(handle)
print(state.get("mainWindowNumber") or state.get("keyWindowNumber") or state.get("frontWindowNumber") or "")
PY
)"
        sleep 0.15
        if [ -n "$window" ] && /usr/sbin/screencapture -x -o -l "$window" \
            "$SCREENSHOT_DIR/$cond.$name.png" >/dev/null 2>&1; then
            # Prove the same identified surface remained active across the
            # pixel capture; overlapping schedulers cannot satisfy this with a
            # pre-capture JSON and a screenshot of a later prompt.
            local after="$state.after-screenshot"
            if dump_to "$after" && \
               state_matches "$after" "$predicate" "$expected" "$surface_id"; then
                event state "$cond" "$name surface=$surface_id"
                record_synthetic_evidence "$cond" "$name" "$state" || {
                    matched=1
                    event evidence-failed "$cond" "$name"
                }
            else
                rm -f "$SCREENSHOT_DIR/$cond.$name.png"
                matched=1
                event screenshot-state-race "$cond" "$name surface=$surface_id"
            fi
        else
            matched=1
            event screenshot-failed "$cond" "$name window=$window"
        fi
    else
        event state-mismatch "$cond" "$name predicate=$predicate"
    fi

    # Clear only the surface this worker created. With rapid schedules, a
    # delayed poll cleanup must not erase a later mandatory notice (or vice
    # versa).
    case "$kind" in
        poll|mandatory)
            send ai.cruxwing.livetest.clearPromptSurface \
                type "$kind" surfaceID "$surface_id"
            ;;
    esac
    release_prompt_capture_lock
    return "$matched"
}

capture_window_field() { # <state json> <window-number field> <png>
    local state="$1" field="$2" destination="$3" window
    window="$(python3 - "$state" "$field" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
PY
)"
    [ -n "$window" ] || return 1
    /usr/sbin/screencapture -x -o -l "$window" "$destination" >/dev/null 2>&1
}

settings_during_call_capture() { # <condition> <at> <playback-start> <pre-record-settings-state>
    local cond="$1" at="$2" playback_started="$3" baseline_path="$4"
    local wait_for
    wait_for="$(python3 - "$playback_started" "$at" <<'PY'
import sys, time
print(max(0.0, float(sys.argv[1]) + float(sys.argv[2]) - time.time()))
PY
)"
    sleep "$wait_for"
    event settings "$cond" "open-and-mutate scheduled=$at"

    local prefix="$OUTDIR/$cond.settings"
    local general_state="$prefix.general-open.state.json"
    local general_mutated_state="$prefix.general-mutated.state.json"
    local open_state="$prefix.ai-open.state.json"
    local live_state="$prefix.ai-live-mutated.state.json"
    local local_engine_state="$prefix.transcription-local-live.state.json"
    local instant_caption_state="$prefix.transcription-instant-caption.state.json"
    local deferred_state="$prefix.transcription-deferred.state.json"
    local glossary_generated_state="$prefix.connected-glossary-generated.state.json"
    local glossary_accepted_state="$prefix.connected-glossary-accepted.state.json"
    local glossary_rejected_state="$prefix.connected-glossary-rejected.state.json"
    local connected_state="$prefix.connected-apps-mutated.state.json"
    local privacy_state="$prefix.account-privacy-open.state.json"
    local privacy_mutated_state="$prefix.account-privacy-mutated.state.json"
    local restored_state="$prefix.restored.state.json"
    local closed_state="$prefix.closed.state.json"
    local result="$prefix.result.json"

    send ai.cruxwing.livetest.openSettings tab general
    sleep 0.65
    dump_to "$general_state" || return 1
    while IFS=: read -r setting value; do
        send ai.cruxwing.livetest.applySetting id "$setting" value "$value"
    done < <(python3 - "$general_state" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
appearance=d.get("configuredAppearance")
print(f"general.appearance:{'dark' if appearance != 'dark' else 'light'}")
current_role=d.get("configuredRoleID")
other_role=next((role for role in d.get("availableRoleIDs", []) if role != current_role), None)
if other_role: print(f"general.role:{other_role}")
print(f"general.ignore-media:{str(not bool(d.get('configuredIgnoreMedia'))).lower()}")
print(f"general.reminder-minutes:{1 if d.get('configuredReminderMinutes') != 1 else 30}")
print(f"general.reminders:{str(not bool(d.get('configuredMeetingReminders'))).lower()}")
print(f"general.call-detection:{str(not bool(d.get('configuredCallDetection'))).lower()}")
PY
)
    sleep 0.45
    dump_to "$general_mutated_state" || return 1
    capture_window_field "$general_mutated_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-general-mutated.png" || true

    send ai.cruxwing.livetest.openSettings tab ai
    sleep 0.8
    dump_to "$open_state" || return 1
    capture_window_field "$open_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-ai-open.png" || true

    # Flip every live watch from its actual baseline. Five back-to-back writes
    # exercise rapid Settings changes without waiting between switches.
    while IFS=: read -r setting value; do
        send ai.cruxwing.livetest.applySetting id "$setting" value "$value"
    done < <(python3 - "$open_state" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
for setting, field in [
    ("ai.brainstorm", "brainstormConfigured"),
    ("ai.agenda", "agendaConfigured"),
    ("ai.fact-check", "factCheckConfigured"),
    ("ai.rhetoric", "rhetoricConfigured"),
    ("ai.facilitation", "facilitationConfigured"),
]:
    print(f"{setting}:{str(not bool(d.get(field))).lower()}")
PY
)
    sleep 0.45
    dump_to "$live_state" || return 1
    capture_window_field "$live_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-ai-live-mutated.png" || true

    # Exercise the reported field regression through the same production setter
    # as Settings: regardless of the developer's launch preference, first move
    # the running call to Local, capture it, then select Instant and capture it.
    # The causal proof below requires a finalized caption explicitly tagged by
    # the Deepgram callback, then keeps Instant selected through the complete
    # pre-ready rollback deadline. A transient Settings row is not evidence.
    # A launch already on Instant still exercises both directions.
    send ai.cruxwing.livetest.applySetting id transcription.engine value local
    sleep 0.45
    dump_to "$local_engine_state" || return 1
    capture_window_field "$local_engine_state" mainWindowNumber \
        "$SCREENSHOT_DIR/$cond.transcription-local-before-instant.png" || true
    local instant_switch_requested_at instant_poll_deadline instant_ready=1 instant_candidate attempt
    local instant_viewport_stable=1 instant_checkpoint_count=0
    local instant_last_checkpoint_at=0 instant_last_render_signature=""
    instant_switch_requested_at="$(python3 -c 'import time;print(time.time())')"
    instant_poll_deadline="$(python3 - "$instant_switch_requested_at" "$INSTANT_CAPTION_TIMEOUT" <<'PY'
import sys
print(float(sys.argv[1]) + float(sys.argv[2]))
PY
)"
    send ai.cruxwing.livetest.applySetting id transcription.engine value deepgram
    attempt=0
    while python3 -c \
        'import sys,time; raise SystemExit(0 if time.time() < float(sys.argv[1]) else 1)' \
        "$instant_poll_deadline" >/dev/null 2>&1
    do
        attempt=$((attempt + 1))
        instant_candidate="$instant_caption_state.attempt-$attempt"
        # A single lost notification must not turn a nominal 30-second bound
        # into 15 seconds per iteration. Four acknowledgement polls cap each
        # candidate at roughly one second; the outer deadline is wall-clock.
        if dump_to "$instant_candidate" 4; then
            local instant_sample caption_count rendered_chars viewport_latest sample_at render_signature
            instant_sample="$(python3 - "$instant_candidate" "$instant_switch_requested_at" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
switched_at = float(sys.argv[2])
lines = [line for line in (state.get("transcriptFull") or [])
         if line.get("transcriptionEngine") == "deepgram"
         and line.get("source") == "system"
         and isinstance(line.get("at"), (int, float))
         and line["at"] >= switched_at]
print("\t".join([
    str(len(lines)), str(int(state.get("transcriptRenderedCharacters") or 0)),
    "true" if state.get("transcriptViewportAtLatest") is True else "false",
    str(float(state.get("dumpAppliedAt") or 0)),
]))
PY
)"
            IFS=$'\t' read -r caption_count rendered_chars viewport_latest sample_at <<<"$instant_sample"
            caption_count="${caption_count:-0}"
            rendered_chars="${rendered_chars:-0}"
            sample_at="${sample_at:-0}"
            if [ "$caption_count" -gt 0 ] 2>/dev/null; then
                [ "$viewport_latest" = "true" ] || instant_viewport_stable=0
                render_signature="$caption_count:$rendered_chars"
                if [ "$instant_checkpoint_count" -lt 3 ] && \
                   [ "$render_signature" != "$instant_last_render_signature" ] && \
                   python3 -c \
                    'import sys; raise SystemExit(0 if float(sys.argv[1])-float(sys.argv[2]) >= 2 else 1)' \
                    "$sample_at" "$instant_last_checkpoint_at" >/dev/null 2>&1; then
                    instant_checkpoint_count=$((instant_checkpoint_count + 1))
                    instant_last_checkpoint_at="$sample_at"
                    instant_last_render_signature="$render_signature"
                    cp "$instant_candidate" \
                        "$prefix.transcription-instant-growth-$instant_checkpoint_count.state.json"
                    capture_window_field "$instant_candidate" mainWindowNumber \
                        "$SCREENSHOT_DIR/$cond.transcription-instant-growth-$instant_checkpoint_count.png" || true
                fi
            fi

            if python3 - "$instant_candidate" "$instant_switch_requested_at" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
switched_at = float(sys.argv[2])
deadline = float(state.get("deepgramHandoffReadinessTimeoutSeconds") or 12)
lines = [line for line in (state.get("transcriptFull") or [])
         if line.get("transcriptionEngine") == "deepgram"
         and isinstance(line.get("at"), (int, float))
         and line["at"] >= switched_at]
system = [line for line in lines if line.get("source") == "system"]
labeled = [line for line in system if str(line.get("speaker") or "").strip()]
stable = float(state.get("dumpAppliedAt") or 0) >= switched_at + deadline + 0.5
ready = (
    state.get("activeTranscriptionEngine") == "deepgram"
    and state.get("pendingEngineChange") is None
    and stable
    and len(system) >= 1
    and len(labeled) >= 3
    and state.get("transcriptViewportAtLatest") is True
)
raise SystemExit(0 if ready else 1)
PY
            then
                if [ "$instant_viewport_stable" = "1" ] && \
                   [ "$instant_checkpoint_count" -ge 2 ]; then
                    cp "$instant_candidate" "$instant_caption_state"
                    instant_ready=0
                    break
                fi
            fi
        fi
        sleep 0.5
    done
    if [ "$instant_ready" != "0" ]; then
        [ -s "$instant_candidate" ] && cp "$instant_candidate" "$instant_caption_state"
        event instant-caption-timeout "$cond" \
            "wait=${INSTANT_CAPTION_TIMEOUT}s switch=$instant_switch_requested_at"
        return 1
    fi
    capture_window_field "$instant_caption_state" mainWindowNumber \
        "$SCREENSHOT_DIR/$cond.transcription-instant-final.png" || return 1
    event instant-caption "$cond" \
        "provider=deepgram stable-after-readiness-deadline switch=$instant_switch_requested_at viewport-checkpoints=$instant_checkpoint_count"

    # Exercise every other always-visible Transcription preference in one rapid
    # burst. Language/model/AEC/glossary remain immutable for the active call;
    # adaptive behavior and Fireflies enhancement are preferences for future or
    # post-call work. Pick values from the real state so every write is a change.
    while IFS=: read -r setting value; do
        send ai.cruxwing.livetest.applySetting id "$setting" value "$value"
    done < <(python3 - "$open_state" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
current_language=d.get("configuredTranscriptionLanguage")
print(f"transcription.language:{'en' if current_language != 'en' else 'ru'}")
current_model=d.get("configuredLocalModel")
print(f"transcription.local-model:{'base' if current_model != 'base' else 'small'}")
print(f"transcription.aec:{str(not bool(d.get('configuredMicrophoneNoiseSuppression'))).lower()}")
print(f"transcription.adaptive:{str(not bool(d.get('configuredAdaptiveLocal'))).lower()}")
print("transcription.glossary-fixture:disabled" if d.get("configuredGlossaryTermCount", 0)
      else "transcription.glossary-fixture:enabled")
print(f"transcription.fireflies-enhance:{str(not bool(d.get('configuredFirefliesEnhance'))).lower()}")
PY
)
    send ai.cruxwing.livetest.openSettings tab transcription
    sleep 0.55
    dump_to "$deferred_state" || return 1
    capture_window_field "$deferred_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-transcription-deferred.png" || true

    # Exercise the connected-app vocabulary proposal through its production
    # parser/review state while capture is live. The nonce-gated fixture is
    # fixed and network/tariff-free; it cannot turn a live test into connector
    # spend, and the semantic assertions below still enforce production prompt
    # bounds, zero transcript characters, and explicit accept/reject behavior.
    local glossary_command_prefix="$RUN_ID:$cond:connected-glossary"
    glossary_suggestion_action_capture "$cond" generate \
        "$glossary_command_prefix:generate" "$glossary_generated_state" || return 1
    capture_window_field "$glossary_generated_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-transcription-glossary-suggestions.png" || true
    glossary_suggestion_action_capture "$cond" acceptFirst \
        "$glossary_command_prefix:accept" "$glossary_accepted_state" || return 1
    glossary_suggestion_action_capture "$cond" rejectFirst \
        "$glossary_command_prefix:reject" "$glossary_rejected_state" || return 1

    # Connected-app grounding is a live prompt-composition preference. Toggle
    # it while capture is active, render its real Settings tab, and verify the
    # change does not perturb the immutable transcription snapshot.
    local next_connected_grounding
    next_connected_grounding="$(python3 - "$open_state" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(str(not bool(d.get("connectedAppsGroundingEnabled"))).lower())
PY
)"
    send ai.cruxwing.livetest.applySetting id connected-apps.grounding \
        value "$next_connected_grounding"
    send ai.cruxwing.livetest.openSettings tab connectedApps
    sleep 0.55
    dump_to "$connected_state" || return 1
    capture_window_field "$connected_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-connected-apps-mutated.png" || true

    # Account/Privacy contains destructive account actions that an unattended
    # test must never trigger. Exercise the reversible analytics preference and
    # prove the tab can be opened/closed without disturbing the call.
    send ai.cruxwing.livetest.openSettings tab accountPrivacy
    sleep 0.5
    dump_to "$privacy_state" || return 1
    local next_share_analytics
    next_share_analytics="$(python3 - "$privacy_state" <<'PY'
import json, sys
print(str(not bool(json.load(open(sys.argv[1])).get("configuredShareAnalytics"))).lower())
PY
)"
    send ai.cruxwing.livetest.applySetting id privacy.analytics value "$next_share_analytics"
    sleep 0.35
    dump_to "$privacy_mutated_state" || return 1
    capture_window_field "$privacy_mutated_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-account-privacy-mutated.png" || true

    # Restore through production setters before this condition ends. The suite
    # never leaves a developer's preferences or background spend gates changed.
    send ai.cruxwing.livetest.restoreSettings
    sleep 0.45
    dump_to "$restored_state" || return 1
    capture_window_field "$restored_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/$cond.settings-restored.png" || true
    send ai.cruxwing.livetest.closeSettings
    sleep 0.4
    dump_to "$closed_state" || return 1

    python3 - "$general_state" "$general_mutated_state" "$open_state" "$live_state" \
        "$local_engine_state" "$instant_caption_state" "$deferred_state" \
        "$glossary_generated_state" "$glossary_accepted_state" "$glossary_rejected_state" \
        "$connected_state" "$privacy_state" "$privacy_mutated_state" \
        "$restored_state" "$closed_state" "$baseline_path" "$SCREENSHOT_DIR" "$cond" \
        "$instant_switch_requested_at" "$instant_checkpoint_count" \
        "$instant_viewport_stable" "$result" <<'PY'
import json, os, sys
general_path, general_mutated_path, open_path, live_path, local_engine_path, instant_path, deferred_path, glossary_generated_path, glossary_accepted_path, glossary_rejected_path, connected_path, privacy_path, privacy_mutated_path, restored_path, closed_path, baseline_path, shots, cond, switch_at_raw, checkpoint_count_raw, viewport_stable_raw, out = sys.argv[1:]
general, general_mutated, opened, live, local_engine, instant, deferred, glossary_generated, glossary_accepted, glossary_rejected, connected, privacy, privacy_mutated, restored, closed = [json.load(open(p)) for p in
    [general_path, general_mutated_path, open_path, live_path, local_engine_path, instant_path, deferred_path,
     glossary_generated_path, glossary_accepted_path, glossary_rejected_path,
     connected_path, privacy_path, privacy_mutated_path, restored_path, closed_path]]
baseline = json.load(open(baseline_path))
watch_pairs = [
    ("brainstormConfigured", "brainstormTaskActive"),
    ("agendaConfigured", "agendaTaskActive"),
    ("factCheckConfigured", "factCheckTaskActive"),
    ("rhetoricConfigured", "rhetoricTaskActive"),
    ("facilitationConfigured", "facilitationTaskActive"),
]
screens = [
    f"{cond}.settings-general-mutated.png",
    f"{cond}.settings-ai-open.png",
    f"{cond}.settings-ai-live-mutated.png",
    f"{cond}.transcription-local-before-instant.png",
    f"{cond}.transcription-instant-growth-1.png",
    f"{cond}.transcription-instant-growth-2.png",
    f"{cond}.transcription-instant-final.png",
    f"{cond}.settings-transcription-deferred.png",
    f"{cond}.settings-transcription-glossary-suggestions.png",
    f"{cond}.settings-connected-apps-mutated.png",
    f"{cond}.settings-account-privacy-mutated.png",
    f"{cond}.settings-restored.png",
]
window_ok = (opened.get("settingsWindowVisible") is True
             and opened.get("settingsWindowCount") == 1
             and opened.get("selectedSettingsTab") == "ai"
             and all(os.path.getsize(os.path.join(shots, p)) > 0 for p in screens
                     if os.path.exists(os.path.join(shots, p)))
             and all(os.path.exists(os.path.join(shots, p)) for p in screens))
live_ok = all(
    bool(live.get(configured)) != bool(opened.get(configured))
    and bool(live.get(active)) == bool(live.get(configured))
    for configured, active in watch_pairs
)
general_ok = (
    general_mutated.get("selectedSettingsTab") == "general"
    and general_mutated.get("configuredAppearance") != general.get("configuredAppearance")
    and general_mutated.get("configuredRoleID") != general.get("configuredRoleID")
    and general_mutated.get("configuredCallDetection") != general.get("configuredCallDetection")
    and general_mutated.get("configuredIgnoreMedia") != general.get("configuredIgnoreMedia")
    and general_mutated.get("configuredMeetingReminders") != general.get("configuredMeetingReminders")
    and general_mutated.get("configuredReminderMinutes") != general.get("configuredReminderMinutes")
    and general_mutated.get("isRecording") is True
)
switch_at = float(switch_at_raw)
instant_deadline = float(instant.get("deepgramHandoffReadinessTimeoutSeconds") or 12)
instant_lines = [line for line in (instant.get("transcriptFull") or [])
                 if line.get("transcriptionEngine") == "deepgram"
                 and isinstance(line.get("at"), (int, float))
                 and line["at"] >= switch_at]
instant_system = [line for line in instant_lines if line.get("source") == "system"]
instant_labeled = [line for line in instant_system
                   if str(line.get("speaker") or "").strip()]
instant_causal_ok = (
    instant.get("activeTranscriptionEngine") == "deepgram"
    and instant.get("configuredTranscriptionEngine") == "deepgram"
    and instant.get("pendingEngineChange") is None
    and float(instant.get("dumpAppliedAt") or 0) >= switch_at + instant_deadline
    and len(instant_system) >= 1
    and instant.get("transcriptViewportAtLatest") is True
)
instant_diarization_ok = len(instant_labeled) >= 3
instant_viewport_ok = (
    viewport_stable_raw == "1"
    and int(checkpoint_count_raw) >= 2
    and instant.get("transcriptViewportAtLatest") is True
)
engine_live_ok = (
    "local" in local_engine.get("availableTranscriptionEngines", [])
    and "deepgram" in local_engine.get("availableTranscriptionEngines", [])
    and local_engine.get("configuredTranscriptionEngine") == "local"
    and local_engine.get("activeTranscriptionEngine") == "local"
    and local_engine.get("pendingEngineChange") is None
    and deferred.get("configuredTranscriptionEngine") == "deepgram"
    and deferred.get("activeTranscriptionEngine") == "deepgram"
    and deferred.get("pendingEngineChange") is None
    and instant_causal_ok
)
deferred_ok = (
    deferred.get("selectedSettingsTab") == "transcription"
    and deferred.get("activeTranscriptionLanguage") == opened.get("activeTranscriptionLanguage")
    and deferred.get("activeLocalModel") == opened.get("activeLocalModel")
    and deferred.get("activeMicrophoneNoiseSuppression")
        == opened.get("activeMicrophoneNoiseSuppression")
    and deferred.get("configuredMicrophoneNoiseSuppression")
        != deferred.get("activeMicrophoneNoiseSuppression")
)
transcription_matrix_ok = (
    engine_live_ok and deferred_ok
    and deferred.get("configuredTranscriptionLanguage")
        != opened.get("configuredTranscriptionLanguage")
    and deferred.get("configuredLocalModel") != opened.get("configuredLocalModel")
    and deferred.get("configuredAdaptiveLocal") != opened.get("configuredAdaptiveLocal")
    and deferred.get("configuredFirefliesEnhance") != opened.get("configuredFirefliesEnhance")
    and deferred.get("configuredGlossaryTermCount")
        != opened.get("configuredGlossaryTermCount")
    and deferred.get("activeGlossaryTermCount") == opened.get("activeGlossaryTermCount")
    and deferred.get("activeAssemblyDiarization") == opened.get("activeAssemblyDiarization")
)
generated_terms = glossary_generated.get("connectedGlossarySuggestionTerms") or []
glossary_suggestions_ok = (
    glossary_generated.get("isRecording") is True
    and glossary_generated.get("connectedGlossarySuggestionStatus") == "ready"
    and len(generated_terms) >= 2
    and 1 <= int(glossary_generated.get("connectedGlossarySuggestionSourceCount") or 0)
        <= 3
    and int(glossary_generated.get("connectedGlossarySuggestionGroundingChars") or 0)
        <= 4_800
    and int(glossary_generated.get("connectedGlossarySuggestionPromptChars") or 0)
        <= 6_000
    and int(glossary_generated.get("connectedGlossarySuggestionInputTokens") or 0)
        < 6_000
    and int(glossary_generated.get("connectedGlossarySuggestionTranscriptCharsSent", -1))
        == 0
    and bool(glossary_generated.get("connectedGlossarySuggestionModelID"))
    and int(glossary_generated.get("connectedGlossarySuggestionEstimatedCredits") or 0) > 0
    and glossary_generated.get("connectedGlossarySuggestionRanking") == "localOnly"
    and glossary_generated.get("connectedGlossarySuggestionCached") is False
    and glossary_accepted.get("liveTestGlossarySuggestionAction") == "acceptFirst"
    and int(glossary_accepted.get("connectedGlossarySuggestionAcceptedCount") or 0) == 1
    and int(glossary_accepted.get("configuredGlossaryTermCount") or 0)
        == int(deferred.get("configuredGlossaryTermCount") or 0) + 1
    and glossary_accepted.get("activeGlossaryTermCount")
        == deferred.get("activeGlossaryTermCount")
    and glossary_rejected.get("liveTestGlossarySuggestionAction") == "rejectFirst"
    and int(glossary_rejected.get("connectedGlossarySuggestionRejectedCount") or 0) == 1
    and glossary_rejected.get("configuredGlossaryTermCount")
        == glossary_accepted.get("configuredGlossaryTermCount")
    and glossary_rejected.get("activeGlossaryTermCount")
        == deferred.get("activeGlossaryTermCount")
    and glossary_rejected.get("isRecording") is True
)
connected_ok = (
    connected.get("selectedSettingsTab") == "connectedApps"
    and connected.get("lastSettingMutationID") == "connected-apps.grounding"
    and bool(connected.get("connectedAppsGroundingEnabled"))
        != bool(opened.get("connectedAppsGroundingEnabled"))
    and connected.get("activeTranscriptionEngine")
        == deferred.get("activeTranscriptionEngine")
    and connected.get("activeMicrophoneNoiseSuppression")
        == opened.get("activeMicrophoneNoiseSuppression")
    and connected.get("isRecording") is True
)
privacy_ok = (
    privacy_mutated.get("selectedSettingsTab") == "accountPrivacy"
    and privacy_mutated.get("configuredShareAnalytics")
        != privacy.get("configuredShareAnalytics")
    and privacy_mutated.get("isRecording") is True
)
restored_ok = (
    restored.get("lastSettingMutationID") == "restore"
    and all(bool(restored.get(c)) == bool(opened.get(c)) for c, _ in watch_pairs)
    and all(bool(restored.get(a)) == bool(restored.get(c)) for c, a in watch_pairs)
    and restored.get("configuredTranscriptionEngine")
        == opened.get("configuredTranscriptionEngine")
    and restored.get("activeTranscriptionEngine")
        == opened.get("activeTranscriptionEngine")
    and restored.get("configuredTranscriptionLanguage")
        == opened.get("configuredTranscriptionLanguage")
    and restored.get("configuredLocalModel") == opened.get("configuredLocalModel")
    and restored.get("configuredMicrophoneNoiseSuppression")
        == opened.get("configuredMicrophoneNoiseSuppression")
    and restored.get("configuredAdaptiveLocal") == opened.get("configuredAdaptiveLocal")
    and restored.get("configuredGlossaryTermCount")
        == baseline.get("configuredGlossaryTermCount")
    and restored.get("configuredFirefliesEnhance")
        == opened.get("configuredFirefliesEnhance")
    and restored.get("pendingEngineChange") is None
    and restored.get("connectedAppsGroundingEnabled")
        == opened.get("connectedAppsGroundingEnabled")
    and restored.get("configuredAppearance") == general.get("configuredAppearance")
    and restored.get("configuredRoleID") == general.get("configuredRoleID")
    and restored.get("configuredCallDetection") == general.get("configuredCallDetection")
    and restored.get("configuredIgnoreMedia") == general.get("configuredIgnoreMedia")
    and restored.get("configuredMeetingReminders") == general.get("configuredMeetingReminders")
    and restored.get("configuredReminderMinutes") == general.get("configuredReminderMinutes")
    and restored.get("configuredShareAnalytics") == privacy.get("configuredShareAnalytics")
    and restored.get("configuredAIModelID") == opened.get("configuredAIModelID")
)
continuity_ok = all(d.get("isRecording") is True for d in
                    [general, general_mutated, opened, live, deferred, connected,
                     privacy, privacy_mutated, restored, closed])
continuity_ok = continuity_ok and all(
    float(closed.get(field) or 0) > float(opened.get(field) or 0)
    for field in ["micCaptureBufferCount", "systemCaptureBufferCount",
                  "micCaptureLastBufferAt", "systemCaptureLastBufferAt"])
close_ok = closed.get("settingsWindowVisible") is False
report = {
    "window": window_ok,
    "generalSettingsDuringCall": general_ok,
    "liveWatchReconciliation": live_ok,
    "liveTranscriptionEngineSwitch": engine_live_ok,
    "instantCaptionCausality": instant_causal_ok,
    "instantDiarizationEvidence": instant_diarization_ok,
    "instantViewportPinned": instant_viewport_ok,
    "instantViewportCheckpointCount": int(checkpoint_count_raw),
    "instantSwitchAt": switch_at,
    "instantCaptionCount": len(instant_system),
    "instantSpeakerLabeledCaptionCount": len(instant_labeled),
    "deferredTranscriptionIsolation": deferred_ok,
    "fullTranscriptionControlMatrix": transcription_matrix_ok,
    "connectedGlossarySuggestionsDuringCall": glossary_suggestions_ok,
    "connectedAppsGroundingDuringCall": connected_ok,
    "accountPrivacySettingsDuringCall": privacy_ok,
    "restoration": restored_ok,
    "captureContinuity": continuity_ok,
    "closedWithoutStoppingCall": close_ok and closed.get("isRecording") is True,
}
report["passed"] = all(report.values())
json.dump(report, open(out, "w"), indent=2, sort_keys=True)
raise SystemExit(0 if report["passed"] else 1)
PY
}

# ── entitlement ─────────────────────────────────────────────────────────────
# One-shot Blind Spot live evidence.
blind_spot_capture() { # <condition> <artifact-base>
    local cond="$1" base="$2"
    local material_state="$OUTDIR/$cond.blind-spot-material.state.json"
    local material_poll="$OUTDIR/$cond.blind-spot-material-poll.state.json"
    local material_ready=1 attempt

    # Use only finalized material produced by the synthetic video. The hook
    # applies the same three-line / 240-character eligibility check again.
    for attempt in $(seq 1 "$BLIND_SPOT_MATERIAL_TIMEOUT"); do
        if dump_to "$material_poll" && python3 - "$material_poll" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
material = [str(line.get("text") or "").strip()
            for line in state.get("transcriptFull", [])]
material = [line for line in material if line]
characters = sum(character.isalnum() for character in " ".join(material))
raise SystemExit(0 if state.get("isRecording") is True
                 and len(material) >= 3 and characters >= 240 else 1)
PY
        then
            cp "$material_poll" "$material_state"
            material_ready=0
            break
        fi
        sleep 1
    done
    check "$cond Blind Spot transcript eligibility" "$material_ready" \
        "three finalized synthetic lines and >=240 material characters"
    [ "$material_ready" = "0" ] || return 1

    # The developer may normally keep Blind Spot off. Use the production
    # Settings setter and restore the launch-time preference before returning.
    send ai.cruxwing.livetest.applySetting id ai.brainstorm value true
    sleep 0.35
    local baseline="$OUTDIR/$cond.blind-spot-baseline.state.json"
    dump_to "$baseline" || {
        check "$cond Blind Spot baseline" 1 "state dump failed"
        send ai.cruxwing.livetest.restoreSettings
        return 1
    }
    python3 - "$baseline" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("brainstormConfigured") is True
                 and d.get("brainstormTaskActive") is True else 1)
PY
    local task_active=$?
    check "$cond Blind Spot task active" "$task_active" \
        "production Settings setter reconciled the in-call task"
    if [ "$task_active" != "0" ]; then
        send ai.cruxwing.livetest.restoreSettings
        return 1
    fi

    local goal_command="$RUN_ID:$cond:blind-spot-goal"
    local refresh_command="$RUN_ID:$cond:blind-spot-refresh"
    send ai.cruxwing.livetest.setSyntheticCallGoal \
        fixtureID project-falcon commandID "$goal_command"
    # Keep the explicit refresh inside callGoal's debounce: it replaces that
    # pending wake, so this remains one bounded scan rather than a second scan.
    sleep 0.1
    send ai.cruxwing.livetest.refreshBlindSpot \
        fixtureID project-falcon commandID "$refresh_command"

    local command_state="$OUTDIR/$cond.blind-spot-command.state.json"
    local commands_applied=1
    for attempt in $(seq 1 12); do
        if dump_to "$command_state" && python3 - "$command_state" \
            "$goal_command" "$refresh_command" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
goal_command, refresh_command = sys.argv[2:]
expected_goal = ("Identify the highest-impact missing decision, risk, or unsupported "
                 "assumption in the Project Falcon rollout, then give one concrete next question.")
ok = (
    state.get("callGoal") == expected_goal
    and state.get("effectiveCallGoal") == expected_goal
    and state.get("liveTestSyntheticGoalCommandID") == goal_command
    and state.get("liveTestBlindSpotRefreshCommandID") == refresh_command
    and isinstance(state.get("liveTestSyntheticGoalAppliedAt"), (int, float))
    and isinstance(state.get("liveTestBlindSpotRefreshRequestedAt"), (int, float))
)
raise SystemExit(0 if ok else 1)
PY
        then
            commands_applied=0
            break
        fi
        sleep 0.15
    done
    check "$cond Blind Spot synthetic prompt acknowledged" "$commands_applied" \
        "fixed fixture goal plus one correlated refresh command"
    if [ "$commands_applied" != "0" ]; then
        send ai.cruxwing.livetest.restoreSettings
        return 1
    fi
    local baseline_attempts
    baseline_attempts="$(python3 -c "import json;print(json.load(open('$baseline')).get('blindSpotAttempts',0))")"
    event blind-spot "$cond" \
        "refresh-command=$refresh_command baseline-attempts=$baseline_attempts"
    checkpoint "$cond" blind-spot-triggered || true
    record_synthetic_evidence "$cond" blind-spot-triggered \
        "$OUTDIR/$cond.blind-spot-triggered.state.json" || \
        check "$cond Blind Spot trigger evidence" 1 "owner-only JSONL append failed"

    local terminal_poll="$OUTDIR/$cond.blind-spot-terminal-poll.state.json"
    local terminal_ready=1
    for attempt in $(seq 1 "$BLIND_SPOT_TIMEOUT"); do
        if dump_to "$terminal_poll" && python3 - "$baseline" "$terminal_poll" \
            "$refresh_command" <<'PY' >/dev/null 2>&1
import json, sys
before, after = [json.load(open(path)) for path in sys.argv[1:3]]
refresh_command = sys.argv[3]
started = after.get("blindSpotLastStartedAt")
completed = after.get("blindSpotLastCompletedAt")
outcome = after.get("blindSpotLastOutcome")
terminal = (
    after.get("liveTestBlindSpotRefreshCommandID") == refresh_command
    and int(after.get("blindSpotAttempts") or 0)
        > int(before.get("blindSpotAttempts") or 0)
    and isinstance(after.get("blindSpotLastAttemptID"), str)
    and bool(after.get("blindSpotLastAttemptID"))
    and isinstance(started, (int, float))
    and isinstance(completed, (int, float))
    and completed >= started
    and outcome in {"succeeded", "empty", "failed", "cancelled"}
)
raise SystemExit(0 if terminal else 1)
PY
        then
            terminal_ready=0
            break
        fi
        sleep 1
    done
    check "$cond Blind Spot terminal attempt" "$terminal_ready" \
        "bounded wait=${BLIND_SPOT_TIMEOUT}s with attempt ID/outcome/timestamps"
    if [ "$terminal_ready" != "0" ]; then
        record_synthetic_evidence "$cond" blind-spot-timeout "$terminal_poll" || true
        send ai.cruxwing.livetest.restoreSettings
        return 1
    fi

    checkpoint "$cond" blind-spot-terminal || true
    local terminal_state="$OUTDIR/$cond.blind-spot-terminal.state.json"
    record_synthetic_evidence "$cond" blind-spot-terminal "$terminal_state" || \
        check "$cond Blind Spot terminal evidence" 1 "owner-only JSONL append failed"

    local metrics="$base.blind-spot.json"
    python3 - "$baseline" "$terminal_state" "$metrics" \
        "$goal_command" "$refresh_command" <<'PY'
import json, sys
before_path, after_path, out, goal_command, refresh_command = sys.argv[1:]
before, after = [json.load(open(path)) for path in (before_path, after_path)]
expected_goal = ("Identify the highest-impact missing decision, risk, or unsupported "
                 "assumption in the Project Falcon rollout, then give one concrete next question.")
def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)
def delta(key):
    return int(after.get(key) or 0) - int(before.get(key) or 0)

attempt_delta = delta("blindSpotAttempts")
success_delta = delta("blindSpotSuccesses")
failure_delta = delta("blindSpotFailures")
outcome = after.get("blindSpotLastOutcome")
result_count = after.get("blindSpotLastResultCount")
suggestions = after.get("suggestionsFull") or []
started = after.get("blindSpotLastStartedAt")
completed = after.get("blindSpotLastCompletedAt")
cache_hit = after.get("blindSpotLastCacheHit")
charged = after.get("blindSpotLastChargedCredits")
provider_attempts = after.get("blindSpotLastProviderAttemptCount")
provider_attempt_details = after.get("blindSpotLastProviderAttempts")
tier = str(after.get("currentTier") or "")
base_credit = {"free": 1, "pro": 3, "premium": 4, "ultra": 5}.get(tier)
safe_failure_reasons = {
    "funds exhausted", "rate limited", "credentials rejected", "timed out",
    "not configured", "temporarily unavailable", "network failure",
    "empty response", "request failed",
}
provider_attempt_details_sanitized = (
    isinstance(provider_attempt_details, list)
    and len(provider_attempt_details) <= 8
    and all(
        isinstance(item, dict)
        and set(item) == {"provider", "model", "reason"}
        and isinstance(item.get("provider"), str)
        and 0 < len(item.get("provider")) <= 64
        and isinstance(item.get("model"), str)
        and 0 < len(item.get("model")) <= 128
        and item.get("reason") in safe_failure_reasons
        for item in provider_attempt_details
    )
)
trace_core = (
    isinstance(after.get("blindSpotLastBackendCorrelationID"), str)
    and bool(after.get("blindSpotLastBackendCorrelationID"))
    and isinstance(after.get("blindSpotLastModel"), str)
    and bool(after.get("blindSpotLastModel"))
    and integer(after.get("blindSpotLastProviderLatencyMs"))
    and after.get("blindSpotLastProviderLatencyMs") >= 0
    and integer(charged) and charged >= 0
    and isinstance(cache_hit, bool)
    and integer(provider_attempts) and provider_attempts >= 0
    and isinstance(after.get("blindSpotLastGrounded"), bool)
)
success_attempt_semantics = (
    (cache_hit is True and provider_attempts == 0)
    or (cache_hit is False and provider_attempts >= 1)
)
failure_attempt_semantics = (
    outcome == "failed"
    and cache_hit is False
    and integer(provider_attempts) and provider_attempts >= 1
    and provider_attempt_details_sanitized
    and len(provider_attempt_details) == provider_attempts
)
trace_complete = trace_core and (
    (outcome in {"succeeded", "empty"}
     and isinstance(after.get("blindSpotLastProvider"), str)
     and bool(after.get("blindSpotLastProvider"))
     and success_attempt_semantics)
    or failure_attempt_semantics
)
billing_ok = (
    base_credit is not None and integer(charged)
    and ((cache_hit is True and charged == 0)
         or (cache_hit is False and outcome in {"succeeded", "empty"}
             and charged == base_credit)
         or (cache_hit is False and outcome == "failed" and charged == 0))
)
payload_present = (
    integer(result_count) and result_count >= 0
    and (result_count == 0 or (
        len(suggestions) > 0
        and all(isinstance(item.get("id"), str) and item.get("id")
                and isinstance(item.get("title"), str) and item.get("title").strip()
                and isinstance(item.get("detail"), str) and item.get("detail").strip()
                and item.get("kind") in {
                    "question", "risk", "missing_info", "advice", "hypothesis"
                } for item in suggestions)
    ))
)
trace = after.get("blindSpotSyntheticTrace")
payload = None
if isinstance(trace, dict):
    try:
        payload = json.loads(trace.get("requestPayload") or "")
    except (TypeError, ValueError):
        payload = None

def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)

def contains_access_token(value):
    if isinstance(value, dict):
        return any(str(key).lower() == "accesstoken" or contains_access_token(item)
                   for key, item in value.items())
    if isinstance(value, list):
        return any(contains_access_token(item) for item in value)
    return False

expected_payload_keys = {"goal", "transcript", "priorSuggestions", "grounded",
                         "probe", "theme"}
if isinstance(trace, dict) and trace.get("guidance") is not None:
    expected_payload_keys.add("guidance")
if isinstance(trace, dict) and trace.get("context") is not None:
    expected_payload_keys.add("context")
local_context = trace.get("localContext") if isinstance(trace, dict) else None
full_context = trace.get("context") if isinstance(trace, dict) else None
synthetic_exact = (
    isinstance(trace, dict) and isinstance(payload, dict)
    and set(payload) == expected_payload_keys
    and payload.get("goal") == trace.get("goal") == after.get("callGoal")
    and payload.get("transcript") == trace.get("transcript")
    and payload.get("priorSuggestions") == trace.get("priorTitles")
    and payload.get("guidance") == trace.get("guidance")
    and payload.get("context") == trace.get("context")
    and payload.get("probe") == trace.get("probe")
    and payload.get("theme") == trace.get("theme")
    and payload.get("grounded") == trace.get("grounded")
    and (local_context is None
         or (isinstance(full_context, str) and full_context.startswith(local_context)))
)
synthetic_token_free = isinstance(payload, dict) and not contains_access_token(payload)

synthetic_timing_ordered = False
if isinstance(trace, dict):
    prepared = trace.get("preparedAt")
    token_start = trace.get("tokenLookupStartedAt")
    token_end = trace.get("tokenLookupCompletedAt")
    provider_start = trace.get("providerStartedAt")
    provider_end = trace.get("providerCompletedAt")
    if all(finite(value) for value in
           (prepared, token_start, token_end, provider_start, provider_end)):
        ordered = prepared <= token_start <= token_end
        cursor = token_end
        connector_start = trace.get("connectorStartedAt")
        connector_end = trace.get("connectorCompletedAt")
        workflows = trace.get("connectorWorkflows")
        if connector_start is None and connector_end is None:
            ordered = ordered and workflows == []
        elif finite(connector_start) and finite(connector_end):
            ordered = ordered and cursor <= connector_start <= connector_end
            if isinstance(workflows, list):
                for workflow in workflows:
                    start = workflow.get("startedAt") if isinstance(workflow, dict) else None
                    end = workflow.get("completedAt") if isinstance(workflow, dict) else None
                    latency = workflow.get("latencyMs") if isinstance(workflow, dict) else None
                    ordered = (ordered and finite(start) and finite(end)
                               and connector_start <= start <= end <= connector_end
                               and integer(latency) and latency >= 0)
            else:
                ordered = False
            cursor = connector_end
        else:
            ordered = False
        consumed = trace.get("groundedCycleConsumedAt")
        if consumed is not None:
            ordered = ordered and finite(consumed) and cursor <= consumed
            cursor = consumed
        pack_start = trace.get("connectorPackStartedAt")
        pack_end = trace.get("connectorPackCompletedAt")
        if pack_start is None and pack_end is None:
            pass
        elif finite(pack_start) and finite(pack_end):
            ordered = ordered and cursor <= pack_start <= pack_end
            cursor = pack_end
        else:
            ordered = False
        synthetic_timing_ordered = ordered and cursor <= provider_start <= provider_end
report = {
    "attemptDelta": attempt_delta,
    "successDelta": success_delta,
    "failureDelta": failure_delta,
    "oneShotCadenceBounded": attempt_delta == 1,
    "successfulTerminal": success_delta == 1 and failure_delta == 0
                          and outcome in {"succeeded", "empty"},
    "outcome": outcome,
    "attemptID": after.get("blindSpotLastAttemptID"),
    "backendCorrelationID": after.get("blindSpotLastBackendCorrelationID"),
    "probeIDs": after.get("blindSpotLastProbeIDs") or [],
    "startedAt": started,
    "completedAt": completed,
    "latencySeconds": round(completed - started, 3)
                      if isinstance(started, (int, float))
                      and isinstance(completed, (int, float)) else None,
    "resultCount": result_count,
    "grounded": after.get("blindSpotLastGrounded"),
    "provider": after.get("blindSpotLastProvider"),
    "model": after.get("blindSpotLastModel"),
    "providerLatencyMs": after.get("blindSpotLastProviderLatencyMs"),
    "chargedCredits": charged,
    "cacheHit": cache_hit,
    "providerAttemptCount": provider_attempts,
    "providerAttempts": provider_attempt_details,
    "providerAttemptsSanitized": (
        provider_attempt_details_sanitized
        if outcome == "failed" else True
    ),
    "providerFallbackObserved": integer(provider_attempts) and provider_attempts > 1,
    "traceComplete": trace_complete,
    "billingWithinTariff": billing_ok,
    "expectedBaseCredits": base_credit,
    "resultPayloadPresent": payload_present,
    "visibleSuggestion": integer(result_count) and result_count > 0
                         and int(after.get("suggestionsCount") or 0) > 0,
    "goalCorrelated": (
        after.get("callGoal") == expected_goal
        and after.get("effectiveCallGoal") == expected_goal
        and after.get("liveTestSyntheticGoalCommandID") == goal_command
        and after.get("liveTestBlindSpotRefreshCommandID") == refresh_command
    ),
    "syntheticTraceExact": synthetic_exact,
    "syntheticTraceTimingOrdered": synthetic_timing_ordered,
    "syntheticTraceTokenFree": synthetic_token_free,
}
json.dump(report, open(out, "w"), indent=2, sort_keys=True)
PY
    local metrics_rc=$?
    check "$cond Blind Spot metrics artifact" "$metrics_rc" "$metrics"
    if [ "$metrics_rc" = "0" ]; then
        local metric_key metric_label metric_rc
        while IFS=: read -r metric_key metric_label; do
            python3 - "$metrics" "$metric_key" <<'PY' >/dev/null 2>&1
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1])).get(sys.argv[2]) is True else 1)
PY
            metric_rc=$?
            check "$cond $metric_label" "$metric_rc" \
                "$metric_key=$(python3 -c "import json;print(json.load(open('$metrics')).get('$metric_key'))")"
        done <<'EOF'
oneShotCadenceBounded:Blind Spot one-shot cadence
successfulTerminal:Blind Spot managed-provider success
traceComplete:Blind Spot provider trace
providerAttemptsSanitized:Blind Spot sanitized provider attempts
billingWithinTariff:Blind Spot tariff charge
resultPayloadPresent:Blind Spot response payload
goalCorrelated:Blind Spot synthetic goal correlation
syntheticTraceExact:Blind Spot exact synthetic request
syntheticTraceTimingOrdered:Blind Spot ordered workflow timings
syntheticTraceTokenFree:Blind Spot synthetic request excludes access tokens
EOF
        if python3 - "$metrics" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("visibleSuggestion") is True else 1)
PY
        then
            check "$cond Blind Spot visible suggestion" 0 \
                "full suggestion payload retained with terminal screenshot"
        elif [ "$cond" = "clean" ]; then
            check "$cond Blind Spot visible suggestion" 1 \
                "clean synthetic call returned no visible card"
        else
            skip "$cond Blind Spot visible suggestion" \
                "successful judge returned an empty result; terminal empty outcome retained"
        fi
        local event_attempt event_outcome event_provider event_model
        event_attempt="$(python3 -c "import json;d=json.load(open('$metrics'));print(d.get('attemptID'))")"
        event_outcome="$(python3 -c "import json;d=json.load(open('$metrics'));print(d.get('outcome'))")"
        event_provider="$(python3 -c "import json;d=json.load(open('$metrics'));print(d.get('provider'))")"
        event_model="$(python3 -c "import json;d=json.load(open('$metrics'));print(d.get('model'))")"
        event blind-spot-terminal "$cond" \
            "attempt=$event_attempt outcome=$event_outcome provider=$event_provider model=$event_model"
    fi
    send ai.cruxwing.livetest.restoreSettings
    return "$metrics_rc"
}

# Whether this process may actually inspect UI, which is what the AX-driven
# steps need. Deliberately NOT `tell System Events to get name of first
# process`: that answers without Accessibility, so it reports success on a
# machine where every AX step will fail. Inspecting windows is the real test.
accessibility_available() {
    osascript -l JavaScript \
        -e 'Application("System Events").processes.byName("Finder").windows().length' \
        >/dev/null 2>&1
}

# Entitlement without the UI. The app exposes ai.cruxwing.livetest.redeem, which
# redeems against the APP's own session — the same end state the Settings flow
# reaches, minus the clicks. Used only when Accessibility is unavailable, so the
# transcription and response conditions can still run.
promo_redemption_via_hook() {
    send ai.cruxwing.livetest.redeem code "$DEV_PROMO_CODE"
    for _ in $(seq 1 20); do
        sleep 1
        dump >/dev/null 2>&1 || continue
        [ "$(jqv currentTier)" = "ultra" ] && return 0
    done
    return 1
}

promo_redemption_ui_capture() {
    local command_id="$RUN_ID:settings-ai-promo"
    local armed_state="$OUTDIR/promo-redemption.armed.state.json"
    local settings_state="$OUTDIR/promo-redemption.settings.state.json"
    local pricing_state="$OUTDIR/promo-redemption.pricing.state.json"
    local final_state="$OUTDIR/promo-redemption.state.json"
    local candidate receipt_outcome attempt

    send ai.cruxwing.livetest.preparePromoRedemption commandID "$command_id"
    for attempt in $(seq 1 40); do
        candidate="$armed_state.poll-$attempt"
        if dump_to "$candidate" 4 && python3 - "$candidate" "$command_id" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
receipt = state.get("liveTestPromoRedemptionReceipt") or {}
ok = (receipt.get("commandID") == sys.argv[2]
      and receipt.get("outcome") == "armed"
      and receipt.get("previewActive") is False
      and isinstance(receipt.get("preparedAt"), (int, float)))
raise SystemExit(0 if ok else 1)
PY
        then
            cp "$candidate" "$armed_state"
            break
        fi
        sleep 0.25
    done
    [ -s "$armed_state" ] || return 1

    send ai.cruxwing.livetest.openSettings tab ai
    for attempt in $(seq 1 40); do
        candidate="$settings_state.poll-$attempt"
        if dump_to "$candidate" 4 && python3 - "$candidate" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
ok = (state.get("selectedSettingsTab") == "ai"
      and state.get("settingsWindowVisible") is True
      and state.get("settingsWindowCount") == 1
      and isinstance(state.get("settingsWindowNumber"), int))
raise SystemExit(0 if ok else 1)
PY
        then
            cp "$candidate" "$settings_state"
            break
        fi
        sleep 0.25
    done
    [ -s "$settings_state" ] || return 1

    ax_wait press settings.ai.manage-plan 40 || return 1
    event promo-ui all "command=$command_id action=manage-plan"
    ax_wait press paywall.see-plans 40 || return 1
    event promo-ui all "command=$command_id action=see-plans"
    ax_scroll_to_bottom || return 1
    ax_wait exists paywall.promo-code 40 || return 1
    sleep 0.35
    dump_to "$pricing_state" || return 1
    capture_window_field "$pricing_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/promo-redemption-pricing-bottom.png" || return 1
    event promo-ui all "command=$command_id action=scroll-bottom"

    ax_element set paywall.promo-code "DEV-UNLIMITED-LOCAL" || return 1
    ax_element verify paywall.promo-code "DEV-UNLIMITED-LOCAL" || return 1
    event promo-ui all "command=$command_id action=enter-exact-fixture"
    ax_wait enabled paywall.redeem 40 || return 1
    ax_wait press paywall.redeem 40 || return 1
    event promo-ui all "command=$command_id action=redeem"

    for attempt in $(seq 1 160); do
        candidate="$final_state.poll-$attempt"
        if ! dump_to "$candidate" 4; then
            sleep 0.25
            continue
        fi
        receipt_outcome="$(python3 - "$candidate" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1])).get("liveTestPromoRedemptionReceipt") or {}
print(receipt.get("outcome") or "")
PY
)"
        if [ "$receipt_outcome" = "failure" ]; then
            cp "$candidate" "$final_state"
            capture_window_field "$final_state" settingsWindowNumber \
                "$SCREENSHOT_DIR/promo-redemption-failure.png" >/dev/null 2>&1 || true
            event promo-redemption all \
                "command=$command_id outcome=failure exact=true plan=none tier=none preview=false"
            return 1
        fi
        if python3 - "$candidate" "$command_id" "$RUN_STARTED_EPOCH" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
receipt = state.get("liveTestPromoRedemptionReceipt") or {}
prepared = receipt.get("preparedAt")
started = receipt.get("startedAt")
completed = receipt.get("completedAt")
ordered = (all(isinstance(value, (int, float)) for value in
               (prepared, started, completed))
           and prepared >= float(sys.argv[3])
           and prepared <= started <= completed)
ok = (receipt.get("commandID") == sys.argv[2]
      and receipt.get("outcome") == "success"
      and receipt.get("exactCodeMatch") is True
      and receipt.get("planID") == "founder"
      and receipt.get("tier") == "ultra"
      and receipt.get("previewActive") is False
      and ordered
      and state.get("currentTier") == "ultra"
      and (state.get("tariffCopilotHours"), state.get("tariffComputeCredits"),
           state.get("tariffGroundedCycles")) == (60, 1500, 300)
      and int(state.get("copilotSecondsRemaining") or 0) > 0
      and int(state.get("groundedCyclesRemaining") or 0) > 0)
raise SystemExit(0 if ok else 1)
PY
        then
            cp "$candidate" "$final_state"
            break
        fi
        sleep 0.25
    done
    [ -s "$final_state" ] || {
        [ -n "${candidate:-}" ] && [ -s "$candidate" ] && \
            cp "$candidate" "$OUTDIR/promo-redemption.timeout.state.json"
        event promo-redemption all \
            "command=$command_id outcome=timeout exact=true plan=none tier=none preview=false"
        return 1
    }
    ax_wait exists paywall.success 20 || return 1
    capture_window_field "$final_state" settingsWindowNumber \
        "$SCREENSHOT_DIR/promo-redemption-success.png" || return 1
    event promo-redemption all \
        "command=$command_id outcome=success exact=true plan=founder tier=ultra preview=false"
    ax_wait press paywall.success-dismiss 20 || return 1
    sleep 0.25
    send ai.cruxwing.livetest.closeSettings
    return 0
}

# Entitlement: without this every AI assertion below scores a 401 body as an "answer".
# shellcheck source=testlib/entitle.sh
source "$LIB/entitle.sh"

# ── build ───────────────────────────────────────────────────────────────────
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo ">> building + installing"
    bash "$ROOT/build.sh" >"$OUTDIR/build.log" 2>&1 || { echo "!! build failed — $OUTDIR/build.log"; exit 2; }
fi

echo ">> scorer selftest"
python3 "$LIB/score_transcript.py" --selftest || { echo "!! scorer is broken; refusing to grade with it"; exit 2; }
python3 "$LIB/response_quality.py" --selftest || { echo "!! response scorer is broken; refusing to grade with it"; exit 2; }
python3 "$LIB/verify_prompt_overlap.py" --selftest || { echo "!! prompt-overlap verifier is broken"; exit 2; }
python3 "$LIB/normalize_unified_log.py" --selftest || { echo "!! log normalizer is broken"; exit 2; }
python3 "$LIB/prompt_schedule.py" --selftest || { echo "!! prompt scheduler is broken; refusing collision-prone live injection"; exit 2; }
python3 "$LIB/verify_media_recording.py" --selftest || { echo "!! media verifier is broken; refusing false-positive media evidence"; exit 2; }

event suite all "seed=$SEED conditions=$CONDITIONS media=$MEDIA_CONDITIONS"

osascript -e 'quit app "Cruxwing"' >/dev/null 2>&1
for _ in $(seq 1 40); do
    pgrep -x MeetGPT >/dev/null 2>&1 || break
    sleep 0.25
done
pgrep -x MeetGPT >/dev/null 2>&1 && {
    echo "!! existing Cruxwing process did not quit; refusing an ambiguous test launch"
    exit 2
}
/bin/launchctl setenv CRUXWING_LIVETEST_NONCE "$RUN_NONCE"
/bin/launchctl setenv CRUXWING_LIVETEST_ARTIFACT_ROOT "$OUTDIR"
/bin/launchctl setenv CRUXWING_LIVETEST_STARTED_AT "$RUN_STARTED_EPOCH"
/bin/launchctl setenv CRUXWING_DEV_CALL_LOGS 1
# Passing the secure run values on `open` is intentional. Some macOS launch
# paths cache the GUI bootstrap environment even after `launchctl setenv`,
# which silently disabled the hooks while launching the right signed bundle.
open --fresh \
    --env "CRUXWING_LIVETEST_NONCE=$RUN_NONCE" \
    --env "CRUXWING_LIVETEST_ARTIFACT_ROOT=$OUTDIR" \
    --env "CRUXWING_LIVETEST_STARTED_AT=$RUN_STARTED_EPOCH" \
    --env "CRUXWING_DEV_CALL_LOGS=1" \
    "$APP"; sleep 6
APP_PID="$(pgrep -x MeetGPT | tail -1)"
[ -n "$APP_PID" ] || { echo "!! launched app process was not found"; exit 2; }
start_network_log "$APP_PID" || { echo "!! privacy-safe network logger did not start"; exit 2; }
event process all "app-pid=$APP_PID"
dump || { echo "!! app not responding to hooks — dev build installed?"; exit 2; }
[ "$(jqv devCallDiagnosticsEnabled)" = "True" ]
check "dev call diagnostics armed" $? \
    "explicit dev gate enabled under nonce-confined owner-only artifact root"
checkpoint launch ready || true
[ "$DEV_PROMO_CODE" = "DEV-UNLIMITED-LOCAL" ] || {
    echo "!! live promo test requires the exact seeded DEV-UNLIMITED-LOCAL fixture"
    exit 3
}
# The UI capture is the evidence for SETTINGS-LIVE-PROMO-REDEMPTION and needs
# Accessibility. Everything AFTER it needs only the ENTITLEMENT it happens to
# produce. Aborting the whole matrix when Accessibility is missing meant one
# permission — the broadest one, since it grants UI control of the entire Mac —
# gated the transcription and response evidence too, which needs nothing but
# Screen Recording and audio.
#
# So: run the UI capture when it can run, and fall back to the hook when it
# cannot. The UI requirement is reported SKIPPED, never passed — the point of
# that check is the clicks, and a hook proves nothing about them.
if accessibility_available; then
    promo_redemption_ui_capture
    promo_redemption_rc=$?
    check "Settings AI promo redemption" "$promo_redemption_rc" \
        "fresh Accessibility-driven Manage → See plans → scroll → redeem receipt; Founder/Ultra with preview disabled"
    [ "$promo_redemption_rc" = "0" ] || exit 3
else
    skip "Settings AI promo redemption" \
        "needs Accessibility for this process (System Settings → Privacy → Accessibility). Entitling via the dev hook so the rest of the run proceeds."
    promo_redemption_via_hook || {
        echo "!! could not entitle via the dev redeem hook either — nothing downstream can run"
        exit 3
    }
    event entitlement all "via=dev-hook reason=accessibility-unavailable"
fi
ENTITLED=1
ENTITLE_TIER=ultra
ENTITLE_DETAIL="plan=founder tier=ultra via Settings AI Manage"
export ENTITLED ENTITLE_TIER ENTITLE_DETAIL

# Prompt schedule: derived from the seed, so successive runs land prompts at
# DIFFERENT points in the meeting. A fixed schedule only ever proves the app
# survives interruption at the one moment somebody happened to pick.
prompt_schedule() {   # prompt_schedule <duration> -> "secs:type:value" lines
    # The helper validates the emitted, one-decimal timestamps themselves:
    # five unique prompt types in the middle playback range with >=2s between
    # capture windows. The explicit 50 ms whattoask -> advice -> summary race
    # below remains separate and deliberately exercises model cancellation.
    python3 "$LIB/prompt_schedule.py" --duration "$1" --seed "$SEED"
}

run_condition() {   # run_condition <name> <extra make-video args...>
    local cond="$1"; shift
    EXECUTED_CONDITIONS=$((EXECUTED_CONDITIONS + 1))
    echo
    echo "──────── condition: $cond ────────"
    local base="$OUTDIR/$RUN_ID-$cond"
    local meta
    meta="$(python3 "$LIB/make_meeting_video.py" --script "$LIB/meeting_script.json" --out "$base" "$@" 2>&1)" \
        || { check "$cond render" 1 "video render failed: $(echo "$meta" | tail -1)"; return; }
    local video duration
    video="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())['video'])" <<<"$meta")"
    duration="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())['durationSeconds'])" <<<"$meta")"
    check "$cond render" 0 "${duration}s, $(basename "$video")"

    send ai.cruxwing.livetest.restoreSettings; sleep 0.2
    send ai.cruxwing.livetest.newCall; sleep 2
    local pre_record_settings_state="$OUTDIR/$cond.pre-record-settings.state.json"
    dump_to "$pre_record_settings_state" || {
        check "$cond pre-record Settings baseline" 1 "state dump failed"
        return
    }
    # Bias the active recording toward the synthetic meeting's known technical
    # vocabulary. The mid-call Settings worker then disables this fixture and
    # proves the running transcriber retains its start-time snapshot; its final
    # restore returns the developer's original glossary from the launch baseline.
    send ai.cruxwing.livetest.applySetting id transcription.glossary-fixture value enabled
    sleep 0.2
    if ! start_recording_and_wait; then
        check "$cond recording" 1 "did not reach correlated recording/call_started state"
        if [ "$RECORDING_ACTIVE" = "1" ]; then
            stop_recording_if_active || true
        fi
        exit 3
    fi
    check "$cond recording" 0 "recording state and call_started diagnostics correlated"
    local record_started; record_started="$(python3 -c 'import time;print(time.time())')"
    checkpoint "$cond" recording-start || true
    event flow "$cond" "recording-start"

    # Play through the speakers so ScreenCaptureKit hears it, like a real call.
    local playback_started; playback_started="$(python3 -c 'import time;print(time.time())')"
    play_video "$video" "$base.player.log"
    event video "$cond" "playback-start=$playback_started duration=$duration"
    # Give the player a bounded launch/decode lead. The absolute schedule below
    # accounts for this wait, while the timestamp above remains the latency
    # anchor for the first audible frame.
    sleep "${PLAYBACK_LEAD_SECONDS:-1}"
    kill -0 "$PLAY_PID" >/dev/null 2>&1
    check "$cond video launched" $? "player pid=$PLAY_PID, media=$(basename "$video")"
    if ! kill -0 "$PLAY_PID" >/dev/null 2>&1; then
        wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
        note "player failed — see $base.player.log"
        stop_recording_if_active || {
            check "$cond recording teardown" 1 "did not reach idle/call_ended after player failure"
            exit 3
        }
        return
    fi

    # Complete this transaction before any independently timed prompt worker is
    # armed: its exact exchange is cancelled after proving that a mid-request
    # Settings change does not replace the model snapshot.
    local model_snapshot_rc=0
    model_selection_during_call_capture "$cond" || model_snapshot_rc=$?
    check "$cond AI model selection snapshot during call" "$model_snapshot_rc" \
        "configured model changed while exact active exchange retained its launch model"
    if [ "$model_snapshot_rc" != "0" ]; then
        send ai.cruxwing.livetest.restoreSettings
        send ai.cruxwing.livetest.applySetting id transcription.glossary-fixture value enabled
        send ai.cruxwing.livetest.closeSettings
        [ -n "$PLAY_PID" ] && kill "$PLAY_PID" >/dev/null 2>&1 || true
        [ -n "$PLAY_PID" ] && wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
        stop_recording_if_active || {
            check "$cond recording teardown" 1 \
                "model snapshot failure did not reach idle/call_ended"
            exit 3
        }
        return
    fi

    # Inject five DISTINCT prompt surfaces mid-playback on the seeded schedule:
    # an interactive poll, a mandatory information notice, a contextual coach
    # question, a free-form user input, and a quick prompt. Poll/notice are
    # captured then cleared. Seeded captures have a deterministic minimum gap
    # and an isolated acknowledgement transaction; cancellation/generation is
    # exercised separately by the explicit 50 ms replacement sequence below.
    local schedule; schedule="$(prompt_schedule "$duration")"
    note "prompt schedule (seed $SEED): $(echo "$schedule" | tr '\n' ' ')"
    local prompt_index=0
    local prompt_pids=()
    while IFS= read -r slot; do
        local at rest kind value
        at="${slot%%:*}"
        rest="${slot#*:}"
        kind="${rest%%:*}"
        value="${rest#*:}"
        prompt_index=$((prompt_index + 1))
        scheduled_prompt_capture \
            "$cond" "$prompt_index" "$at" "$kind" "$value" "$playback_started" &
        prompt_pids+=("$!")
    done <<<"$schedule"
    local settings_at settings_pid settings_worker_failed=0
    settings_at="$(python3 - "$duration" <<'PY'
import sys
# Settings first captures General and AI mutations before requesting the
# Local→Instant handoff. Start near the beginning of playback: those two tabs
# consume several seconds before the engine write, and a percentage-based
# delay left the 1.25× fixture with only two diarized system turns after the
# 12-second Deepgram readiness deadline. The earlier schedule is also the more
# adversarial overlap — it collides with the first randomized prompt while
# leaving enough real speech to prove a three-caption, pinned-scroll handoff.
print(round(min(2.0, max(0.5, float(sys.argv[1]) * 0.05)), 1))
PY
)"
    settings_during_call_capture "$cond" "$settings_at" "$playback_started" \
        "$pre_record_settings_state" &
    settings_pid=$!
    WORKER_PIDS=("${prompt_pids[@]}" "$settings_pid")

    # Wait for capture workers only after every injection timer is armed. The
    # waits therefore cannot perturb the seeded playback timestamps.
    local prompt_pid prompt_worker_failures=0
    for prompt_pid in "${prompt_pids[@]}"; do
        wait "$prompt_pid" 2>/dev/null || prompt_worker_failures=$((prompt_worker_failures + 1))
    done
    wait "$settings_pid" 2>/dev/null || settings_worker_failed=1
    WORKER_PIDS=()
    [ "$prompt_worker_failures" -eq 0 ]
    check "$cond prompt workers completed" $? \
        "$(( ${#prompt_pids[@]} - prompt_worker_failures ))/${#prompt_pids[@]} identified prompt captures completed"

    local settings_result="$OUTDIR/$cond.settings.result.json"
    [ "$settings_worker_failed" -eq 0 ] && [ -s "$settings_result" ]
    check "$cond Settings mutation worker" $? \
        "AI + Transcription + Connected Apps tabs mutated during playback; artifacts=$settings_result"
    local setting_key setting_label setting_ok
    while IFS=: read -r setting_key setting_label; do
        setting_ok=1
        if [ -s "$settings_result" ]; then
            python3 - "$settings_result" "$setting_key" <<'PY' >/dev/null 2>&1
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1])).get(sys.argv[2]) is True else 1)
PY
            setting_ok=$?
        fi
        check "$cond $setting_label" "$setting_ok" "$setting_key=$( [ -s "$settings_result" ] && python3 -c "import json;print(json.load(open('$settings_result')).get('$setting_key'))" || echo missing )"
    done <<'EOF'
window:single Settings window with screenshots
generalSettingsDuringCall:General preferences change safely during call
liveWatchReconciliation:live co-pilot switches reconcile tasks
liveTranscriptionEngineSwitch:Local to Instant switches the active call
instantCaptionCausality:Instant callback produces a finalized caption after readiness
instantDiarizationEvidence:Instant captions retain speaker labels
instantViewportPinned:transcript viewport stays pinned through Instant final growth
deferredTranscriptionIsolation:next-recording settings stay deferred
fullTranscriptionControlMatrix:all visible transcription preferences reconcile safely
connectedGlossarySuggestionsDuringCall:connected-app glossary proposals remain bounded and deferred
connectedAppsGroundingDuringCall:connected-app grounding changes safely during call
accountPrivacySettingsDuringCall:Account and Privacy tab remains safe during call
restoration:preferences restored during call
captureContinuity:mic and system capture continue through Settings
closedWithoutStoppingCall:closing Settings keeps recording
EOF

    prompt_index=0
    while IFS= read -r slot; do
        local at rest kind value name predicate expected state screenshot surface_id
        at="${slot%%:*}"
        rest="${slot#*:}"
        kind="${rest%%:*}"
        value="${rest#*:}"
        prompt_index=$((prompt_index + 1))
        surface_id="$RUN_ID:$cond:$prompt_index:$kind"
        case "$kind" in
            poll)
                name="prompt-$prompt_index-poll"; predicate="poll"; expected=""
                ;;
            mandatory)
                name="prompt-$prompt_index-mandatory"; predicate="mandatory"; expected=""
                ;;
            contextual)
                name="prompt-$prompt_index-contextual"; predicate="prompt-contains"
                expected="Act as a sharp meeting coach."
                ;;
            freeform)
                name="prompt-$prompt_index-freeform"; predicate="prompt-equals"; expected="$value"
                ;;
            quick)
                name="prompt-$prompt_index-quick-$value"; predicate="prompt-contains"
                expected="Summarize this meeting so far"
                ;;
        esac
        state="$OUTDIR/$cond.$name.state.json"
        screenshot="$SCREENSHOT_DIR/$cond.$name.png"
        { [ -s "$state" ] && \
          state_matches "$state" "$predicate" "$expected" "$surface_id" && \
          [ -s "$screenshot" ]; }
        check "$cond $name screenshot" $? "$screenshot plus correlated semantic state"

        case "$kind" in
            poll)
                local poll_count
                poll_count="$(python3 - "$state" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("pendingClarificationCount", 0))
PY
)"
                [ "${poll_count:-0}" -gt 0 ] 2>/dev/null
                check "$cond interactive poll surfaced" $? "${poll_count:-0} question(s)"
                ;;
            mandatory)
                local mandatory_message
                mandatory_message="$(python3 - "$state" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("liveTestMandatoryNoticeMessage") or "")
PY
)"
                { [ -n "$mandatory_message" ] && [ "$mandatory_message" != "None" ]; }
                check "$cond mandatory information surfaced" $? "visible notice captured"
                ;;
        esac
        note "t=${at}s injected '$kind' ($value)"
    done <<<"$schedule"

    # Goal-setting and the one-shot refresh happen only after the synthetic
    # video has produced enough finalized transcript material. Keep recording
    # through the terminal response so cancellation cannot masquerade as
    # successful Blind Spot coverage.
    blind_spot_capture "$cond" "$base" || true

    # Deterministically exercise rapid model-backed replacement after the five
    # seeded UI surfaces have been captured. Each next notification lands while
    # the previous request is still in progress, so AppState must preserve two
    # explicit `superseded` terminals before the final Summary succeeds. The
    # final-state verifier below proves this from IDs and timestamps.
    local overlap_started overlap_prefix
    overlap_started="$(python3 -c 'import time;print(time.time())')"
    overlap_prefix="$RUN_ID:$cond:model-overlap"
    send ai.cruxwing.livetest.runPrompt id "whattoask" \
        surfaceID "$overlap_prefix:whattoask"
    sleep 0.05
    send ai.cruxwing.livetest.runPrompt id "advice" \
        surfaceID "$overlap_prefix:advice"
    sleep 0.05
    send ai.cruxwing.livetest.runPrompt id "summary" \
        surfaceID "$overlap_prefix:summary"
    event prompt-overlap "$cond" \
        "started=$overlap_started sequence=whattoask,advice,summary"

    # Let playback finish plus the transcription tail.
    local remaining
    remaining="$(python3 - "$playback_started" "$duration" <<'PY'
import sys, time
print(max(0.0, float(sys.argv[1]) + float(sys.argv[2]) + 14.0 - time.time()))
PY
)"
    sleep "$remaining"
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" >/dev/null 2>&1 || true
    [ -n "$PLAY_PID" ] && wait "$PLAY_PID" 2>/dev/null || true
    PLAY_PID=""

    # A model or backend failure must become a terminal visible state, never a
    # spinner that survives the video. Polling is evidence for flow-completion
    # latency and gives the final in-video summary a fair chance to finish. Keep
    # the call active through both terminal responses: the dev-call diagnostic
    # stream is intentionally per-call and closes on Stop.
    local ai_wait_started; ai_wait_started="$(python3 -c 'import time;print(time.time())')"
    for _ in $(seq 1 "$AI_TIMEOUT"); do
        dump || true
        [ "$(jqv aiStreaming)" = "False" ] && break
        sleep 1
    done
    dump || { check "$cond capture" 1 "no state dump"; return; }
    { [ "$(jqv aiStreaming)" = "False" ] &&
      [ "$(jqv aiResponsePromptID)" = "summary" ] &&
      [ "$(jqv aiResponseStatus)" = "succeeded" ]; }
    check "$cond overlapping Summary reached successful terminal state" $? \
        "id=$(jqv aiResponsePromptID) status=$(jqv aiResponseStatus) streaming=$(jqv aiStreaming)"
    cp "$STATE_JSON" "$base.overlap-summary.state.json"

    # A deliberately superseded prompt must never be the only thing measured,
    # but the final Summary alone is also insufficient evidence. Run Advice
    # after Summary has terminalized so two distinct prompt IDs/types must meet
    # all per-response quality and latency gates.
    send ai.cruxwing.livetest.runPrompt id "advice" \
        surfaceID "$overlap_prefix:gradeable-advice"
    for _ in $(seq 1 "$AI_TIMEOUT"); do
        dump || true
        [ "$(jqv aiStreaming)" = "False" ] && break
        sleep 1
    done
    dump || { check "$cond advice capture" 1 "no state dump"; return; }
    { [ "$(jqv aiStreaming)" = "False" ] &&
      [ "$(jqv aiResponsePromptID)" = "advice" ] &&
      [ "$(jqv aiResponseStatus)" = "succeeded" ]; }
    check "$cond independent Advice reached successful terminal state" $? \
        "id=$(jqv aiResponsePromptID) status=$(jqv aiResponseStatus) streaming=$(jqv aiStreaming)"
    local ai_terminal_latency
    ai_terminal_latency="$(python3 - "$ai_wait_started" <<'PY'
import sys, time
print(round(time.time() - float(sys.argv[1]), 3))
PY
    )"
    event flow "$cond" "prompt-terminal-latency=$ai_terminal_latency"
    stop_recording_if_active || {
        check "$cond recording teardown" 1 "did not reach idle with a correlated call_ended record"
        exit 3
    }
    sleep 3
    dump || { check "$cond final post-stop capture" 1 "no state dump"; return; }
    checkpoint "$cond" final || true
    cp "$STATE_JSON" "$base.state.json"
    python3 - "$base.state.json" <<'PY' >/dev/null 2>&1
import json, re, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
relative = state.get("devCallDiagnosticsRelativePath")
valid_path = (isinstance(relative, str)
              and re.fullmatch(r"dev-call-diagnostics/call-[0-9a-f-]+\.jsonl", relative))
ok = (state.get("devCallDiagnosticsEnabled") is True
      and isinstance(state.get("devCallDiagnosticsCallID"), str)
      and isinstance(state.get("devCallDiagnosticsSessionID"), str)
      and valid_path
      and int(state.get("devCallDiagnosticsEventCount") or 0) > 0
      and int(state.get("devCallDiagnosticsDroppedEventCount") or 0) == 0
      and int(state.get("devCallDiagnosticsBytesWritten") or 0) > 0)
raise SystemExit(0 if ok else 1)
PY
    check "$cond dev call diagnostic state" $? \
        "correlated owner-only JSONL path with events, bytes, and zero dropped records"
    record_synthetic_evidence "$cond" final "$base.state.json" || \
        check "$cond final synthetic evidence" 1 "owner-only JSONL append failed"

    local overlap_report="$base.prompt-overlap.json"
    python3 "$LIB/verify_prompt_overlap.py" \
        --state "$base.state.json" --started-at "$overlap_started" \
        --sequence "whattoask,advice,summary" --out "$overlap_report" >/dev/null
    local overlap_rc=$?
    check "$cond model-backed prompt overlap evidence" "$overlap_rc" \
        "whattoask→advice→summary IDs/timestamps/statuses in $overlap_report"

    local lines system_lines
    lines="$(jqv transcriptCount)"; system_lines="$(jqv systemEntries)"
    [ "${system_lines:-0}" -gt 0 ]
    check "$cond captured system audio" $? \
        "$system_lines system lines ($lines total across concurrent tracks)"
    [ "${system_lines:-0}" -gt 0 ] || {
        note "no system audio captured — check Screen Recording permission and output device"
        return
    }

    # Duplex evidence: a Zoom-like topology means remote audio is physically
    # rendered through built-in speakers while ScreenCaptureKit and the live
    # microphone continue delivering buffers. Transcript text alone cannot
    # prove mic health because AEC/VAD may correctly emit no mic words.
    local duplex_json="$base.duplex.json"
    python3 - "$OUTDIR/$cond.recording-start.state.json" "$base.state.json" \
        "$playback_started" "$duration" "$duplex_json" <<'PY'
import json, re, sys
baseline_path, final_path, playback, duration, out = sys.argv[1:]
baseline = json.load(open(baseline_path))
final = json.load(open(final_path))
playback, duration = float(playback), float(duration)

def delta(key):
    return max(0, float(final.get(key) or 0) - float(baseline.get(key) or 0))

level = str(final.get("outputLevel") or "")
volume_match = re.search(r"\bvolume=([0-9.]+)", level)
volume = float(volume_match.group(1)) if volume_match else None
mic_buffers = int(delta("micCaptureBufferCount"))
system_buffers = int(delta("systemCaptureBufferCount"))
mic_samples = int(delta("micCaptureRMSSampleCount"))
system_samples = int(delta("systemCaptureRMSSampleCount"))
mic_non_silent = int(delta("micCaptureNonSilentSamples"))
system_non_silent = int(delta("systemCaptureNonSilentSamples"))
cutoff = playback + duration * 0.5
mic_last = float(final.get("micCaptureLastBufferAt") or 0)
system_last = float(final.get("systemCaptureLastBufferAt") or 0)
route = str(final.get("outputRoute") or "")
report = {
    "microphonePermissionGranted": bool(final.get("microphonePermissionGranted")),
    "screenRecordingPermissionGranted": bool(final.get("screenRecordingPermissionGranted")),
    "outputRoute": route,
    "outputLevel": level,
    "outputVolume": volume,
    "speakerOutputReady": route == "builtin-speakers" and "muted=no" in level
                          and volume is not None and volume >= 0.05,
    "micVoiceProcessingActive": bool(final.get("micVoiceProcessingActive")),
    "micBufferDelta": mic_buffers,
    "systemBufferDelta": system_buffers,
    "micRMSSampleDelta": mic_samples,
    "systemRMSSampleDelta": system_samples,
    "micNonSilentSampleDelta": mic_non_silent,
    "systemNonSilentSampleDelta": system_non_silent,
    "micMeanRMSDuringPlayback": round(delta("micCaptureRMSSum") / max(1, mic_samples), 7),
    "systemMeanRMSDuringPlayback": round(delta("systemCaptureRMSSum") / max(1, system_samples), 7),
    "micLastBufferAt": mic_last,
    "systemLastBufferAt": system_last,
    "micLiveThroughPlayback": mic_buffers >= 10 and mic_samples >= 2 and mic_last >= cutoff,
    "systemLiveThroughPlayback": system_buffers >= 10 and system_samples >= 2
                                 and system_non_silent > 0 and system_last >= cutoff,
    "speakerToMicActivity": mic_non_silent > 0,
}
json.dump(report, open(out, "w"), indent=2, sort_keys=True)
PY
    local duplex_rc=$?
    check "$cond duplex diagnostics produced" "$duplex_rc" "$duplex_json"
    if [ "$duplex_rc" = "0" ]; then
        python3 -c "import json,sys;d=json.load(open('$duplex_json'));sys.exit(0 if d['microphonePermissionGranted'] and d['screenRecordingPermissionGranted'] else 1)"
        check "$cond capture permissions" $? "microphone and screen recording granted"
        python3 -c "import json,sys;d=json.load(open('$duplex_json'));sys.exit(0 if d['speakerOutputReady'] else 1)"
        check "$cond built-in speaker output" $? \
            "$(python3 -c "import json;d=json.load(open('$duplex_json'));print(d['outputRoute'], d['outputLevel'])")"
        python3 -c "import json,sys;d=json.load(open('$duplex_json'));sys.exit(0 if d['micLiveThroughPlayback'] else 1)"
        check "$cond live microphone track" $? \
            "$(python3 -c "import json;d=json.load(open('$duplex_json'));print(str(d['micBufferDelta'])+' buffers, mean RMS='+str(d['micMeanRMSDuringPlayback']))")"
        python3 -c "import json,sys;d=json.load(open('$duplex_json'));sys.exit(0 if d['systemLiveThroughPlayback'] else 1)"
        check "$cond live remote/system track" $? \
            "$(python3 -c "import json;d=json.load(open('$duplex_json'));print(str(d['systemBufferDelta'])+' buffers, mean RMS='+str(d['systemMeanRMSDuringPlayback']))")"
        if [ "$(python3 -c "import json;print(json.load(open('$duplex_json'))['micVoiceProcessingActive'])")" = "True" ]; then
            skip "$cond speaker-to-mic acoustic activity" \
                "voice processing/AEC active; mic liveness is gated but echo may be intentionally removed"
        else
            python3 -c "import json,sys;d=json.load(open('$duplex_json'));sys.exit(0 if d['speakerToMicActivity'] else 1)"
            check "$cond speaker-to-mic acoustic activity" $? \
                "raw mic non-silent samples=$(python3 -c "import json;print(json.load(open('$duplex_json'))['micNonSilentSampleDelta'])")"
        fi
    fi

    # First-line latency: how long after Record until anything appeared.
    local latency
    latency="$(python3 - "$base.state.json" "$record_started" <<'PY'
import json, sys
state = json.load(open(sys.argv[1])); started = float(sys.argv[2])
lines = [line for line in (state.get("transcriptFull") or [])
         if line.get("source") == "system"]
print(round(lines[0]["at"] - started, 2) if lines else -1)
PY
)"
    note "first transcript line at +${latency}s"

    python3 "$LIB/score_transcript.py" --truth "$base.truth.json" --hyp "$base.state.json" \
        --playback-start "$playback_started" --source system \
        --out "$base.score.json" >/dev/null 2>&1
    local score_rc=$?
    check "$cond transcript scorer completed" "$score_rc" "$base.score.json"
    [ "$score_rc" = "0" ] || return
    local wer recall dup visible_dup echo_rate spk latency_p95 speaker_lines speaker_coverage engine
    wer="$(python3 -c "import json;print(json.load(open('$base.score.json'))['wer'])")"
    recall="$(python3 -c "import json;print(json.load(open('$base.score.json'))['termRecall'])")"
    dup="$(python3 -c "import json;print(json.load(open('$base.score.json'))['duplicationRate'])")"
    visible_dup="$(python3 -c "import json;print(json.load(open('$base.score.json'))['visibleDuplicationRate'])")"
    echo_rate="$(python3 -c "import json;print(json.load(open('$base.score.json'))['crossTrackEchoRate'])")"
    spk="$(python3 -c "import json;print(json.load(open('$base.score.json'))['speakerAccuracy'])")"
    latency_p95="$(python3 -c "import json;print(json.load(open('$base.score.json')).get('latencySecondsP95',-1))")"
    speaker_lines="$(python3 -c "import json;print(json.load(open('$base.score.json')).get('speakerEvaluatedLines',0))")"
    speaker_coverage="$(python3 -c "import json;print(json.load(open('$base.score.json')).get('speakerLabelCoverage',0))")"
    engine="$(jqv transcriptionEngine)"
    local missing; missing="$(python3 -c "import json;print(', '.join(json.load(open('$base.score.json'))['missingTerms']) or '-')")"

    local max_wer="$MAX_WER_CLEAN"
    [ "$cond" = "noisy" ] && max_wer="$MAX_WER_NOISY"
    python3 -c "import sys;sys.exit(0 if $wer <= $max_wer else 1)"
    check "$cond WER" $? "$wer (bar $max_wer)"
    python3 -c "import sys;sys.exit(0 if $recall >= $MIN_TERM_RECALL else 1)"
    check "$cond technical terms" $? "recall $recall, missing: $missing"
    python3 -c "import sys;sys.exit(0 if $dup <= $MAX_DUPLICATION else 1)"
    check "$cond system-track duplication" $? "$dup (bar $MAX_DUPLICATION)"
    python3 -c "import sys;sys.exit(0 if $visible_dup <= $MAX_DUPLICATION else 1)"
    check "$cond visible all-track duplication" $? "$visible_dup (bar $MAX_DUPLICATION)"
    python3 -c "import sys;sys.exit(0 if $echo_rate <= $MAX_CROSS_TRACK_ECHO else 1)"
    check "$cond cross-track speaker echo" $? "$echo_rate (bar $MAX_CROSS_TRACK_ECHO)"
    python3 -c "import sys;sys.exit(0 if $latency_p95 >= 0 and $latency_p95 <= $MAX_TRANSCRIPT_LATENCY_P95 else 1)"
    check "$cond transcript latency p95" $? "${latency_p95}s (bar ${MAX_TRANSCRIPT_LATENCY_P95}s)"

    # The call may restore the developer's Local preference after Settings, so
    # score the causally tagged Instant slice on its own. Session-final engine
    # state must not turn a real Deepgram diarization failure into a skip.
    local instant_hyp="$base.instant-provider.state.json"
    local instant_score="$base.instant-provider.score.json"
    python3 - "$base.state.json" "$settings_result" "$instant_hyp" <<'PY'
import json, sys
state, settings = [json.load(open(path)) for path in sys.argv[1:3]]
switched_at = float(settings.get("instantSwitchAt") or 0)
lines = [line for line in (state.get("transcriptFull") or [])
         if line.get("transcriptionEngine") == "deepgram"
         and isinstance(line.get("at"), (int, float))
         and line["at"] >= switched_at]
json.dump({"transcriptFull": lines}, open(sys.argv[3], "w"), indent=2, sort_keys=True)
PY
    python3 "$LIB/score_transcript.py" --truth "$base.truth.json" \
        --hyp "$instant_hyp" --playback-start "$playback_started" --source system \
        --out "$instant_score" >/dev/null 2>&1
    local instant_score_rc=$?
    if [ "$instant_score_rc" = "0" ]; then
        python3 - "$instant_score" "$MIN_SPEAKER_ACCURACY" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
ok = (int(d.get("speakerEvaluatedLines") or 0) >= 3
      and float(d.get("speakerLabelCoverage") or 0) >= 0.6
      and float(d.get("speakerAccuracy") or 0) >= float(sys.argv[2]))
raise SystemExit(0 if ok else 1)
PY
        instant_score_rc=$?
    fi
    check "$cond Instant speaker attribution" "$instant_score_rc" \
        "provider-tagged lines scored in $instant_score"

    if [ "$speaker_lines" -ge 3 ] && \
       python3 -c "import sys;sys.exit(0 if $speaker_coverage >= 0.6 else 1)"; then
        python3 -c "import sys;sys.exit(0 if $spk >= $MIN_SPEAKER_ACCURACY else 1)"
        check "$cond speaker attribution" $? "accuracy $spk across $speaker_lines aligned lines (label coverage $speaker_coverage)"
    elif [ "$REQUIRE_DIARIZATION" = "1" ] || [ "$engine" = "deepgram" ]; then
        check "$cond speaker attribution" 1 \
            "engine=$engine lacked 3 labeled aligned lines at >=60% coverage (lines=$speaker_lines coverage=$speaker_coverage)"
    else
        skip "$cond speaker attribution" "measured as 0.0: engine=$engine has no live diarization; set REQUIRE_DIARIZATION=1 to gate"
    fi

    # In-call answers: grade EVERY archived/current answer, not only whichever
    # happened to be visible last. The deterministic evaluator checks terminal
    # completion, meeting relevance/grounding, prompt-specific fulfillment,
    # coherence/repetition, and unsupported numeric claims.
    local ai_chars ai_err
    ai_chars="$(jqv aiResponseChars)"; ai_err="$(jqv aiResponseIsError)"
    if [ "$ENTITLED" = "1" ]; then
        { [ "${ai_chars:-0}" -gt 0 ] && [ "$ai_err" = "False" ]; }
        check "$cond in-call answer produced" $? "$ai_chars chars, error=$ai_err"
        python3 "$LIB/response_quality.py" \
            --truth "$base.truth.json" --state "$base.state.json" \
            --playback-start "$playback_started" \
            --min-responses 2 --min-overall "$MIN_RESPONSE_QUALITY" \
            --min-completion 0.25 --min-response-overall 0.35 \
            --min-response-relevance "$MIN_RESPONSE_RELEVANCE" \
            --min-response-fulfillment "$MIN_RESPONSE_FULFILLMENT" \
            --min-response-coherence "$MIN_RESPONSE_COHERENCE" \
            --max-response-latency "$MAX_AI_RESPONSE_LATENCY" \
            --require-prompt-id summary --require-prompt-id advice \
            --require-prompt-type summary --require-prompt-type freeform \
            --require-explicit-lifecycle \
            --max-repetition 0.25 --out "$base.responses.json" >/dev/null
        local quality_rc=$?
        local quality_detail
        quality_detail="$(python3 - "$base.responses.json" <<'PY'
import json, sys
r=json.load(open(sys.argv[1])); a=r["aggregate"]
s=a["scores"]
print(f"{a['responseCount']}/{a['attemptCount']} successful, overall={s['overall']:.3f}, relevance={s['meetingRelevanceGrounding']:.3f}, fulfillment={s['promptFulfillment']:.3f}, coherence={s['coherenceRepetition']:.3f}, max latency={a['latencySecondsMax']}s, statuses={a['terminalStatusCounts']}")
PY
)"
        check "$cond response quality" "$quality_rc" "$quality_detail"
    else
        skip "$cond in-call answer" "unentitled — would grade a 401 body"
    fi

    python3 - "$base.score.json" "$OUTDIR/report.json" "$cond" "$latency" "$SEED" <<'PY'
import json, os, sys
score_path, report_path, cond, latency, seed = sys.argv[1:6]
report = {}
if os.path.exists(report_path):
    report = json.load(open(report_path))
entry = json.load(open(score_path))
entry["firstLineLatencySeconds"] = float(latency)
entry["seed"] = int(seed)
response_path = score_path.replace(".score.json", ".responses.json")
if os.path.exists(response_path):
    entry["responseQuality"] = json.load(open(response_path))["aggregate"]
duplex_path = score_path.replace(".score.json", ".duplex.json")
if os.path.exists(duplex_path):
    entry["duplexAudio"] = json.load(open(duplex_path))
blind_spot_path = score_path.replace(".score.json", ".blind-spot.json")
if os.path.exists(blind_spot_path):
    entry["blindSpot"] = json.load(open(blind_spot_path))
report.setdefault("conditions", {})[cond] = entry
json.dump(report, open(report_path, "w"), indent=2, sort_keys=True)
PY
}

# A compact second topology for non-call media. These recordings deliberately
# avoid the five prompt surfaces, Blind Spot cycle, and Settings matrix already
# paid for above. They still render and play real audio, keep the physical mic
# and system capture active, mutate the manual recording type mid-stream, and
# grade the resulting transcript. The tutorial adds exactly one model request:
# the media-adapted Apply to Project prompt.
run_media_condition() { # run_media_condition <tutorial|video> <script> <temporary type>
    local kind="$1" script="$2" temporary="$3"
    local cond="media-$kind"
    EXECUTED_MEDIA_CONDITIONS=$((EXECUTED_MEDIA_CONDITIONS + 1))
    echo
    echo "──────── recording: $cond ────────"

    local base="$OUTDIR/$RUN_ID-$cond"
    local meta
    meta="$(python3 "$LIB/make_meeting_video.py" --script "$script" --out "$base" 2>&1)" \
        || { check "$cond render" 1 "media render failed: $(echo "$meta" | tail -1)"; return; }
    local video duration
    video="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())['video'])" <<<"$meta")"
    duration="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read())['durationSeconds'])" <<<"$meta")"
    check "$cond render" 0 "${duration}s deterministic fixture, $(basename "$video")"

    send ai.cruxwing.livetest.restoreSettings; sleep 0.2
    send ai.cruxwing.livetest.closeSettings
    send ai.cruxwing.livetest.newCall; sleep 1
    send ai.cruxwing.livetest.applySetting id recording.context value "$kind"
    if [ "$kind" = "tutorial" ]; then
        # The existing fixed fixture contains idempotent + Postgres and proves
        # the technical-dictionary path without adding arbitrary test strings.
        send ai.cruxwing.livetest.applySetting id transcription.glossary-fixture value enabled
    else
        send ai.cruxwing.livetest.applySetting id transcription.glossary-fixture value disabled
    fi
    # Media coverage pays for one explicit tutorial application answer only.
    # Ambient co-pilot loops are already exercised and tariff-scored in every
    # meeting condition; leaving them armed here would spend nondeterministic
    # background cycles without adding a distinct assertion.
    local media_watch
    for media_watch in ai.brainstorm ai.agenda ai.fact-check ai.rhetoric ai.facilitation; do
        send ai.cruxwing.livetest.applySetting id "$media_watch" value false
    done
    sleep 0.3
    local selected_state="$base.context-selected.state.json"
    if ! dump_to "$selected_state" || ! python3 - "$selected_state" "$kind" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
kind = sys.argv[2]
expected = kind.replace("_", " ").title()
ambient = ["brainstormConfigured", "agendaConfigured", "factCheckConfigured",
           "rhetoricConfigured", "facilitationConfigured"]
raise SystemExit(0 if state.get("recordingContextSelection") == kind
                 and state.get("effectiveRecordingContext") == expected
                 and all(state.get(key) is False for key in ambient)
                 and state.get("isRecording") is False else 1)
PY
    then
        check "$cond manual type before recording" 1 \
            "recording.context=$kind was not acknowledged before Record"
        return
    fi
    check "$cond manual type before recording" 0 \
        "selection=$kind wins; ambient paid co-pilot loops off for this compact fixture"

    if ! start_recording_and_wait; then
        check "$cond recording" 1 "did not reach correlated recording/call_started state"
        [ "$RECORDING_ACTIVE" = "1" ] && stop_recording_if_active || true
        return
    fi
    check "$cond recording" 0 "real mic + system capture started"
    checkpoint "$cond" recording-start || true
    event flow "$cond" "recording-start type=$kind"

    local playback_started
    playback_started="$(python3 -c 'import time;print(time.time())')"
    play_video "$video" "$base.player.log"
    event video "$cond" "playback-start=$playback_started duration=$duration fixture=$(basename "$script")"
    sleep 1
    if ! kill -0 "$PLAY_PID" >/dev/null 2>&1; then
        wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
        check "$cond video launched" 1 "ffplay exited during launch — see $base.player.log"
        stop_recording_if_active || true
        return
    fi
    check "$cond video launched" 0 "speaker playback pid=$PLAY_PID"

    # Wait until both capture taps have accumulated real playback buffers, then
    # switch the user-selected type and switch it back without ending the call.
    local transition_wait
    transition_wait="$(python3 - "$playback_started" "$duration" <<'PY'
import sys, time
target = float(sys.argv[1]) + max(3.5, float(sys.argv[2]) * 0.30)
print(max(0.0, target - time.time()))
PY
)"
    sleep "$transition_wait"
    local before_change="$base.context-before-change.state.json"
    local changed="$base.context-changed.state.json"
    local restored="$base.context-restored.state.json"
    if ! dump_to "$before_change"; then
        check "$cond context transition evidence" 1 "pre-change state dump failed"
        [ -n "$PLAY_PID" ] && kill "$PLAY_PID" >/dev/null 2>&1 || true
        [ -n "$PLAY_PID" ] && wait "$PLAY_PID" 2>/dev/null || true
        PLAY_PID=""
        stop_recording_if_active || true
        return
    fi
    send ai.cruxwing.livetest.applySetting id recording.context value "$temporary"
    event recording-context "$cond" "$kind->$temporary during active playback"
    sleep 1.25
    dump_to "$changed" || true
    send ai.cruxwing.livetest.applySetting id recording.context value "$kind"
    event recording-context "$cond" "$temporary->$kind during active playback"
    sleep 1.25
    dump_to "$restored" || true
    local continuity_report="$base.context-continuity.json"
    python3 "$LIB/verify_media_recording.py" transition \
        --before "$before_change" --changed "$changed" --restored "$restored" \
        --expected "$kind" --temporary "$temporary" --out "$continuity_report" >/dev/null 2>&1
    local continuity_rc=$?
    check "$cond manual type switch continuity" "$continuity_rc" \
        "same call/session; both capture taps advance; $kind->$temporary->$kind ($continuity_report)"
    checkpoint "$cond" context-restored || true

    local remaining
    remaining="$(python3 - "$playback_started" "$duration" "$MEDIA_TRANSCRIPT_TAIL_SECONDS" <<'PY'
import sys, time
print(max(0.0, float(sys.argv[1]) + float(sys.argv[2]) + float(sys.argv[3]) - time.time()))
PY
)"
    sleep "$remaining"
    [ -n "$PLAY_PID" ] && kill "$PLAY_PID" >/dev/null 2>&1 || true
    [ -n "$PLAY_PID" ] && wait "$PLAY_PID" 2>/dev/null || true
    PLAY_PID=""

    local response_report=""
    if [ "$kind" = "tutorial" ]; then
        EXECUTED_MEDIA_PROMPTS=$((EXECUTED_MEDIA_PROMPTS + 1))
        local prompt_started
        prompt_started="$(python3 -c 'import time;print(time.time())')"
        send ai.cruxwing.livetest.runPrompt id advice \
            surfaceID "$RUN_ID:$cond:apply-to-project"
        event media-prompt "$cond" "id=advice type=project-application started=$prompt_started"
        local attempt
        for attempt in $(seq 1 "$MEDIA_AI_TIMEOUT"); do
            dump 4 || true
            if python3 - "$STATE_JSON" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
terminal = state.get("aiResponseStatus") in {
    "succeeded", "failed", "cancelled", "superseded"
}
raise SystemExit(0 if state.get("aiResponsePromptID") == "advice"
                 and state.get("aiStreaming") is False and terminal else 1)
PY
            then
                break
            fi
            sleep 1
        done
        dump || true
        local media_terminal_detail
        media_terminal_detail="$(python3 - "$STATE_JSON" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
started, completed = state.get("aiResponseStartedAt"), state.get("aiResponseCompletedAt")
latency = (round(completed - started, 3)
           if isinstance(started, (int, float)) and isinstance(completed, (int, float))
           and completed >= started else None)
print(f"id={state.get('aiResponsePromptID')} status={state.get('aiResponseStatus')} latency={latency}")
PY
)"
        event flow "$cond" "media-prompt-terminal $media_terminal_detail"
        { [ "$(jqv aiStreaming)" = "False" ] &&
          [ "$(jqv aiResponsePromptID)" = "advice" ] &&
          [ "$(jqv aiResponseStatus)" = "succeeded" ]; }
        check "$cond project-application prompt terminal" $? \
            "id=$(jqv aiResponsePromptID) status=$(jqv aiResponseStatus) chars=$(jqv aiResponseChars)"
        checkpoint "$cond" project-application-response || true
    fi

    local active_final="$base.active-final.state.json"
    dump_to "$active_final" || check "$cond active final capture" 1 "state dump failed"
    stop_recording_if_active || {
        check "$cond recording teardown" 1 "did not reach idle with correlated call_ended"
        return
    }
    sleep 2
    dump || { check "$cond final capture" 1 "post-stop state dump failed"; return; }
    cp "$STATE_JSON" "$base.state.json"
    checkpoint "$cond" final || true

    python3 - "$base.state.json" "$kind" <<'PY' >/dev/null 2>&1
import json, sys
state = json.load(open(sys.argv[1]))
kind = sys.argv[2]
expected = kind.replace("_", " ").title()
ok = (state.get("isRecording") is False
      and state.get("recordingContextSelection") == kind
      and state.get("effectiveRecordingContext") == expected
      and state.get("microphonePermissionGranted") is True
      and state.get("screenRecordingPermissionGranted") is True
      and int(state.get("systemEntries") or 0) > 0)
raise SystemExit(0 if ok else 1)
PY
    check "$cond final capture state" $? \
        "manual type retained; permissions granted; system transcript committed"

    local score="$base.score.json"
    python3 "$LIB/score_transcript.py" --truth "$base.truth.json" \
        --hyp "$base.state.json" --playback-start "$playback_started" \
        --source system --out "$score" >/dev/null 2>&1
    local score_rc=$?
    check "$cond transcript scorer completed" "$score_rc" "$score"
    if [ "$score_rc" = "0" ]; then
        local wer recall dup echo_rate latency_p95 missing
        wer="$(python3 -c "import json;print(json.load(open('$score'))['wer'])")"
        recall="$(python3 -c "import json;print(json.load(open('$score'))['termRecall'])")"
        dup="$(python3 -c "import json;print(json.load(open('$score'))['duplicationRate'])")"
        echo_rate="$(python3 -c "import json;print(json.load(open('$score'))['crossTrackEchoRate'])")"
        latency_p95="$(python3 -c "import json;print(json.load(open('$score')).get('latencySecondsP95',-1))")"
        missing="$(python3 -c "import json;print(', '.join(json.load(open('$score'))['missingTerms']) or '-')")"
        python3 -c "import sys;sys.exit(0 if $wer <= $MAX_WER_MEDIA else 1)"
        check "$cond WER" $? "$wer (bar $MAX_WER_MEDIA)"
        python3 -c "import sys;sys.exit(0 if $recall >= $MIN_MEDIA_TERM_RECALL else 1)"
        check "$cond vocabulary" $? "recall $recall, missing: $missing"
        python3 -c "import sys;sys.exit(0 if $dup <= $MAX_DUPLICATION else 1)"
        check "$cond duplication" $? "$dup (bar $MAX_DUPLICATION)"
        python3 -c "import sys;sys.exit(0 if $echo_rate <= $MAX_CROSS_TRACK_ECHO else 1)"
        check "$cond cross-track echo" $? "$echo_rate (bar $MAX_CROSS_TRACK_ECHO)"
        python3 -c "import sys;sys.exit(0 if $latency_p95 >= 0 and $latency_p95 <= $MAX_TRANSCRIPT_LATENCY_P95 else 1)"
        check "$cond transcript latency p95" $? \
            "${latency_p95}s (bar ${MAX_TRANSCRIPT_LATENCY_P95}s)"
    fi

    if [ "$kind" = "tutorial" ]; then
        response_report="$base.media-response.json"
        python3 "$LIB/verify_media_recording.py" response \
            --state "$base.state.json" --truth "$base.truth.json" \
            --out "$response_report" >/dev/null 2>&1
        local response_rc=$?
        check "$cond media-aware project answer" "$response_rc" \
            "successful advice lifecycle, tutorial grounding, project application, no invented meeting artifacts ($response_report)"
    fi

    local first_line_latency
    first_line_latency="$(python3 - "$base.state.json" "$playback_started" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
started = float(sys.argv[2])
lines = [row for row in state.get("transcriptFull", [])
         if row.get("source") == "system" and isinstance(row.get("at"), (int, float))]
print(round(lines[0]["at"] - started, 2) if lines else -1)
PY
)"
    if [ -s "$score" ]; then
        python3 - "$score" "$continuity_report" "$response_report" \
            "$OUTDIR/report.json" "$cond" "$kind" "$first_line_latency" <<'PY'
import json, os, sys
score_path, continuity_path, response_path, report_path, cond, kind, latency = sys.argv[1:]
report = json.load(open(report_path)) if os.path.exists(report_path) else {}
entry = json.load(open(score_path))
entry["recordingType"] = kind
entry["firstLineLatencySeconds"] = float(latency)
entry["contextContinuity"] = json.load(open(continuity_path)) if os.path.exists(continuity_path) else None
if response_path and os.path.exists(response_path):
    entry["mediaResponse"] = json.load(open(response_path))
report.setdefault("mediaConditions", {})[cond] = entry
json.dump(report, open(report_path, "w"), indent=2, sort_keys=True)
PY
    fi
}

# ── conditions ──────────────────────────────────────────────────────────────
for cond in $CONDITIONS; do
    case "$cond" in
        clean)   run_condition clean ;;
        noisy)   run_condition noisy --noise 0.25 ;;
        fast)    run_condition fast --tempo 1.25 ;;
        offline)
            echo; echo "──────── condition: offline ────────"
            # Never disable the developer Mac's network from an unattended
            # test. Offline + timeout are injected deterministically by
            # BackendGatewayTests and server fallback tests; this live runner
            # records the selected real network path in network.log.
            skip "offline live transport" "covered by injected URLProtocol failures; machine-wide network left intact"
            ;;
        *) skip "$cond" "unknown condition" ;;
    esac
done

for media in $MEDIA_CONDITIONS; do
    case "$media" in
        tutorial)
            run_media_condition tutorial "$LIB/tutorial_script.json" video
            ;;
        video)
            run_media_condition video "$LIB/generic_video_script.json" tutorial
            ;;
        *) skip "media $media" "unknown media condition" ;;
    esac
done

if [ "$EXECUTED_CONDITIONS" -eq 0 ] && [ "$EXECUTED_MEDIA_CONDITIONS" -eq 0 ]; then
    check "suite executable condition" 1 \
        "no playback ran (choose clean/noisy/fast and/or tutorial/video; offline transport is injected in unit tests)"
fi

# ── console + verdict ───────────────────────────────────────────────────────
/usr/bin/log show --style ndjson --info --start "@$RUN_STARTED_EPOCH" \
    --process "$APP_PID" --predicate 'subsystem == "ai.wheespr.meetgpt"' \
    >"$OUTDIR/console.log" 2>"$OUTDIR/console-logger.stderr.log"
grep -cE "convertFail=[1-9]|empty transcription" "$OUTDIR/console.log" >/dev/null 2>&1 && \
    note "audio-pipeline warnings present — see $OUTDIR/console.log"
[ -n "$LOG_PID" ] && kill "$LOG_PID" >/dev/null 2>&1 || true
[ -n "$LOG_PID" ] && wait "$LOG_PID" 2>/dev/null || true
LOG_PID=""
python3 "$LIB/normalize_unified_log.py" \
    --sanitize --input "$NETWORK_RAW_LOG" --out "$NETWORK_LOG"
check "network stream normalized" $? "macOS JSON-array stream converted to one event per line"
python3 - "$NETWORK_LOG" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1]) as handle:
    rows = [line for line in handle if line.strip()]
for row in rows:
    json.loads(row)
raise SystemExit(0 if rows else 1)
PY
check "network artifact valid NDJSON" $? "complete parseable event stream; diagnostics separated"
python3 - "$NETWORK_LOG" "$OUTDIR/network-summary.json" "$EXECUTED_CONDITIONS" \
    "$EXECUTED_MEDIA_PROMPTS" <<'PY'
import json, re, sys
source, out = sys.argv[1:3]
condition_count, media_prompt_count = map(int, sys.argv[3:5])
events = [json.loads(line) for line in open(source) if line.strip()]
requests = {}
promo_requests = {}
transcription_events = 0
connector_events = 0
allowed_fields = {
    "network": {
        "category", "event", "requestID", "timestamp", "method",
        "pathTemplate", "status", "durationMilliseconds", "requestBytes",
        "responseBytes", "outputBytes", "errorCategory",
    },
    "transcription": {
        "category", "event", "timestamp", "source", "inputBytes", "reason",
    },
    "connector": {
        "category", "event", "requestID", "timestamp", "operation",
        "providerID", "providerCategory", "toolClass", "cacheResult",
        "cacheAgeMilliseconds", "status", "durationMilliseconds", "retryCount",
        "retryEligible",
    },
}
schema_violations = []
for event in events:
    category = event.get("category")
    if category == "transcription":
        transcription_events += 1
    elif category == "connector":
        connector_events += 1
    extra = set(event) - allowed_fields.get(category, set())
    if category not in allowed_fields or extra:
        schema_violations.append({"category": category, "extraFields": sorted(extra)})
    name = str(event.get("event") or "")
    request_id = event.get("requestID")
    match = re.fullmatch(r"backend_chat_(prepare|start|response|complete|failed)", name)
    if match and isinstance(request_id, str):
        stage = match.group(1)
        requests.setdefault(request_id, set()).add(stage)
    promo_match = re.fullmatch(r"promo_redeem_(start|response|complete|failed)", name)
    if promo_match and isinstance(request_id, str):
        stage = promo_match.group(1)
        promo_requests.setdefault(request_id, {})[stage] = event
terminal = {request_id: stages for request_id, stages in requests.items()
            if stages & {"complete", "failed"}}
complete_lifecycles = {request_id: stages for request_id, stages in terminal.items()
                       if "start" in stages and "prepare" in stages}
promo_terminal = {
    request_id: stages for request_id, stages in promo_requests.items()
    if "complete" in stages or "failed" in stages
}
promo_complete_lifecycles = {}
for request_id, stages in promo_terminal.items():
    complete = stages.get("complete")
    if ("start" in stages and "response" in stages and isinstance(complete, dict)
            and isinstance(complete.get("durationMilliseconds"), int)
            and complete.get("status") in range(200, 300)
            and complete.get("pathTemplate") in {
                "/api/promo/device-redeem", "/api/subscribe"
            }):
        promo_complete_lifecycles[request_id] = stages
raw = open(source, encoding="utf-8").read().casefold()
canaries = ["authorization:", "bearer ", "dev-unlimited-local",
            "what decision is most at risk", "oauth", "cookie", "transcriptfull",
            "system_chars", "user_chars", "image_count", '"host"', '"detail"',
            '"processimagepath"', '"bootuuid"', '"backtrace"']
leaks = [value for value in canaries if value in raw]
summary = {
    "eventCount": len(events),
    "requestCount": len(requests),
    "terminalRequestCount": len(terminal),
    "completeLifecycleCount": len(complete_lifecycles),
    "promoRedemptionRequestCount": len(promo_requests),
    "promoRedemptionTerminalRequestCount": len(promo_terminal),
    "promoRedemptionCompleteLifecycleCount": len(promo_complete_lifecycles),
    "transcriptionEventCount": transcription_events,
    "connectorEventCount": connector_events,
    "contentCanaryLeaks": leaks,
    "schemaViolations": schema_violations,
    "minimumTerminalRequests": condition_count * 2 + media_prompt_count,
}
json.dump(summary, open(out, "w"), indent=2, sort_keys=True)
raise SystemExit(0 if len(complete_lifecycles) >= condition_count * 2 + media_prompt_count
                 and len(promo_complete_lifecycles) >= 1
                 and transcription_events > 0 and not leaks
                 and not schema_violations else 1)
PY
check "network lifecycle artifact" $? \
    "closed-schema assistant and promo request lifecycles, transcription, and connector events; promo-code canary clean"

python3 - "$EVENTS_JSONL" "$EXECUTED_CONDITIONS" <<'PY' >/dev/null 2>&1
import json, sys
path, conditions = sys.argv[1], int(sys.argv[2])
rows = [json.loads(line) for line in open(path) if line.strip()]
prompt_rows = [row for row in rows if row.get("kind") == "prompt"]
for row in rows:
    if not isinstance(row.get("at"), (int, float)) or not row.get("kind"):
        raise SystemExit(1)
raise SystemExit(0 if len(prompt_rows) == conditions * 5 else 1)
PY
check "event timeline complete" $? \
    "$((EXECUTED_CONDITIONS * 5)) scheduled prompt events plus state/flow lifecycle rows"

python3 - "$SYNTHETIC_EVIDENCE_JSONL" "$OUTDIR" \
    "$EXECUTED_CONDITIONS" <<'PY' >/dev/null 2>&1
import json, os, stat, sys
path, root, conditions = sys.argv[1], sys.argv[2], int(sys.argv[3])
root_stat = os.stat(root)
file_stat = os.stat(path)
if root_stat.st_uid != os.getuid() or stat.S_IMODE(root_stat.st_mode) != 0o700:
    raise SystemExit(1)
if file_stat.st_uid != os.getuid() or stat.S_IMODE(file_stat.st_mode) != 0o600:
    raise SystemExit(1)
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
terminal = [row for row in rows if row.get("checkpoint") == "blind-spot-terminal"]
prompt = [row for row in rows if str(row.get("checkpoint") or "").startswith("prompt-")]
expected_goal = ("Identify the highest-impact missing decision, risk, or unsupported "
                 "assumption in the Project Falcon rollout, then give one concrete next question.")
required_lists = ["transcriptFull", "aiHistoryFull", "aiExchangeEvidenceFull",
                  "workflowStepsFull", "suggestionsFull"]
valid = (
    len(terminal) == conditions
    and len(prompt) >= conditions * 5
    and all(row.get("callGoal") == expected_goal
            and row.get("effectiveCallGoal") == expected_goal
            and all(isinstance(row.get(key), list) for key in required_lists)
            and isinstance(row.get("blindSpot"), dict)
            for row in terminal)
)
raise SystemExit(0 if valid else 1)
PY
check "owner-only full synthetic evidence" $? \
    "prompt/workflow/transcript/response checkpoints in $SYNTHETIC_EVIDENCE_JSONL (0600 under 0700 root)"

python3 - "$OUTDIR/dev-call-diagnostics" "$EXECUTED_CONDITIONS" \
    "$EXECUTED_MEDIA_CONDITIONS" <<'PY' >/dev/null 2>&1
import json, os, re, stat, sys
directory = sys.argv[1]
conditions, media_conditions = map(int, sys.argv[2:4])
directory_stat = os.stat(directory)
if (not stat.S_ISDIR(directory_stat.st_mode)
        or directory_stat.st_uid != os.getuid()
        or stat.S_IMODE(directory_stat.st_mode) != 0o700):
    raise SystemExit(1)
files = sorted(
    os.path.join(directory, name) for name in os.listdir(directory)
    if re.fullmatch(r"call-[0-9a-f-]+\.jsonl", name))
if len(files) != conditions + media_conditions:
    raise SystemExit(1)
meeting_required = {
    "call_started", "assistant_request", "workflow_step",
    "assistant_terminal", "backend_chat_terminal",
    "blind_spot_request", "blind_spot_terminal", "call_ended",
    "connected_glossary_review",
}
media_required = {"call_started", "recording_context_changed", "call_ended"}
tutorial_required = media_required | {
    "assistant_request", "workflow_step", "assistant_terminal", "backend_chat_terminal",
}
secret_patterns = [
    re.compile(r"(?i)Bearer\s+(?!\[REDACTED\])\S+"),
    re.compile(r"(?i)\b(?:sk-(?:proj-)?|xox[baprs]-|gh[pousr]_|AIza|ya29\.)[A-Za-z0-9._-]{6,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]
meeting_files = 0
media_files = 0
for path in files:
    file_stat = os.stat(path)
    if (not stat.S_ISREG(file_stat.st_mode)
            or file_stat.st_uid != os.getuid()
            or stat.S_IMODE(file_stat.st_mode) != 0o600
            or file_stat.st_size <= 0 or file_stat.st_size > 4 * 1024 * 1024):
        raise SystemExit(1)
    raw = open(path, encoding="utf-8").read()
    if any(pattern.search(raw) for pattern in secret_patterns):
        raise SystemExit(1)
    rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if not rows:
        raise SystemExit(1)
    events = {row.get("event") for row in rows}
    first_fields = rows[0].get("fields") if isinstance(rows[0].get("fields"), dict) else {}
    recording_context = first_fields.get("recordingContext")
    if recording_context == "Meeting":
        meeting_files += 1
        required = meeting_required
    elif recording_context == "Tutorial":
        media_files += 1
        required = tutorial_required
        if "blind_spot_request" in events:
            raise SystemExit(1)
    elif recording_context == "Video":
        media_files += 1
        required = media_required
        if "blind_spot_request" in events or "assistant_request" in events:
            raise SystemExit(1)
    else:
        raise SystemExit(1)
    if not required.issubset(events):
        raise SystemExit(1)
    sequences = [row.get("sequence") for row in rows]
    if sequences != list(range(1, len(rows) + 1)):
        raise SystemExit(1)
    call_ids = {row.get("callID") for row in rows}
    session_ids = {row.get("sessionID") for row in rows}
    if len(call_ids) != 1 or not next(iter(call_ids), "") or len(session_ids) != 1:
        raise SystemExit(1)
raise SystemExit(0 if meeting_files == conditions
                 and media_files == media_conditions else 1)
PY
check "dev call prompt/workflow diagnostics" $? \
    "$((EXECUTED_CONDITIONS + EXECUTED_MEDIA_CONDITIONS)) bounded per-recording JSONL traces; 0700/0600, correlated, type-aware, complete, token-free"
event suite all "passed=${#PASS[@]} failed=${#FAIL[@]} skipped=${#SKIP[@]}"

python3 - "$OUTDIR/report.json" "${#PASS[@]}" "${#FAIL[@]}" "${#SKIP[@]}" "$SEED" <<'PY'
import json, os, sys
path, passed, failed, skipped, seed = sys.argv[1:]
report = json.load(open(path)) if os.path.exists(path) else {}
report["execution"] = {
    "passed": int(passed), "failed": int(failed), "skipped": int(skipped),
    "seed": int(seed), "completed": int(failed) == 0,
}
json.dump(report, open(path, "w"), indent=2, sort_keys=True)
PY

echo
echo "════════ VIDEO TEST: ${#PASS[@]} passed · ${#FAIL[@]} failed · ${#SKIP[@]} skipped ════════"
echo "artifacts: $OUTDIR"
[ -f "$OUTDIR/report.json" ] && python3 -c "
import json
r = json.load(open('$OUTDIR/report.json'))
for cond, m in sorted(r.get('conditions', {}).items()):
    quality = m.get('responseQuality', {}).get('scores', {}).get('overall')
    quality_text = f' · response {quality:.2f}' if quality is not None else ''
    blind = m.get('blindSpot') or {}
    blind_text = (f' · Blind Spot {blind.get(\"outcome\")} '
                  f'{blind.get(\"provider\")}/{blind.get(\"model\")} '
                  f'{blind.get(\"chargedCredits\")}cr') if blind else ''
    print(f\"  {cond:8s} WER {m['wer']:.3f} · terms {m['termRecall']:.2f} · echo {m.get('crossTrackEchoRate',-1):.2f} · spk {m['speakerAccuracy']:.2f} · p95 {m.get('latencySecondsP95',-1):.1f}s · first line +{m['firstLineLatencySeconds']}s{quality_text}{blind_text}\")
for cond, m in sorted(r.get('mediaConditions', {}).items()):
    response = m.get('mediaResponse') or {}
    response_text = ' · project answer pass' if response.get('ok') else ''
    print(f\"  {cond:14s} WER {m['wer']:.3f} · terms {m['termRecall']:.2f} · echo {m.get('crossTrackEchoRate',-1):.2f} · p95 {m.get('latencySecondsP95',-1):.1f}s · first line +{m['firstLineLatencySeconds']}s{response_text}\")
"
[ "${#FAIL[@]}" -gt 0 ] && { printf 'failed: %s\n' "${FAIL[*]}"; exit 1; }
exit 0
