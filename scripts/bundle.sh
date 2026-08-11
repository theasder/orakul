#!/usr/bin/env bash
# Собрать orakul.app из исполняемого файла SwiftPM.
#
# SwiftPM не умеет делать бандлы, поэтому раскладку делаем сами — это тридцать
# строк и полная ясность в том, что попало внутрь.
#
#   bash scripts/bundle.sh            # собрать build/orakul.app
#   bash scripts/bundle.sh --run      # собрать и запустить
#
# Подписи Developer ID и нотаризации здесь НЕТ. Такой бандл запустится на своей
# машине и будет заблокирован Gatekeeper на чужой: называть это дистрибутивом
# нельзя.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$root/build/orakul.app"
plist="$root/app/Support/Info.plist"

echo "==> сборка"
cd "$root/app"
swift build -c release --product OrakulApp

binary="$(swift build -c release --show-bin-path)/OrakulApp"
[ -f "$binary" ] || { echo "не нашёл собранный OrakulApp"; exit 1; }

echo "==> раскладка бандла"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

# Имя исполняемого файла обязано совпадать с CFBundleExecutable, иначе macOS
# запустит бандл и не найдёт, что внутри него исполнять.
cp "$binary" "$app_dir/Contents/MacOS/orakul"
cp "$plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# Ad-hoc подпись: без неё у бандла нет собственной записи в базе разрешений, и
# запрос микрофона уходит той программе, из которой его запустили.
if codesign --force --sign - "$app_dir" 2>/dev/null; then
  echo "==> подписано ad-hoc (только для этой машины)"
else
  echo "==> подписать не вышло — разрешения могут уехать вызывающей программе"
fi

echo "==> готово: $app_dir"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist"

if [ "${1:-}" = "--run" ]; then
  open "$app_dir"
fi
