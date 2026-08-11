#!/bin/bash
# Produce a portable Intel-native release build. Swift's release configuration
# enables whole-module optimized code; the x86_64 target intentionally avoids a
# newer CPU-specific ISA so the app remains compatible with older Intel Macs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Cruxwing-Intel.app"
BIN="$APP/Contents/MacOS/MeetGPT"
DIST="$ROOT/dist"
ZIP="$DIST/Cruxwing-Intel.zip"
SECRETS="$ROOT/Sources/MeetGPT/Secrets.swift"
SECRETS_BACKUP="$(mktemp "${TMPDIR:-/tmp}/cruxwing-secrets.XXXXXX")"
HAD_SECRETS=0
if [ -f "$SECRETS" ]; then
    cp "$SECRETS" "$SECRETS_BACKUP"
    HAD_SECRETS=1
fi
restore_secrets() {
    if [ "$HAD_SECRETS" = "1" ]; then
        cp "$SECRETS_BACKUP" "$SECRETS"
    else
        rm -f "$SECRETS"
    fi
    rm -f "$SECRETS_BACKUP"
}
trap restore_secrets EXIT

# A transferable artifact must never contain the provider keys from a local
# mac/.env. MEETGPT_DIST also selects the production gateway and sandbox profile.
MEETGPT_ARCH=x86_64 \
MEETGPT_APP_BASENAME=Cruxwing-Intel \
MEETGPT_DIST=1 \
MEETGPT_NO_INSTALL=1 \
"$ROOT/build.sh"

ARCHS="$(lipo -archs "$BIN")"
if [ "$ARCHS" != "x86_64" ]; then
    echo "!! expected an Intel-only executable, got: $ARCHS" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
bash "$ROOT/assert-no-baked-secrets.sh" "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ">> Intel executable: $ARCHS"
echo ">> Intel app: $APP"
echo ">> Intel zip: $ZIP"
echo "   Locally signed build; use notarize.sh with a Developer ID for Gatekeeper-ready distribution."
