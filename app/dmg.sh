#!/bin/bash
# Build the classic drag-to-Applications disk image from an already-notarized
# app bundle, then sign, notarize and staple the IMAGE itself.
#
#   ./dmg.sh            # arm64 (orakul.app       -> dist/orakul-AppleSilicon.dmg)
#   ./dmg.sh x86_64     # intel (orakul-Intel.app -> dist/orakul-Intel.dmg)
#
# Why a DMG when notarize.sh already produces a working zip:
#
#   · A zip lands in ~/Downloads and people run the app FROM there. macOS ties
#     Screen Recording and Microphone grants to the app's path and signature, so
#     an app that later moves to /Applications presents as a different subject
#     and the permissions it was granted stop applying — reported as "I granted
#     Screen Recording but it still fails" (reset-permissions.sh exists because
#     of exactly this).
#   · The drag-to-Applications window is the one install gesture Mac users
#     already know. It makes the correct location the default action rather than
#     a line in a README nobody reads.
#
# The app inside must ALREADY be notarized and stapled by notarize.sh: a stapled
# app still validates when the DMG is opened offline. The image is then notarized
# separately so Gatekeeper is clean on the download itself, not only the payload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-${MEETGPT_ARCH:-arm64}}"
case "$ARCH" in
    x86_64) APP_BASENAME="orakul-Intel"; PUBLISH_NAME="orakul-Intel" ;;
    arm64|native) APP_BASENAME="orakul"; PUBLISH_NAME="orakul-AppleSilicon" ;;
    *) echo "!! unsupported arch '$ARCH' (use arm64 or x86_64)" >&2; exit 2 ;;
esac

APP="$ROOT/build/$APP_BASENAME.app"
DIST="$ROOT/dist"
DMG="$DIST/$PUBLISH_NAME.dmg"
VOLNAME="orakul"

[ -d "$APP" ] || { echo "!! no app at $APP — run ./notarize.sh first" >&2; exit 2; }

# Refuse to package an app that is not already Gatekeeper-clean. Shipping a DMG
# whose payload fails is worse than shipping nothing: the user gets a polished
# install window and then an app that will not open, which reads as a broken
# product rather than a broken build.
if ! /usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "!! $APP has no stapled notarization ticket — run ./notarize.sh first" >&2
    exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-meetgpt-notary}"
SIGN_ID="${NOTARY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"
[ -n "$SIGN_ID" ] || { echo "!! no Developer ID Application identity found" >&2; exit 1; }

mkdir -p "$DIST"

# A stale mount of a previous run leaves a "/Volumes/Cruxwing" ghost, macOS
# mounts the new image as "Cruxwing 1", and the AppleScript below — addressed
# by VOLUME name — styles the wrong (old) disk: Finder error -10006, unstyled
# image. Only image-backed volumes are detached; a real disk that happens to
# share the name is not ours to eject.
while IFS= read -r VOL; do
    if /usr/bin/hdiutil info | grep -qF "$VOL"; then
        echo ">> detaching stale mount $VOL"
        /usr/bin/hdiutil detach "$VOL" -quiet \
            || /usr/bin/hdiutil detach "$VOL" -force -quiet || true
    fi
done < <(ls -d "/Volumes/$VOLNAME" "/Volumes/$VOLNAME "* 2>/dev/null)

STAGE="$(mktemp -d /tmp/cruxwing-dmg.XXXXXX)"
echo ">> staging $APP_BASENAME.app"
/usr/bin/ditto "$APP" "$STAGE/$APP_BASENAME.app"
# The other half of the gesture: without this symlink the window has nowhere to
# drag TO, and the user is back to copying by hand.
ln -s /Applications "$STAGE/Applications"

# Background art, rendered rather than checked in: the PNG has no business in git
# when CoreGraphics can draw it deterministically, and generate-icon.sh already
# establishes `swift -` + heredoc as how this repo makes images.
#
# Rendered TWICE, at 1x and 2x, and combined into a HiDPI TIFF. Finder cannot use
# an SVG — a background picture must be raster — so the only way to stop a Retina
# Mac upscaling a 660x420 bitmap is to ship the 1320x840 representation alongside
# it and let `tiffutil -cathidpicheck` mark it as the @2x variant. Every drawing
# coordinate below is multiplied by the scale, so the two renders are identical
# artwork rather than one resampled copy: text and the arrow are re-rasterised at
# the higher resolution, which is the entire point.
echo ">> rendering background (1x + 2x HiDPI)"
mkdir -p "$STAGE/.background"
for SCALE in 1 2; do
/usr/bin/swift - "$STAGE/.background/bg-${SCALE}x.png" "$SCALE" <<'SWIFT'
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let s = CGFloat(Int(CommandLine.arguments[2]) ?? 1)
let w = Int(660 * s), h = Int(420 * s)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
// Draw in 1x coordinates from here on; the transform above handles the rest.
let bw = 660, bh = 420

