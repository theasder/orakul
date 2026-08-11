#!/bin/bash
# Edge-case test of the REAL installed app — the regression pack for every bug
# class reported from live calls. Complements livetest.sh (the happy path):
#
#   bash edgetest.sh              # build + install + run all edge scenarios
#   SKIP_BUILD=1 bash edgetest.sh # scenarios only (app already installed)
#
# Scenarios, each mapped to a shipped incident:
#   E1  cold launch + relaunch while running   (bundle-ID clash regression)
#   E2  empty / whitespace ask                 (must not start a run)
#   E3  ask while streaming                    ("message vanished" regression)
#   E4  cross-track echo duplicate             (mic hears the speakers)
#   E5  same-track near-copy duplicate         (chunked re-emission)
#   E6  legitimate repeat OUTSIDE the window   (must be KEPT — dedup too eager)
#   E7  quota latch                            ("credits over but still working")
#   E8  new call clears the latch + call state
#   E9  rapid record toggle                    (generation-guard race)
#   E10 quit + relaunch persistence            (session survives)
#
# Needs a dev build (hooks bake out of dist), and for E3 a reachable backend —
# E3 degrades to "terminal state reached" if the AI errors, which is itself the
# assertion: the app must END somewhere visible, never hang.
set -u
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Cruxwing.app"
OUTDIR="$(mktemp -d /tmp/cruxwing-edgetest.XXXXXX)"
chmod 700 "$OUTDIR"
STATE_JSON="$OUTDIR/state.json"
RUN_NONCE="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
RUN_STARTED_EPOCH="$(python3 -c 'import time; print(int(time.time()))')"

