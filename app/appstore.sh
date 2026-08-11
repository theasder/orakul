#!/bin/bash
# Build, MAS-sign, package (.pkg), and (optionally) upload Cruxwing for
# the Mac App Store. This lane is SEPARATE from notarize.sh (Developer ID):
#   - signs with "Apple Distribution" (NOT "Developer ID Application")
#   - embeds a Mac App Store provisioning profile
#   - wraps the app in a productbuild .pkg signed with the Mac Installer identity
#   - does NOT use the hardened runtime (MAS relies on the App Sandbox instead)
#
# One-time setup (needs a paid Apple Developer account — HUMAN, M11b-4/M12b):
#   1. App Store Connect → create the app record. ⚠ BUNDLE ID IS PERMANENT once
#      submitted. Info.plist currently ships ai.orakul.desktop; the D14 decision
#      flagged com.cruxwing.mac as a revisit BEFORE first submission — a human
#      product call. Change Support/Info.plist FIRST if switching; do not submit
#      ai.orakul.desktop unless that is the intended permanent id.
#   2. Install two certs: "Apple Distribution: …" (app) and "3rd Party Mac
#      Developer Installer: …" (pkg). Xcode → Settings → Accounts → Manage
#      Certificates, or developer.apple.com → Certificates.
#   3. Download a Mac App Store provisioning profile for the app id; pass its path
#      as MAS_PROVISION_PROFILE.
#   4. For upload: an app-specific password (appleid.apple.com) or Transporter.app.
#
# Usage:
#   MAS_PROVISION_PROFILE=~/Cruxwing_MAS.provisionprofile ./appstore.sh
#   MAS_DRY_RUN=1 ./appstore.sh        # build + secret gate only (no Apple creds)
#
# Env:
#   MAS_APP_IDENTITY        app identity        (default: "Apple Distribution")
#   MAS_INSTALLER_IDENTITY  installer identity  (default: "3rd Party Mac Developer Installer")
#   MAS_PROVISION_PROFILE   path to .provisionprofile (required unless dry run)
#   MAS_UPLOAD=1            upload the .pkg via `xcrun altool` after packaging
#   MAS_APPLE_ID / MAS_APP_PASSWORD   credentials for MAS_UPLOAD
#   MAS_DRY_RUN=1          build + assert-no-baked-secrets, then stop
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Cruxwing.app"
SANDBOX_ENT="$ROOT/Support/MeetGPT.sandbox.entitlements"
DIST="$ROOT/dist"
PKG="$DIST/Cruxwing.pkg"

APP_IDENTITY="${MAS_APP_IDENTITY:-Apple Distribution}"
INSTALLER_IDENTITY="${MAS_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}"
PROFILE="${MAS_PROVISION_PROFILE:-}"
DRY_RUN="${MAS_DRY_RUN:-0}"

# --- Pre-flight: fail fast on the HUMAN inputs, so we never ship a half-signed
#     pkg. All of these come from a paid Apple Developer account. ---
if [ "$DRY_RUN" != "1" ]; then
    if [ -z "$PROFILE" ] || [ ! -f "$PROFILE" ]; then
        echo "!! MAS_PROVISION_PROFILE is required (a Mac App Store provisioning" >&2
        echo "   profile for the app's bundle id). This + the Apple Distribution /" >&2
        echo "   Mac Installer certs are Apple-account HUMAN inputs — see the header." >&2
        echo "   To validate the keyless build + secret gate without them: MAS_DRY_RUN=1." >&2
        exit 1
    fi
    for id in "$APP_IDENTITY" "$INSTALLER_IDENTITY"; do
        if ! security find-identity -v 2>/dev/null | grep -q "$id" \
           && ! security find-identity 2>/dev/null | grep -q "$id"; then
            echo "!! signing identity not found in keychain: \"$id\"" >&2
            echo "   Install the Apple Distribution + Mac Installer certs (paid Apple" >&2
            echo "   Developer account). MAS_DRY_RUN=1 skips signing." >&2
            exit 1
        fi
    done
fi

# --- Fresh keyless, sandboxed staging build (MEETGPT_DIST=1 → no baked keys,
#     mandatory App Sandbox). build.sh signs the staging copy with a local
#     identity; we re-sign below with the MAS identity + provisioning profile. ---
echo ">> building keyless sandboxed app (MEETGPT_DIST=1)"
MEETGPT_DIST=1 MEETGPT_NO_INSTALL=1 "$ROOT/build.sh"

# --- FAIL-SAFE secret gate (M12): the store binary MUST be keyless. Aborts the
#     whole lane if any provider/org key shape is present in the binary. ---
bash "$ROOT/assert-no-baked-secrets.sh" "$APP"

if [ "$DRY_RUN" = "1" ]; then
    echo ">> DRY RUN complete: keyless build + secret gate passed. Stopping before signing."
    echo "   Provide MAS_PROVISION_PROFILE + the Apple certs to sign/package/upload."
    exit 0
fi

# --- Embed the Mac App Store provisioning profile ---
echo ">> embedding provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# --- Re-sign nested code, then the app: MAS identity + sandbox entitlements.
#     Nested bundles (the vendored skills/resource bundle) must be signed before
#     the outer app or codesign rejects the seal. No hardened runtime for MAS. ---
echo ">> codesign (\"$APP_IDENTITY\" + sandbox entitlements)"
find "$APP/Contents" -type d -name '*.bundle' -print0 | while IFS= read -r -d '' b; do
    codesign --force --timestamp --sign "$APP_IDENTITY" "$b"
done
codesign --force --timestamp \
         --sign "$APP_IDENTITY" --entitlements "$SANDBOX_ENT" "$APP"
codesign --verify --deep --strict "$APP"

# --- Build the App Store installer package ---
mkdir -p "$DIST"
rm -f "$PKG"
echo ">> productbuild → $PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
echo ">> packaged: $PKG"

# --- Optional upload to App Store Connect ---
if [ "${MAS_UPLOAD:-0}" = "1" ]; then
    : "${MAS_APPLE_ID:?MAS_UPLOAD=1 needs MAS_APPLE_ID}"
    : "${MAS_APP_PASSWORD:?MAS_UPLOAD=1 needs MAS_APP_PASSWORD (app-specific password)}"
    echo ">> uploading to App Store Connect (xcrun altool)"
    xcrun altool --upload-app -f "$PKG" -t macos \
        -u "$MAS_APPLE_ID" -p "$MAS_APP_PASSWORD"
    echo ">> uploaded. Finish in App Store Connect (TestFlight / submit for review)."
else
    echo ">> upload skipped. Upload with Transporter.app, or:"
    echo "   xcrun altool --upload-app -f \"$PKG\" -t macos -u <apple-id> -p <app-specific-password>"
    echo "   (or set MAS_UPLOAD=1 MAS_APPLE_ID=… MAS_APP_PASSWORD=… )"
fi