// A quiet vertical wash. The window is a signpost, not a landing page: anything
// louder competes with the two icons the user is meant to look at.
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.976, green: 0.976, blue: 0.984, alpha: 1),
    CGColor(red: 0.925, green: 0.929, blue: 0.949, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bh),
                       end: CGPoint(x: 0, y: 0), options: [])

// Arrow between the two icon positions (170,210) and (490,210), drawn in the
// gap so it never sits under either icon.
ctx.setStrokeColor(CGColor(red: 0.62, green: 0.64, blue: 0.70, alpha: 1))
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 268, y: bh - 205))
ctx.addLine(to: CGPoint(x: 392, y: bh - 205))
ctx.strokePath()
ctx.move(to: CGPoint(x: 372, y: bh - 191))
ctx.addLine(to: CGPoint(x: 394, y: bh - 205))
ctx.addLine(to: CGPoint(x: 372, y: bh - 219))
ctx.strokePath()

func text(_ s: String, _ size: CGFloat, _ y: CGFloat, _ alpha: CGFloat, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: alpha),
    ]
    let line = NSAttributedString(string: s, attributes: attrs)
    let size = line.size()
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    line.draw(at: NSPoint(x: (CGFloat(bw) - size.width) / 2, y: y))
    NSGraphicsContext.restoreGraphicsState()
}
text("Drag Cruxwing into Applications", 17, CGFloat(bh) - 92, 0.95, bold: true)
text("Launching it from Applications keeps Screen Recording and", 12, 58, 0.6)
text("Microphone permissions attached to the app.", 12, 40, 0.6)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
SWIFT
done

# -cathidpicheck is what tells Finder the second image IS the @2x of the first.
# Without it the two are just unrelated pages of a TIFF and Retina still blurs.
/usr/bin/tiffutil -cathidpicheck "$STAGE/.background/bg-1x.png" \
                                 "$STAGE/.background/bg-2x.png" \
                  -out "$STAGE/.background/bg.tiff" >/dev/null
rm -f "$STAGE/.background/bg-1x.png" "$STAGE/.background/bg-2x.png"

echo ">> creating disk image"
rm -f "$DMG"
# Build read-WRITE first: Finder can only record window geometry, icon positions
# and the background onto a mounted, writable volume. The compressed read-only
# image is produced from it afterwards.
RW="$STAGE/../cruxwing-rw-$$.dmg"
rm -f "$RW"
/usr/bin/hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
    -ov -format UDRW -quiet "$RW"
MOUNT="$(/usr/bin/hdiutil attach -readwrite -noverify -noautoopen "$RW" \
    | grep -o '/Volumes/.*' | head -1)"
[ -n "$MOUNT" ] || { echo "!! could not mount the staging image" >&2; exit 1; }

# Finder scripting is the flakiest step in any DMG pipeline — it needs Automation
# permission and fails on a machine with no window server. Non-fatal on purpose:
# an unstyled DMG still installs correctly, so a cosmetic failure must not block
# a release.
echo ">> arranging the window"
if ! /usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 860, 580}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        -- Back to 112 after trying 1.3x (146): it fit geometrically but read as
        -- oversized next to the caption, and the window is a signpost rather
        -- than a showcase. The hard ceiling is still ~190 — past that the icons
        -- close the gap the arrow occupies, and ~230 has them touching.
        set icon size of opts to 112
        set background picture of opts to file ".background:bg.tiff"
        set position of item "$APP_BASENAME.app" of container window to {170, 210}
        set position of item "Applications" of container window to {490, 210}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "   (Finder styling failed — shipping an unstyled but working image)" >&2
fi

/bin/sync
/usr/bin/hdiutil detach "$MOUNT" -quiet || /usr/bin/hdiutil detach "$MOUNT" -force -quiet
/usr/bin/hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"

echo ">> signing the image"
/usr/bin/codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

echo ">> notarizing the image (this is the slow part)"
/usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
rm -rf "$STAGE"

echo ">> done: $DMG"
echo "   arch: $ARCH"
echo "   Double-click, drag Cruxwing to Applications, launch from there."
