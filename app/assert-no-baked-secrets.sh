#!/bin/bash
# assert-no-baked-secrets.sh <Cruxwing.app | binary>
#
# Fail-safe secret gate for the Mac App Store lane (M12). A keyless dist build
# (MEETGPT_DIST=1) serves every LLM through the backend gateway, so the shipped
# binary must contain NO provider or org secrets. This scans the Mach-O binary's
# strings for known key shapes and exits non-zero if any are found — appstore.sh
# runs it BEFORE productbuild/upload so a misbuilt (non-DIST, key-baked) binary
# can never be packaged for the store. It redacts any match so the gate itself
# never prints a full secret.
set -euo pipefail

TARGET="${1:?usage: assert-no-baked-secrets.sh <Cruxwing.app|binary>}"
if [ -d "$TARGET" ]; then
    BIN="$TARGET/Contents/MacOS/MeetGPT"
else
    BIN="$TARGET"
fi
[ -f "$BIN" ] || { echo "!! no binary at $BIN" >&2; exit 2; }

# Provider / API key shapes — deliberately specific so ordinary strings don't
# match: OpenAI/DeepSeek/Moonshot (sk-…), Anthropic (sk-ant-…), Google AI
# (AIza…), Slack (xox[baprs]-…), and inline bearer tokens. The keyless build
# emits empty string literals for all of these, so a clean scan is expected.
#
# The (?<![A-Za-z0-9_-]) lookbehind is load-bearing. Without it `sk-` matched
# MID-WORD, and the bundled skill id `risk-management-specialist` — a router seed
# for the Risks button, present in every build — read as "ri" + "sk-management-
# specialist" and tripped the scan. This guard therefore failed on every run,
# keyless or not, which either blocks release packaging outright or trains
# everyone to wave it through. A guard that always fires protects nothing.
#
# perl rather than grep -E: BSD grep (macOS) has no lookbehind support.
PATTERN='(?<![A-Za-z0-9_-])(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|[Bb]earer [A-Za-z0-9._-]{24,})'

HITS="$(strings -a "$BIN" 2>/dev/null | perl -nle "print \$1 while /$PATTERN/g" | sort -u || true)"
if [ -n "$HITS" ]; then
    echo "!! BAKED SECRET DETECTED in $BIN — refusing to package for the App Store." >&2
    echo "   A Mac App Store build must be keyless (LLM_GATEWAY=backend). Rebuild with" >&2
    echo "   MEETGPT_DIST=1 so no provider keys compile in. Offending token shapes:" >&2
    printf '%s\n' "$HITS" | sed -E 's/(.{6}).*/   \1… [redacted]/' >&2
    exit 1
fi
echo ">> secret scan clean: no provider/org keys in $BIN"
