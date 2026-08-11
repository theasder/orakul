#!/bin/bash
# Live end-to-end test of the REAL installed app — run after each change:
#
#   bash mac/livetest.sh              # build + install + run the scenario
#   SKIP_BUILD=1 bash mac/livetest.sh # scenario only (app already installed)
#
# Scenario: launch the app -> start recording -> play a scripted "call"
# through the speakers (`say`; the system-audio capture hears it exactly like
# meeting audio) -> press prompt buttons -> read state snapshots + persisted
# heartbeat logs -> print a PASS/FAIL analysis.
#
# Needs: a dev build (livetest hooks are baked out of dist builds), mic +
# Screen Recording permission already granted, provider key for the AI step.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Cruxwing.app"
STATE_JSON="/tmp/cruxwing-livetest-state.json"
SPEAK_SECONDS_MIN=26          # two 6s chunks per source + margin
AI_TIMEOUT=90
MARKER_BUDGET="forty thousand"     # must appear in the transcript
MARKER_NAME="Falcon"

PASS=()
FAIL=()
note()  { printf '   %s\n' "$*"; }
check() { # check <name> <ok:0/1> <detail>
    if [ "$2" = "0" ]; then PASS+=("$1"); printf '✅ %s — %s\n' "$1" "$3"
    else FAIL+=("$1"); printf '❌ %s — %s\n' "$1" "$3"; fi
}
send() { # send <notification> [key value] — JXA: no python deps needed
    if [ $# -ge 3 ]; then
        osascript -l JavaScript \
            -e "ObjC.import('Foundation');" \
            -e "const info = \$.NSMutableDictionary.alloc.init;" \
            -e "info.setObjectForKey(\$('$3'), \$('$2'));" \
            -e "\$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(\$('$1'), \$(), info, true);" >/dev/null
    else
        osascript -l JavaScript \
            -e "ObjC.import('Foundation');" \
            -e "\$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(\$('$1'), \$(), \$(), true);" >/dev/null
    fi
}
dump() { rm -f "$STATE_JSON"; send ai.cruxwing.livetest.dumpState path "$STATE_JSON"
         for _ in $(seq 1 20); do [ -f "$STATE_JSON" ] && break; sleep 0.25; done
         [ -f "$STATE_JSON" ] || { echo "!! no state dump — is the dev app running?"; return 1; }; }
jqv() { python3 -c "import json,sys;d=json.load(open('$STATE_JSON'));print(d$1)"; }

# ── 0 · build + launch ───────────────────────────────────────────────────────
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo ">> building + installing"
    bash "$ROOT/build.sh" >/tmp/livetest-build.log 2>&1 || { echo "!! build failed — see /tmp/livetest-build.log"; exit 2; }
fi
osascript -e 'quit app "Cruxwing"' >/dev/null 2>&1; sleep 2
TEST_START="$(date '+%Y-%m-%d %H:%M:%S')"
open "$APP"; sleep 6
dump || exit 2
check "app responds to hooks" $? "state dump received"

# ── 1 · create the call ─────────────────────────────────────────────────────
echo ">> starting recording"
send ai.cruxwing.livetest.toggleRecording
sleep 5
dump
[ "$(jqv "['isRecording']")" = "True" ]; check "recording started" $? "status=$(jqv "['status']")"

# ── 2 · speak (the scripted meeting, through the speakers) ──────────────────
echo ">> speaking the scripted call (~${SPEAK_SECONDS_MIN}s)"
say -r 175 "Welcome everyone to the project ${MARKER_NAME} planning call. \
The budget for project ${MARKER_NAME} is ${MARKER_BUDGET} dollars, approved by finance last week. \
Maria will send the updated contract to the client by Friday. \
There is one open risk: the vendor has not confirmed the delivery date for the hardware. \
Let us also decide that the launch moves to the second week of September. \
Please prepare your status updates for the next call." &
SAY_PID=$!
sleep "$SPEAK_SECONDS_MIN"; wait "$SAY_PID" 2>/dev/null
sleep 10   # let the last chunk transcribe

dump
TC="$(jqv "['transcriptCount']")"; SYS="$(jqv "['systemEntries']")"
[ "${TC:-0}" -gt 0 ]; check "transcript populated" $? "$TC entries ($SYS system, $(jqv "['micEntries']") mic)"
# The played call MUST also arrive via the system-audio (SCK) track — with
# headphones it is the ONLY path. Known failure being chased: SCK delivering
# digital silence (see sysaudio: lines in the analysis below).
[ "${SYS:-0}" -gt 0 ]; check "system-audio track captured" $? "$SYS system entries"
python3 -c "
import json,sys
d=json.load(open('$STATE_JSON'))
text=' '.join(d['transcriptTail']).lower()
sys.exit(0 if ('falcon' in text or 'forty' in text or 'maria' in text) else 1)"
check "scripted speech recognized" $? "tail: $(jqv "['transcriptTail'][-1:]" 2>/dev/null | head -c 120)"

# Language consistency: the call was SPOKEN in English, so the transcript we
# show must be English script — catches Whisper language drift (e.g. English
# speech surfacing as Cyrillic when the engine language is 'multi').
LANG_DETAIL="$(python3 -c "
import json, sys, unicodedata
d = json.load(open('$STATE_JSON'))
letters = [c for c in ' '.join(d['transcriptTail']) if c.isalpha()]
if not letters:
    print('no letters in transcript'); sys.exit(1)
latin = sum(1 for c in letters if 'LATIN' in unicodedata.name(c, ''))
pct = round(100 * latin / len(letters))
print(f'{pct}% latin script across {len(letters)} letters (spoken: en)')
sys.exit(0 if pct >= 80 else 1)")"
check "transcript language matches spoken language" $? "$LANG_DETAIL"

# ── 3 · press prompt buttons ────────────────────────────────────────────────
for BUTTON in summary tasks; do
    echo ">> pressing '$BUTTON'"
    send ai.cruxwing.livetest.runPrompt id "$BUTTON"
    OK=1
    for _ in $(seq 1 "$AI_TIMEOUT"); do
        sleep 1; dump >/dev/null 2>&1 || continue
        STREAMING="$(jqv "['aiStreaming']")"; CHARS="$(jqv "['aiResponseChars']")"
        if [ "$STREAMING" = "False" ] && [ "${CHARS:-0}" -gt 0 ]; then OK=0; break; fi
    done
    ISERR="$(jqv "['aiResponseIsError']")"
    [ "$OK" = "0" ] && [ "$ISERR" = "False" ]; check "button '$BUTTON' answered" $? \
        "$(jqv "['aiResponseChars']") chars · head: $(jqv "['aiResponseHead'][:90]" | tr '\n' ' ')"
    [ "$ISERR" = "True" ] && note "error body: $(jqv "['aiResponseHead']")"
done

# ── 4 · stop + audio-pipeline analysis from persisted logs ──────────────────
echo ">> stopping recording"
send ai.cruxwing.livetest.toggleRecording; sleep 3
echo ">> analyzing persisted audio heartbeats since $TEST_START"
LOGS="$(log show --start "$TEST_START" --predicate 'subsystem == "ai.wheespr.meetgpt"' 2>/dev/null)"
echo "$LOGS" | grep -E "Mic tap:" | tail -2
echo "$LOGS" | grep -E "sysaudio:" | tail -3
FINAL="$(echo "$LOGS" | grep -E "chunker\[(mic|system)\] final" | tail -2)"
echo "$FINAL"
echo "$FINAL" | grep -q "convertFail=0"; check "no conversion failures" $? "chunker finals above"
EMPTY="$(echo "$LOGS" | grep -c "empty transcription result" || true)"
note "empty-transcription chunks: $EMPTY (a few are normal for silence)"

# ── verdict ─────────────────────────────────────────────────────────────────
echo
echo "════════ LIVE TEST: ${#PASS[@]} passed · ${#FAIL[@]} failed ════════"
[ "${#FAIL[@]}" -gt 0 ] && { printf 'failed: %s\n' "${FAIL[*]}"; exit 1; }
exit 0
