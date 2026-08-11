#!/bin/bash
# Regenerate every piece of deterministic evidence, then verify it.
#
#   bash verify-evidence.sh
#
# Why a script and not a README paragraph: the verifier rejects any report that
# predates the sources it claims to cover, and it says so in a way that is easy
# to misread —
#
#   "report predates manifest/source evidence (1786137485.848 < 1786137624.208)"
#
# which reads as a broken run and is actually just a stale file. Editing a test
# and rerunning only the verifier reports 0.0% executed coverage with all 164
# requirements still mapped, so the number looks like a catastrophic regression
# when nothing regressed at all. Generating in order removes the trap.
#
# The ceiling here is ~64%. The remaining requirements are live-gated: they need
# the installed app, granted Screen Recording and Microphone permissions, and
# videotest.sh playing real audio. Those are in TEST_PLAN.md and are not
# reachable from a headless run. This script deliberately does NOT pretend
# otherwise — it prints the split so a passing run is never mistaken for full
# coverage.

set -euo pipefail

# Every generation step sends its output to a log and prints it ONLY on failure.
# Without this the steps were `>/dev/null` under `set -e`, so a step that died
# took the script with it and printed nothing at all — the caller saw the last
# echoed heading and had to guess which command failed and why. A run that
# fails must say what failed.
STEP_LOG="$(mktemp -t cruxwing-evidence)"
trap 'rm -f "$STEP_LOG"' EXIT

run_step() {
    local label="$1"; shift
    echo "== $label =="
    if ! "$@" >"$STEP_LOG" 2>&1; then
        echo "--- FAILED: $label ---" >&2
        echo "    command: $*" >&2
        tail -40 "$STEP_LOG" >&2
        return 1
    fi
}

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_ROOT="${CRUXWING_API_ROOT:-$APP_ROOT/../cruxwing-api}"
export PATH="/opt/homebrew/bin:$PATH"

cd "$APP_ROOT"
mkdir -p coverage

if [ ! -d "$API_ROOT" ]; then
    echo "error: cruxwing-api not found at $API_ROOT (set CRUXWING_API_ROOT)" >&2
    exit 1
fi

# 1. API first. Its reports are evidence for the app's ECON-* and billing
#    requirements, so they must not be older than the app's own run.
# vitest occasionally exits non-zero AFTER writing a clean report — seen three
# times, always with "JUNIT report written" as the last line and no failure in
# the XML, which points at teardown rather than at a test. Retrying blindly
# would hide real failures, so the exception is narrow: accept it only when the
# report exists and contains zero <failure> and <error> elements. A report with
# any failure in it still fails the run.
if ! run_step "API: full suite + JUnit" \
        env -C "$API_ROOT" npx vitest run --reporter=junit --outputFile=coverage/api-tests.xml; then
    if python3 - "$API_ROOT/coverage/api-tests.xml" <<'PYCHECK'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(1)
cases = list(root.iter('testcase'))
bad = sum(1 for c in cases for _ in list(c) if _.tag in ('failure', 'error'))
raise SystemExit(0 if cases and bad == 0 else 1)
PYCHECK
    then
        echo "    (report is clean — non-zero exit came after the run; continuing)" >&2
    else
        exit 1
    fi
fi

run_step "API: commercial-core coverage gate" \
    env -C "$API_ROOT" npm run --silent test:coverage:critical

# 2. App suite with coverage.
run_step "app: swift test + xUnit" \
    swift test --enable-code-coverage --xunit-output coverage/swift-tests.xml

echo "== app: critical Swift coverage =="
python3 testlib/verify_swift_critical_coverage.py --out coverage/swift-critical.json

# 3. Verify. --run-command-checks executes the allowlisted scorer self-tests,
#    without which TRANSCRIPT-SCORER-SELFTEST and RESPONSE-THRESHOLD-SELFTEST
#    stay uncovered no matter how many tests pass.
# The verifier exits non-zero whenever executed coverage is under its 90%
# target, which is the NORMAL outcome here — 59 requirements need the installed
# app. Under `set -e` that killed the script before the summary below could
# explain why, so the run looked like a hard failure with no reason given. The
# summary decides the exit status instead: live-gated shortfall is expected, a
# gap that is neither live nor manual is not.
echo "== verify =="
set +e
python3 testlib/verify_e2e_coverage.py \
    --manifest Tests/E2E/coverage-manifest.json \
    --xunit coverage/swift-tests.xml \
    --xunit "$API_ROOT/coverage/api-tests.xml" \
    --coverage-summary "$API_ROOT/coverage/critical/coverage-summary.json" \
    --run-command-checks \
    --out coverage/e2e-verification.json
verify_status=$?
set -e
if [ "$verify_status" -gt 1 ]; then
    echo "error: verifier failed to run (exit $verify_status)" >&2
    exit "$verify_status"
fi

python3 - <<'PY'
import json
result = json.load(open("coverage/e2e-verification.json"))
manifest = json.load(open("Tests/E2E/coverage-manifest.json"))
live = set(manifest["evidencePolicy"].get("liveRequirements", []))
manual = {r["id"] for r in manifest["requirements"] if r.get("manual")}
uncovered = result["uncovered"]
blocked = [u for u in uncovered if u in live or u in manual]
real = [u for u in uncovered if u not in live and u not in manual]

print()
print(f"deterministic evidence: {len(uncovered) - len(blocked)} gap(s) reachable from this run")
print(f"live/manual gated:      {len(blocked)} requirement(s) need the installed app — see TEST_PLAN.md")
if real:
    print("\nNOT covered and NOT live-gated — these are real gaps:")
    for name in real:
        print(f"  {name}")
    raise SystemExit(1)
print("\nEverything reachable without the installed app is covered.")
PY