cleanup() {
    /bin/launchctl unsetenv CRUXWING_LIVETEST_NONCE >/dev/null 2>&1 || true
    /bin/launchctl unsetenv CRUXWING_LIVETEST_ARTIFACT_ROOT >/dev/null 2>&1 || true
    /bin/launchctl unsetenv CRUXWING_LIVETEST_STARTED_AT >/dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=(); FAIL=()
note()  { printf '   %s\n' "$*"; }
check() { if [ "$2" = "0" ]; then PASS+=("$1"); printf '✅ %s — %s\n' "$1" "$3"
          else FAIL+=("$1"); printf '❌ %s — %s\n' "$1" "$3"; fi; }

send() { # send <notification> [key value]...  (JXA — no extra deps)
    local name="$1"; shift
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
dump() { rm -f "$STATE_JSON"; send ai.cruxwing.livetest.dumpState path "$STATE_JSON"
         for _ in $(seq 1 20); do [ -f "$STATE_JSON" ] && break; sleep 0.25; done
         [ -f "$STATE_JSON" ] || { echo "!! no state dump — dev app running?"; return 1; }; }
jqv() { python3 -c "import json;d=json.load(open('$STATE_JSON'));print(d$1)"; }
inject() { send ai.cruxwing.livetest.injectLine text "$1" source "$2" ${3:+speaker "$3"}; }
appwin() { osascript -e 'tell application "System Events" to count windows of process "Cruxwing"' 2>/dev/null || echo 0; }

# ── E1 · cold launch, then relaunch while running ───────────────────────────
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo ">> building + installing"
    bash "$ROOT/build.sh" >"$OUTDIR/build.log" 2>&1 || { echo "!! build failed — $OUTDIR/build.log"; exit 2; }
fi
osascript -e 'quit app "Cruxwing"' >/dev/null 2>&1; sleep 2
/bin/launchctl setenv CRUXWING_LIVETEST_NONCE "$RUN_NONCE"
/bin/launchctl setenv CRUXWING_LIVETEST_ARTIFACT_ROOT "$OUTDIR"
/bin/launchctl setenv CRUXWING_LIVETEST_STARTED_AT "$RUN_STARTED_EPOCH"
open "$APP"; sleep 6
dump || exit 2
check "E1a cold launch reaches idle" $? "status=$(jqv "['status']")"

# Entitle the APP's own session before any AI scenario. Without this the E3
# assertions grade a "401 Sign in to use your Free AI credits" body as an
# answer — green suite, zero coverage.
# shellcheck source=testlib/entitle.sh
source "$ROOT/testlib/entitle.sh"
send ai.cruxwing.livetest.redeem code "DEV-UNLIMITED-LOCAL"
sleep 3
entitle_or_warn
PIDS_BEFORE="$(pgrep -x MeetGPT | sort | tr '\n' ' ')"
open "$APP"; sleep 3   # relaunch while running — LaunchServices must reuse
PIDS_AFTER="$(pgrep -x MeetGPT | sort | tr '\n' ' ')"
[ "$PIDS_BEFORE" = "$PIDS_AFTER" ] && [ -n "$PIDS_BEFORE" ]
check "E1b relaunch reuses the running instance" $? "pids: ${PIDS_AFTER:-none}"
dump; [ "$(jqv "['status']")" != "" ]; check "E1c app still responds after relaunch" $? "hooks alive"

# ── E2 · empty and whitespace asks must not start a run ─────────────────────
send ai.cruxwing.livetest.ask text ""
send ai.cruxwing.livetest.ask text "   "
sleep 2; dump
[ "$(jqv "['aiStreaming']")" = "False" ] && [ "$(jqv "['aiResponseChars']")" = "0" ]
check "E2 empty ask starts nothing" $? "streaming=$(jqv "['aiStreaming']") chars=$(jqv "['aiResponseChars']")"

# ── E3 · ask while streaming: the second message must not vanish ────────────
send ai.cruxwing.livetest.ask text "First question: give a long answer about meeting preparation."
sleep 1   # let the first run enter streaming
send ai.cruxwing.livetest.ask text "Second question: what is two plus two?"
TERMINAL=1
for _ in $(seq 1 90); do
    sleep 1; dump >/dev/null 2>&1 || continue
    [ "$(jqv "['aiStreaming']")" = "False" ] && { TERMINAL=0; break; }
done
check "E3a run reaches a terminal state" $TERMINAL "streaming=$(jqv "['aiStreaming']")"
[ "$(jqv "['aiResponsePrompt']")" = "Second question: what is two plus two?" ]
check "E3b live prompt is the SECOND ask (not silently dropped)" $? "prompt: $(jqv "['aiResponsePrompt']" | head -c 60)"
# Only meaningful with an entitlement: unentitled, the "answer" is a 401 body
# and asserting on it proves nothing.
if [ "$ENTITLED" = "1" ]; then
    [ "$(jqv "['aiResponseIsError']")" = "False" ] && [ "$(jqv "['aiResponseChars']")" -gt 0 ]
    check "E3c the answer is real, not an error body" $? \
        "$(jqv "['aiResponseChars']") chars, error=$(jqv "['aiResponseIsError']")"
else
    printf '⏭️  E3c the answer is real — unentitled, would grade a 401 body\n'
fi
[ "$(jqv "['aiHistoryCount']")" -ge 0 ]
note "history=$(jqv "['aiHistoryCount']") (first turn archived if it had streamed text) · head: $(jqv "['aiResponseHead'][:80]" | tr '\n' ' ')"

# ── E4 · cross-track echo: same sentence on both tracks within seconds ──────
BASE_TC="$(jqv "['transcriptCount']")"
inject "we can ship the migration on friday afternoon" system "Speaker A"
sleep 1
inject "we can ship the migration on friday afternoon" mic
sleep 1; dump
GAIN=$(( $(jqv "['transcriptCount']") - BASE_TC ))
[ "$GAIN" = "1" ]; check "E4 speaker echo collapses to one line" $? "+$GAIN line(s) (want 1)"

# ── E5 · same-track near-copy (chunk boundary re-emission) ──────────────────
BASE_TC="$(jqv "['transcriptCount']")"
inject "the vendor has not confirmed the delivery date for the hardware" system "Speaker B"
sleep 1
inject "the vendor has not confirmed the delivery dates for the hardware" system "Speaker B"
sleep 1; dump
GAIN=$(( $(jqv "['transcriptCount']") - BASE_TC ))
[ "$GAIN" = "1" ]; check "E5 near-copy re-emission is dropped" $? "+$GAIN line(s) (want 1)"

# ── E6 · genuine repeat far outside the window must be KEPT ─────────────────
BASE_TC="$(jqv "['transcriptCount']")"
inject "let us circle back to the budget question now" system "Speaker A"
sleep 1; dump
FIRST_GAIN=$(( $(jqv "['transcriptCount']") - BASE_TC ))
note "waiting out the 14s dedup window before the genuine repeat…"
sleep 16
inject "let us circle back to the budget question now" system "Speaker A"
sleep 1; dump
TOTAL_GAIN=$(( $(jqv "['transcriptCount']") - BASE_TC ))
[ "$FIRST_GAIN" = "1" ] && [ "$TOTAL_GAIN" = "2" ]
check "E6 same sentence minutes apart is kept" $? "+$TOTAL_GAIN line(s) (want 2)"

# ── E7 · quota latch: watches stop, one visible notice ──────────────────────
send ai.cruxwing.livetest.latchQuota
sleep 1; dump
QM="$(jqv "['copilotQuotaMessage']")"
[ "$QM" != "None" ] && [ -n "$QM" ]; check "E7a latch is set from the 429" $? "message: $(echo "$QM" | head -c 70)"
case "$QM" in *"{"*) BAD=0;; *) BAD=1;; esac
[ "$BAD" = "1" ]; check "E7b notice is a sentence, not raw JSON" $? "no JSON envelope leaked"

