#!/usr/bin/env bash
# Prepare a corpus for the lever experiment.
#
# The harness replays recorded calls through a token lever ON and OFF against a
# LIVE provider — so every session in the corpus is sent to that provider, twice
# per window. Your real history is therefore never used by default: you name the
# sessions one at a time, or you use the synthetic one.
#
# The corpus lives OUTSIDE the repository on purpose. A directory of real
# meeting transcripts inside a git working tree is one `git add -A` away from
# being published.
#
#   ./eval-corpus.sh synthetic [n]      # seed n invented sessions (default 4)
#   ./eval-corpus.sh list               # show what is in your real history
#   ./eval-corpus.sh add <uuid> [uuid…] # copy chosen sessions into the corpus
#   ./eval-corpus.sh status             # what the corpus holds now
#   ./eval-corpus.sh run [digest|order] # print the command to run
#
set -euo pipefail

CORPUS="${CRUXWING_EVAL_CORPUS_DIR:-$HOME/cruxwing-eval-corpus}/Sessions"
APP_SUPPORT="$HOME/Library/Application Support"

find_history() {
  for candidate in "$APP_SUPPORT/Cruxwing/Sessions" "$APP_SUPPORT/MeetGPT/Sessions"; do
    [ -d "$candidate" ] && { echo "$candidate"; return; }
  done
  return 1
}

cmd_list() {
  local history
  history="$(find_history)" || { echo "No session history found."; exit 1; }
  echo "History: $history"
  echo
  python3 - "$history" <<'PY'
import json, os, sys
root = sys.argv[1]
rows = []
for name in os.listdir(root):
    if not name.endswith(".json"):
        continue
    path = os.path.join(root, name)
    try:
        with open(path) as handle:
            session = json.load(handle)
    except Exception:
        continue
    rows.append((
        session.get("title") or "(untitled)",
        len(session.get("entries") or []),
        len(session.get("aiHistory") or []),
        os.path.getsize(path) // 1024,
        name[:-5],
    ))
rows.sort(key=lambda row: -row[2])
print(f"{'title':<40} {'lines':>6} {'asks':>5} {'KB':>6}  id")
print("-" * 88)
for title, lines, asks, kb, ident in rows:
    print(f"{title[:39]:<40} {lines:>6} {asks:>5} {kb:>6}  {ident}")
print()
print("'asks' is the replayable window count — sessions with 0 are useless here.")
print("Choose sessions you are willing to send to a model provider.")
PY
}

cmd_add() {
  [ "$#" -ge 1 ] || { echo "usage: ./eval-corpus.sh add <uuid> [uuid…]"; exit 1; }
  local history
  history="$(find_history)" || { echo "No session history found."; exit 1; }
  mkdir -p "$CORPUS"
  for id in "$@"; do
    local source="$history/$id.json"
    if [ -f "$source" ]; then
      cp "$source" "$CORPUS/"
      echo "added $id"
    else
      echo "missing $id — skipped"
    fi
  done
  cmd_status
}

