#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-$ROOT/../web/landing/assets/icon-512.png}"
OUTPUT="${2:-$ROOT/Support/AppIcon.icns}"

[ -f "$SOURCE" ] || { echo "!! icon source missing: $SOURCE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cruxwing-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# The artwork contains near-black opaque pixels outside its visually rounded
# tile. A plain resize therefore produces a square desktop icon that reads
# larger than Mail/Safari/Notes in Dock and Finder. Crop the fringe, draw the
# tile into a centered optical inset (~70% of the canvas), then apply the
# continuous macOS 22.37% corner mask so the glyph matches system icon size.
/usr/bin/swift - "$SOURCE" "$ICONSET" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Slot {
    let pixels: Int
    let name: String
}

let slots = [
    Slot(pixels: 16, name: "icon_16x16.png"),
    Slot(pixels: 32, name: "icon_16x16@2x.png"),
    Slot(pixels: 32, name: "icon_32x32.png"),
    Slot(pixels: 64, name: "icon_32x32@2x.png"),
    Slot(pixels: 128, name: "icon_128x128.png"),
    Slot(pixels: 256, name: "icon_128x128@2x.png"),
    Slot(pixels: 256, name: "icon_256x256.png"),
    Slot(pixels: 512, name: "icon_256x256@2x.png"),
    Slot(pixels: 512, name: "icon_512x512.png"),
    Slot(pixels: 1024, name: "icon_512x512@2x.png"),
]

/// Fraction of the canvas the squircle occupies. Full-bleed (~1.0) looks
/// oversized next to Apple apps; ~0.70 matches Dock/Finder optical weight.
let opticalScale: CGFloat = 0.70

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: MaskAppIcon <source.png> <output.iconset>")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height else {
    fatalError("icon source must be a readable square image")
}

// The 512px source contains a baked near-black fringe outside the luminous
// tile: 13px left, 15px right, 26px top, and 20px bottom. Crop those unequal
// margins before scaling so no dark padding survives on any side. Keep the
// ratios when a proportional source variant is supplied.
let sourceScaleX = CGFloat(image.width) / 512.0
let sourceScaleY = CGFloat(image.height) / 512.0
let artworkCrop = CGRect(
    x: 13.0 * sourceScaleX,
    y: 26.0 * sourceScaleY,
    width: 484.0 * sourceScaleX,
    height: 466.0 * sourceScaleY
).integral
guard let artwork = image.cropping(to: artworkCrop) else {
    fatalError("could not crop baked icon padding")
}

for slot in slots {
    let pixels = slot.pixels
    let canvas = CGFloat(pixels)
    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let inset = canvas * (1.0 - opticalScale) / 2.0
    let drawRect = CGRect(
        x: inset,
        y: inset,
        width: canvas - inset * 2.0,
        height: canvas - inset * 2.0
    )
    let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("could not create \(pixels)x\(pixels) icon context")
    }

    context.clear(rect)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    let mask = RoundedRectangle(
        cornerRadius: drawRect.width * 0.2237,
        style: .continuous
    ).path(in: drawRect)
    context.addPath(mask.cgPath)
    context.clip()
    context.draw(artwork, in: drawRect)

    guard let rendered = context.makeImage() else {
        fatalError("could not render \(slot.name)")
    }
    let outputURL = outputDirectory.appendingPathComponent(slot.name)
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("could not create \(slot.name)")
    }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(slot.name)")
    }
}
SWIFT

iconutil -c icns "$ICONSET" -o "$TMP/AppIcon.icns"
cp "$TMP/AppIcon.icns" "$OUTPUT"
echo ">> icon: $OUTPUT"
