#!/bin/bash
# Прогнать часть проверок и упасть, если под фильтр не попало ни одной.
#
#     bash scripts/test-filter.sh mvp RussianCaseSearchTests
#     bash scripts/test-filter.sh app AgendaCheckServiceTests
#
# Зачем. `swift test --filter «чего-нибудь несуществующего»` печатает
#
#     ✔ Test run with 0 tests passed after 0.001 seconds.
#
# и возвращает ноль. То есть опечатка в имени набора выглядит точно так же, как
# успешный прогон. За одну ночь я купился на это дважды: сначала решил, что
# проверка не ловит мутацию (а она просто не запускалась), потом — что запуск
# подтвердил починку. Ноль проверок ничего не подтверждает.
#
# Имя набора — то, что стоит в `@Suite("…")`, или имя структуры. Фильтр Swift
# Testing сопоставляется с полным именем, и кириллические названия из `@Test`
# в него не попадают: искать надо по имени структуры.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

if [ $# -lt 2 ]; then
    echo "Нужно: bash scripts/test-filter.sh <app|mvp> <имя набора>" >&2
    exit 2
fi

package="$1"
filter="$2"
case "$package" in
    app|mvp) ;;
    # Скобки обязательны: без них bash читает имя переменной вместе со
    # следующей многобайтовой кавычкой и падает под `set -u`.
    *) echo "Первый аргумент — app или mvp, а не «${package}»." >&2; exit 2 ;;
esac

output=$(cd "$root/$package" && swift test --filter "$filter" 2>&1)
status=$?
echo "$output"

count=$(echo "$output" | grep -oE "Test run with ([0-9]+) tests?" | tail -1 \
        | grep -oE "[0-9]+" || echo "")

if [ -z "$count" ]; then
    echo ">> Не удалось прочитать число проверок — считаю это провалом." >&2
    exit 1
fi

if [ "$count" -eq 0 ]; then
    echo ">> Под фильтр «${filter}» не попало ни одной проверки." >&2
    echo ">> Это не успех: ноль проверок ничего не подтверждает." >&2
    echo ">> Имена наборов: grep -rn '@Suite' $package/Tests | head" >&2
    exit 1
fi

echo ">> Прошло проверок: $count"
exit $status
