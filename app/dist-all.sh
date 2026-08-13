#!/bin/bash
#
# Build a distributable for BOTH architectures, so friends on Apple Silicon AND
# Intel Macs can run it — "not only the Apple Silicon version but also Intel".
#
# Each arch goes through the full, already-debugged notarize.sh pipeline (its own
# scratch path under .build/<arch>, its own Developer-ID sign, its own Apple
# notarization + staple). Output in dist/:
#     orakul-AppleSilicon.zip  (+ .sha256)   arm64
#     orakul-Intel.zip         (+ .sha256)   x86_64
#
# arm64 runs first (the common Mac today), so if the rarer Intel leg fails the
# Apple Silicon build is already produced and shippable. Prerequisites are
# notarize.sh's: a Developer-ID identity and stored notarytool credentials.
#
# This is what the build step distributes; a single-arch build is
#     MEETGPT_ARCH=arm64 ./notarize.sh
# and remains available for a quick Apple-Silicon-only turn.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

ARCHES=(arm64 x86_64)
built=()
for arch in "${ARCHES[@]}"; do
    echo "======================================================================"
    echo ">> distributable: $arch"
    echo "======================================================================"
    MEETGPT_ARCH="$arch" "$ROOT/notarize.sh"
    # Every friend build ships the drag-to-Applications DMG alongside the zip
    # (owner's standing instruction): the zip invites running from ~/Downloads,
    # which breaks path-tied Screen Recording/Microphone grants on later moves —
    # dmg.sh's whole reason to exist. It packages THIS arch's freshly stapled
    # bundle, then signs, notarizes and staples the image itself.
    "$ROOT/dmg.sh" "$arch"
    built+=("$arch")
done

echo ""
echo ">> both architectures done (${built[*]}):"
ls -1 "$ROOT/dist/"*.zip "$ROOT/dist/"*.dmg 2>/dev/null || true

# Разложить собранное туда, откуда оно уезжает на сервер.
#
# Раньше этого шага здесь не было, и он делался руками — то есть иногда не
# делался. `scripts/audit-dmg.sh` поймал это дважды за один вечер: сборка
# зелёная, DMG на месте, а в папке публикации лежит вчерашний файл с прошлым
# хешем исходников. Собрать и забыть выложить — самая незаметная из ошибок,
# потому что все признаки успеха налицо.
PUBLISH="$ROOT/../../cruxwing-marketing/public/download"
if [ -d "$PUBLISH" ]; then
    for dmg in "$ROOT/dist/"orakul-*.dmg; do
        [ -f "$dmg" ] || continue
        cp "$dmg" "$PUBLISH/"
        echo ">> опубликовано: $(basename "$dmg")"
    done
    echo ">> сверить с исходниками: bash scripts/audit-dmg.sh"
else
    echo "!! папка публикации не найдена ($PUBLISH) — DMG остались только в dist/"
fi
