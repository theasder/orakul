#!/usr/bin/env bash
# Совпадает ли опубликованный установщик с текущими исходниками.
#
# Зачем. Собрать и забыть отправить — или отправить, но старое — не оставляет
# следа: лог сборки зелёный, DMG рабочий, страница на месте. Единственный
# способ поймать это — спросить у самого файла, из чего он собран.
#
# Коммита для этого мало. При незакоммиченном дереве `OrakulCommit` одинаков у
# всех сборок подряд: 12 августа их было девять, и все несли один штамп при 149
# изменённых файлах. Поэтому `build.sh` кладёт рядом хеш содержимого
# `Sources/MeetGPT`, а этот скрипт пересчитывает его и сравнивает.
#
#   bash scripts/audit-dmg.sh
#
# Выход 0 — опубликованное собрано из этих исходников. Иначе 1 и что разошлось.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
download="$(cd "$root/../cruxwing-marketing/public/download" 2>/dev/null && pwd || true)"

if [ -z "$download" ]; then
    echo "!! не найдена папка публикации cruxwing-marketing/public/download" >&2
    exit 1
fi

# Та же формула, что в build.sh. Держать её в двух местах неприятно, но
# альтернатива — спрашивать у сборки, чем она себя считает, а это уже не
# проверка.
# Считается по приложению И по ядру относительными путями от корня: `shasum`
# едет в том же бинарнике. Пока в хеш входило только `Sources/MeetGPT`, правка
# коннектора не меняла штамп вовсе.
commits=""
expected="$(cd "$root" && find app/Sources/MeetGPT mvp/Sources/OrakulCore -type f \
    ! -name Secrets.swift | LC_ALL=C sort | xargs shasum -a 1 2>/dev/null \
    | shasum -a 1 | cut -c1-12)"

echo ">> исходники сейчас: $expected"

status=0
for arch in AppleSilicon Intel; do
    dmg="$download/orakul-$arch.dmg"
    if [ ! -f "$dmg" ]; then
        echo "  $arch: НЕТ ФАЙЛА $dmg"
        status=1
        continue
    fi

    mount="$(mktemp -d)"
    hdiutil attach "$dmg" -nobrowse -quiet -mountpoint "$mount"
    app="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
    stamped="$(defaults read "$app/Contents/Info.plist" OrakulSourceHash 2>/dev/null || echo "")"
    commit="$(defaults read "$app/Contents/Info.plist" OrakulCommit 2>/dev/null || echo "?")"
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet
    rmdir "$mount" 2>/dev/null || true

    if [ -z "$stamped" ]; then
        echo "  $arch: штампа нет — собрано до появления этой проверки"
        status=1
    elif [ "$stamped" = "$expected" ]; then
        echo "  $arch: совпадает ($stamped, коммит $commit)"
    else
        echo "  $arch: РАСХОЖДЕНИЕ — в DMG $stamped, в исходниках $expected"
        echo "       опубликовано не то, что лежит в рабочем дереве"
        status=1
    fi

    # Коммит запоминается, чтобы сверить архитектуры между собой (ниже).
    if [ -z "$commits" ]; then commits="$commit"; else commits="$commits $commit"; fi
done

# Один выпуск — один коммит на обе архитектуры.
#
# Хеш исходников этого не ловит: он считается по `Sources`, и коммит, который
# трогает только страницу, тесты или README, оставляет хеш прежним. Ровно так
# и вышло — правка документации легла между сборкой arm64 и сборкой Intel, и
# два DMG одного выпуска уехали со штампами 1928241 и 686618f при одинаковом
# хеше. Аудит сказал «совпадает» дважды и был прав по букве.
#
# Само по себе это не разные бинарники. Но форма отчёта об ошибке просит
# прислать `OrakulCommit`, и два ответа на один выпуск — это потерянное время
# того, кто будет разбираться.
first=""
for c in $commits; do
    if [ -z "$first" ]; then first="$c"; continue; fi
    if [ "$c" != "$first" ]; then
        echo "  РАСХОЖДЕНИЕ КОММИТОВ: архитектуры собраны из разных ($commits)"
        echo "       обычно это правка, легшая между сборками — пересоберите обе"
        status=1
    fi
done

exit "$status"
