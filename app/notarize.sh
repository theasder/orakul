#!/bin/bash
# Build, Developer-ID-sign (hardened runtime), notarize, staple, and zip
# orakul.app for distribution outside the App Store.
#
# One-time setup (needs a paid Apple Developer account):
#   1. Install a "Developer ID Application: …" certificate in your keychain
#      (developer.apple.com → Certificates, or Xcode → Settings → Accounts).
#   2. Store notarytool credentials (App Store Connect API key or app-specific
#      password):
#        xcrun notarytool store-credentials meetgpt-notary \
#            --apple-id you@example.com --team-id TEAMID
#
# Then:  ./notarize.sh
# Env:   NOTARY_PROFILE (default meetgpt-notary), NOTARY_SIGN_ID (override cert)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# One archive per architecture. build.sh names the Intel bundle differently, so
# notarizing x86_64 used to sign, submit and staple the arm64 app that happened
# to be lying in build/ — a "Gatekeeper-ready Intel build" that was not Intel.
ARCH="${MEETGPT_ARCH:-native}"
case "$ARCH" in
    x86_64) APP_BASENAME="orakul-Intel"; PUBLISH_NAME="orakul-Intel" ;;
    arm64)  APP_BASENAME="orakul";       PUBLISH_NAME="orakul-AppleSilicon" ;;
    native) APP_BASENAME="orakul";       PUBLISH_NAME="orakul" ;;
    *) echo "!! unsupported MEETGPT_ARCH=$ARCH (use native, arm64, or x86_64)" >&2; exit 2 ;;
esac
APP="$ROOT/build/$APP_BASENAME.app"
# Sign with the entitlements build.sh RESOLVED, not the raw non-sandbox file.
#
# build.sh picks the sandbox profile for a dist build, and — when there is no
# provisioning profile to authorise it — strips com.apple.developer.applesignin
# into build/.local.entitlements. Re-signing here with Support/MeetGPT.entitlements
# threw both away: the shipped app came back non-sandboxed AND carrying a
# restricted Sign-in-with-Apple entitlement it had no profile for, so launchd
# refused to spawn it and the app died with "Launchd job spawn failed" — which
# Finder reports as "The application Cruxwing can't be opened."
ENT="$ROOT/Support/MeetGPT.sandbox.entitlements"
[ -f "$ROOT/build/.local.entitlements" ] && ENT="$ROOT/build/.local.entitlements"
DIST="$ROOT/dist"
PROFILE="${NOTARY_PROFILE:-meetgpt-notary}"

# Учётные данные нотаризации проверяются ДО сборки, а не в момент отправки.
#
# 2026-08-13 профиль пропал из связки ключей, и это выяснилось после того, как
# arm64 собрался и подписался: шесть минут работы впустую, а сообщение об
# ошибке пришло с середины конвейера. Проверка стоит секунду и говорит, что
# именно делать.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "!! Профиль нотаризации «${PROFILE}» недоступен в связке ключей." >&2
    echo "   Сборка остановлена до компиляции — чинить здесь:" >&2
    echo "     xcrun notarytool store-credentials ${PROFILE} \\" >&2
    echo "       --apple-id <Apple ID> --team-id <Team ID> --password <app-specific>" >&2
    echo "   Пароль вводит человек: он не хранится в репозитории и не должен." >&2
    exit 1
fi

# --- Find a Developer ID identity (ad-hoc / self-signed can't notarize) ---
SIGN_ID="${NOTARY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Developer ID Application" \
              | awk -F'"' '{print $2}' || true)"
fi
if [ -z "$SIGN_ID" ]; then
    echo "!! No 'Developer ID Application' identity in the keychain."
    echo "   Notarization requires one (paid Apple Developer account) — see the"
    echo "   comments at the top of this script. Local dev builds don't need it."
    exit 1
fi
echo ">> signing identity: $SIGN_ID"

# --- Fresh staging build (not installed) ---
MEETGPT_DIST=1 MEETGPT_NO_INSTALL=1 MEETGPT_ARCH="$ARCH" MEETGPT_SIGN_ID="$SIGN_ID" "$ROOT/build.sh"

# --- Re-sign with the hardened runtime (required by notarization) ---
echo ">> codesign (hardened runtime)"
codesign --force --deep --options runtime --timestamp \
         --sign "$SIGN_ID" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

# --- Submit + staple ---
mkdir -p "$DIST"
ZIP="$DIST/$PUBLISH_NAME-notarize.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo ">> notarytool submit (waits for Apple; typically a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo ">> stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# --- Final distributable ---
FINAL="$DIST/$PUBLISH_NAME.zip"
rm -f "$FINAL" "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$FINAL"
# The checksum the download page tells users to verify against.
( cd "$DIST" && shasum -a 256 "$PUBLISH_NAME.zip" > "$PUBLISH_NAME.zip.sha256" )
echo ">> done: $FINAL"
echo "   arch: $(lipo -archs "$APP/Contents/MacOS/MeetGPT" 2>/dev/null || echo unknown)"
echo "   Gatekeeper-ready — distribute this zip + $PUBLISH_NAME.zip.sha256"