# ── E8 · a new call clears the latch and per-call state ─────────────────────
send ai.cruxwing.livetest.newCall
sleep 2; dump
# JSONEncoder drops nil optionals entirely — an absent key IS the cleared state.
CLEARED="$(python3 -c "import json;d=json.load(open('$STATE_JSON'));print(d.get('copilotQuotaMessage'))")"
[ "$CLEARED" = "None" ]
check "E8a new call clears the quota latch" $? "copilotQuotaMessage=$CLEARED"
[ "$(jqv "['transcriptCount']")" = "0" ]
check "E8b new call starts with an empty transcript" $? "transcriptCount=$(jqv "['transcriptCount']")"

# ── E9 · rapid record toggling must settle cleanly ──────────────────────────
for _ in 1 2 3; do
    send ai.cruxwing.livetest.toggleRecording; sleep 1
    send ai.cruxwing.livetest.toggleRecording; sleep 1
done
sleep 4; dump
STATUS="$(jqv "['status']")"
[ "$(jqv "['isRecording']")" = "False" ] && { [ "$STATUS" = "idle" ] || [ "$STATUS" = "stopped" ]; }
check "E9 rapid start/stop settles" $? "status=$STATUS after 3 fast cycles"

# ── E10 · quit + relaunch: the call survives in the saved list ──────────────
# Launch deliberately starts a FRESH session; the previous call must come back
# as the newest SAVED session, not in the live transcript.
inject "persistence marker line about project falcon budget" system "Speaker A"
sleep 1
send ai.cruxwing.livetest.newCall     # startNewCall persists the outgoing call
sleep 2
osascript -e 'quit app "Cruxwing"' >/dev/null 2>&1; sleep 3
open "$APP"; sleep 6
if dump; then
    python3 -c "
import json,sys
d=json.load(open('$STATE_JSON'))
text=' '.join(d.get('latestSessionTail',[])).lower()
sys.exit(0 if 'falcon' in text else 1)"
    check "E10 relaunch keeps the call in saved sessions" $? \
        "saved=$(jqv "['savedSessionCount']") · latest tail carries the marker"
else
    check "E10 relaunch keeps the call in saved sessions" 1 "no dump after relaunch"
fi

# ── E11 · call attribution against the REAL process list ────────────────────
# The unit suite pins the ranking; this confirms the bundle ids match what the
# vendors actually ship. Reported bug: a new Zoom conference was attributed to
# a Telegram that had been running in the background since login.
dump
ATTRIB="$(python3 -c "import json;print(json.load(open('$STATE_JSON')).get('commAppAttribution'))")"
ZOOM_RUNNING=0; pgrep -x "zoom.us" >/dev/null 2>&1 && ZOOM_RUNNING=1
TG_RUNNING=0; pgrep -f "Telegram" >/dev/null 2>&1 && TG_RUNNING=1
if [ "$ZOOM_RUNNING" = "1" ]; then
    [ "$ATTRIB" = "Zoom" ]
    check "E11 a running Zoom wins attribution" $? \
        "attributed to '$ATTRIB' (telegram running: $TG_RUNNING)"
elif [ "$TG_RUNNING" = "1" ]; then
    [ "$ATTRIB" = "Telegram" ]
    check "E11 messenger attributed when no meeting app runs" $? "attributed to '$ATTRIB'"
else
    printf '⏭️  E11 call attribution — no comm app running; open Zoom and re-run to check live\n'
fi

# ── verdict ─────────────────────────────────────────────────────────────────
echo
echo "════════ EDGE TEST: ${#PASS[@]} passed · ${#FAIL[@]} failed ════════"
echo "artifacts: $OUTDIR"
[ "${#FAIL[@]}" -gt 0 ] && { printf 'failed: %s\n' "${FAIL[*]}"; exit 1; }
exit 0
