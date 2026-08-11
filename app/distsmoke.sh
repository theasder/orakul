#!/bin/bash
# Smoke-test a DISTRIBUTION artifact — the thing users actually receive.
#
#   ./distsmoke.sh dist/Cruxwing-AppleSilicon.dmg
#   ./distsmoke.sh dist/Cruxwing-Intel.zip
#
# Takes either format. The disk image is what the download page links, so it is
# the one that has to pass; the zips ship alongside for mirrors. Checking only
# the zip would repeat the mistake this script exists to prevent — testing an
# artifact adjacent to the one users receive.
#
# livetest.sh / edgetest.sh / videotest.sh drive the real app but need a DEV
# build: their hooks are compiled out of a dist build. So until now the one
# artifact that ships had nothing checking it, and a dist-only packaging bug
# reached a user — `notarize.sh` re-signed with the wrong entitlements file, the
# app kept a restricted Sign-in-with-Apple entitlement it had no provisioning
# profile for, and launchd refused to spawn it. Every signature check passed.
# Only launching it revealed the failure, which is why step 6 exists.
#
# Exits non-zero if any check fails.
set -uo pipefail

ART="${1:?usage: distsmoke.sh <dist/....dmg|.zip>}"
[ -f "$ART" ] || { echo "!! no such artifact: $ART" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d /tmp/distsmoke.XXXXXX)"
echo "== unpacking $(basename "$ART") -> $WORK"

MNT=""
cleanup() { [ -n "$MNT" ] && /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null; }
trap cleanup EXIT

case "$ART" in
*.dmg)
    # Copy the app OUT of the image rather than testing it in place. A mounted
    # DMG is read-only, so step 6 could not launch it the way a user does —
    # they drag it to /Applications first, and that copy is what must run.
    MNT="$(/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen "$ART" \
           | grep -o '/Volumes/.*' | head -1)"
    [ -n "$MNT" ] || { echo "!! image will not mount" >&2; exit 2; }
    SRC="$(/usr/bin/find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
    [ -n "$SRC" ] || { echo "!! no .app inside the image" >&2; exit 2; }
    /usr/bin/ditto "$SRC" "$WORK/$(basename "$SRC")" || { echo "!! ditto failed" >&2; exit 2; }
    /usr/bin/hdiutil detach "$MNT" -quiet; MNT=""
    ;;
*)
    # ditto, never unzip: a ditto archive carries extended attributes, and unzip
    # materialises them as ._AppleDouble files INSIDE the bundle, which breaks the
    # signature seal ("a sealed resource is missing or invalid"). That failure looks
    # identical to a corrupt download and has nothing to do with the build.
    /usr/bin/ditto -x -k "$ART" "$WORK" || { echo "!! ditto failed" >&2; exit 2; }
    ;;
esac
APP="$(/usr/bin/find "$WORK" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "!! no .app inside the artifact" >&2; exit 2; }
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

echo "== 1. bundle shape"
[ -x "$BIN" ] && ok "executable present and +x" || bad "missing/non-executable $BIN"
[ "$(/usr/bin/find "$APP" -name '._*' | wc -l | tr -d ' ')" = "0" ] \
    && ok "no AppleDouble files in bundle" || bad "._ files present — seal will be invalid"

echo "== 2. architecture"
ARCHS="$(/usr/bin/lipo -archs "$BIN" 2>/dev/null || echo unknown)"
echo "        archs: $ARCHS"
case "$ARCHS" in *arm64*|*x86_64*) ok "recognised architecture" ;; *) bad "unexpected arch" ;; esac

echo "== 3. signature"
/usr/bin/codesign --verify --deep --strict "$APP" 2>/dev/null \
    && ok "codesign --verify --deep --strict" || bad "signature invalid"

echo "== 4. notarization / Gatekeeper"
SPCTL="$(/usr/sbin/spctl -a -vvv -t exec "$APP" 2>&1)"
grep -q "accepted" <<<"$SPCTL" && ok "spctl accepted" || bad "spctl rejected"
grep -q "Notarized Developer ID" <<<"$SPCTL" \
    && ok "source = Notarized Developer ID" || bad "not notarized"
/usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1 \
    && ok "stapled ticket validates offline" || bad "no stapled ticket — fails without network"

echo "== 5. entitlements"
E="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null)"
grep -q 'com.apple.security.app-sandbox</key><true/>' <<<"$E" \
    && ok "app-sandbox = true" || bad "app-sandbox not true (dist builds must be sandboxed)"
if grep -q 'applesignin' <<<"$E" && [ ! -f "$APP/Contents/embedded.provisionprofile" ]; then
    bad "applesignin entitlement WITHOUT a provisioning profile — launchd will refuse to spawn"
else
    ok "no unauthorised restricted entitlement"
fi

echo "== 6. it actually launches"
# The check the signature checks cannot make. A bundle can pass 1-5 and still be
# unable to start; that is precisely the bug this script was written for.
SINCE="$(date +%s)"
/usr/bin/open "$APP" 2>/tmp/distsmoke-open.err
sleep 12
if /usr/bin/pgrep -f "$APP/Contents/MacOS/" >/dev/null; then
    ok "process alive 12s after launch"
    /usr/bin/osascript -e 'tell application id "ai.orakul.desktop" to quit' >/dev/null 2>&1
    sleep 3
    /usr/bin/pgrep -f "$APP/Contents/MacOS/" >/dev/null && bad "did not quit cleanly" || ok "quit cleanly"
else
    bad "did not stay running — $(tr -d '\n' </tmp/distsmoke-open.err | cut -c1-160)"
fi

NEW_CRASH="$(/usr/bin/find ~/Library/Logs/DiagnosticReports -name '*.ips' -newermt "@$SINCE" 2>/dev/null \
             | xargs -I{} basename {} 2>/dev/null | grep -i -E 'MeetGPT|Cruxwing' | head -3)"
[ -z "$NEW_CRASH" ] && ok "no crash report generated" || bad "crash report: $NEW_CRASH"

echo
echo "== $PASS passed, $FAIL failed   ($(basename "$ART"), $ARCHS)"
echo "   scratch: $WORK"
[ "$FAIL" -eq 0 ]