cmd_synthetic() {
  # LeverExperiment.minimumWindowsForVerdict is 10 and each session yields 3
  # windows, so one session can only ever print "too few paired windows".
  # Four is the smallest count that can reach a verdict.
  local sessions="${1:-4}"
  mkdir -p "$CORPUS"
  python3 - "$CORPUS" "$sessions" <<'PY'
import json, os, sys, uuid
root = sys.argv[1]
session_count = max(1, int(sys.argv[2]))

# Long enough to cross digestActivationChars (12,000) so the digest lever has
# something to actually compress. Invented entirely — no real meeting content.
beats = [
    "The offline sync path is still failing its integration test.",
    "Roughly four percent of sessions touch that path at all.",
    "Support saw thirty tickets the last time a queue bug shipped.",
    "We could ship behind a flag and fix it in the point release.",
    "The flag would be off by default and on for the internal cohort.",
    "QA signed off on everything except that one path.",
    "Nobody has checked what happens to writes queued before the flag flips.",
    "The release train leaves on the twenty-second either way.",
]
# SessionStore decodes with .iso8601 — numeric timestamps fail silently
# (its `try?` swallows the error and the session vanishes from list()).
from datetime import datetime, timedelta, timezone
start = datetime(2024, 5, 1, 9, 0, 0, tzinfo=timezone.utc)
def iso(offset_seconds):
    return (start + timedelta(seconds=offset_seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
# Each session gets its own subject. Identical transcripts would make the
# comparison measure one prompt repeated, and a provider-side cache could
# serve the second run of every pair from the first.
subjects = [
    ("mobile beta go/no-go", "Decide whether the mobile beta ships this month"),
    ("pricing tier review", "Agree whether the mid tier keeps its seat limit"),
    ("incident post-mortem", "Decide what to change after the queue outage"),
    ("vendor renewal", "Decide whether to renew the transcription vendor"),
    ("hiring loop debrief", "Decide on the staff engineer candidate"),
    ("roadmap trim", "Cut two items from the quarter"),
]

total_chars = 0
for session_index in range(session_count):
    subject, goal = subjects[session_index % len(subjects)]
    entries = []
    for index in range(220):
        # The session index shifts which beat opens the call, so the
        # transcripts differ in content and not only in a trailing number.
        beat = beats[(index + session_index) % len(beats)]
        entries.append({
            "id": str(uuid.uuid4()).upper(),
            "source": "system" if index % 3 else "mic",
            "text": f"{beat} (turn {index})",
            "timestamp": iso(index * 12),
        })

    # SessionStore.fileURL builds "\(id.uuidString).json", which is UPPERCASE.
    # A lowercase filename still loads on case-insensitive APFS but will not on
    # a case-sensitive volume, so match the app exactly.
    session_id = str(uuid.uuid4()).upper()
    session = {
        "id": session_id,
        "title": f"Synthetic — {subject}",
        "startedAt": iso(0),
        "savedAt": iso(5400),
        "goal": goal,
        "entries": entries,
        "aiResponse": "",
        "digest": ("Earlier: the team weighed shipping the beta against an unfixed "
                   "offline sync path, and support's history of queue bugs."),
        "contextNotes": "Project brief: the beta ships behind a flag, off by default.",
        "aiHistory": [
            {"id": str(uuid.uuid4()).upper(), "prompt": "What did we decide?",
             "answer": "…", "at": iso(5400)},
            {"id": str(uuid.uuid4()).upper(), "prompt": "What is still unresolved?",
             "answer": "…", "at": iso(5401)},
            {"id": str(uuid.uuid4()).upper(), "prompt": "Summarize the call so far.",
             "answer": "…", "at": iso(5402)},
        ],
    }
    with open(os.path.join(root, f"{session_id}.json"), "w") as handle:
        json.dump(session, handle)
    total_chars += sum(len(entry["text"]) for entry in session["entries"])

windows = session_count * 3
print(f"wrote {session_count} session(s) of 220 lines "
      f"(~{total_chars // session_count} transcript chars each — the digest "
      f"activates above 12,000)")
print(f"{windows} replayable windows; a verdict needs 10 paired ones")
if windows < 10:
    print("NOTE: below the verdict threshold — seed more with "
          f"'./eval-corpus.sh synthetic 4'")
PY
  cmd_status
}

cmd_status() {
  if [ ! -d "$CORPUS" ]; then
    echo "Corpus is empty — run './eval-corpus.sh synthetic' or 'add <uuid>'."
    return
  fi
  local count
  count="$(find "$CORPUS" -name '*.json' | wc -l | tr -d ' ')"
  echo
  echo "Corpus: $CORPUS  ($count session(s))"
}

cmd_run() {
  local lever="${1:-digest}"
  cat <<EOF

Run the experiment (spends real tokens — two requests per window):

  CRUXWING_LEVER_CORPUS="$CORPUS" \\
  CRUXWING_LEVER=$lever \\
  CRUXWING_LEVER_WINDOWS=12 \\
  swift test --filter LeverExperimentHarness

Requires provider keys: put them in mac/.env and run ./build.sh first —
Secrets.swift is regenerated from there and ships empty in a clean tree.
EOF
}

case "${1:-status}" in
  list)      cmd_list ;;
  add)       shift; cmd_add "$@" ;;
  synthetic) shift; cmd_synthetic "${1:-4}" ;;
  status)    cmd_status ;;
  run)       shift; cmd_run "${1:-digest}" ;;
  *)         sed -n '2,20p' "$0"; exit 1 ;;
esac
