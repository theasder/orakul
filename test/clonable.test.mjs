// Собирается ли то, что получит клонирующий.
//
// Центральная метрика проекта — звёзды и то, сколько людей им пользуется.
// Обе упираются в одно: человек, пришедший из Хабра или телеграм-чата, делает
// `git clone`, потом `swift build`, и либо у него собирается, либо он уходит.
// Всё остальное в этом репозитории имеет значение только после этого шага.
//
// Проверять это чтением бесполезно: в рабочем дереве файл есть, и сборка,
// тесты и глаз показывают одно и то же — «всё на месте». У клонирующего его
// нет. Ровно так и вышло: пятьдесят исходников не были под контролем версий,
// среди них `ProviderKeyStore.swift` (без него приложение не отвечает ни на
// один вопрос), весь новый код ядра, CI и SECURITY.md. Локально — зелено,
// у клонирующего — не собирается вовсе.
//
// Поэтому здесь спрашивается не рабочее дерево, а `git ls-files`.

import { test, describe } from 'node:test';
import assert from 'node:assert';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');

const git = (...args) =>
  execFileSync('git', args, { cwd: repo, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });

/// Файлы под контролем версий — ровно то, что окажется у клонирующего.
const tracked = () => new Set(git('ls-files').split('\n').filter(Boolean));

/// Исходники в рабочем дереве, без артефактов сборки и чужих зависимостей.
const onDisk = () =>
  git('ls-files', '--others', '--cached', '--exclude-standard')
    .split('\n')
    .filter(Boolean)
    .filter((f) => !/(^|\/)(\.build|build|dist|node_modules)\//.test(f));

describe('то, что получает клонирующий', () => {
  test('каждый исходник в рабочем дереве попадёт в клон', () => {
    // Именно этот разрыв и случился: файл написан, тесты по нему зелёные,
    // `git add` никто не сделал. Локально не отличить.
    const inGit = tracked();
    const missing = onDisk()
      .filter((f) => /\.(swift|mjs|js|sh|yml|html)$/.test(f))
      .filter((f) => !inGit.has(f));

    assert.deepEqual(missing, [],
      `у клонирующего не будет этих файлов:\n  ${missing.join('\n  ')}`);
  });

  test('git не помнит файлов, которых уже нет', () => {
    // Обратная сторона: удалённый файл остаётся в индексе и приезжает
    // клонирующему обратно. Так `RussianLexicon.swift` уехал бы в клон по
    // старому пути — второй копией словаря, ради устранения которой его и
    // переносили, и проверка «словарь один» упала бы у всех, кроме нас.
    const ghosts = [...tracked()].filter((f) => !existsSync(resolve(repo, f)));
    assert.deepEqual(ghosts, [],
      `git отдаёт клонирующему то, чего уже нет:\n  ${ghosts.join('\n  ')}`);
  });

  test('обещанные README каталоги в клоне не пустые', () => {
    // Быстрый старт начинается с `cd mvp && swift build`. Если под контролем
    // версий нет манифеста и исходников, первая же команда обрывается.
    const inGit = tracked();
    const needed = [
      ['mvp/Package.swift', 'без манифеста `swift build` не начнётся'],
      ['app/Package.swift', 'приложение нечем собрать'],
      ['package.json', '`npm test` из README не запустится'],
      ['README.md', 'пришедшему не с чего начать'],
      ['LICENSE', 'без лицензии код нельзя брать'],
    ];
    for (const [file, why] of needed) {
      assert.ok(inGit.has(file), `${file} не под контролем версий — ${why}`);
    }

    // Каталоги, а не только манифесты: пустой `Sources` собирается в пустоту.
    for (const dir of ['mvp/Sources/OrakulCore', 'mvp/Sources/orakul',
                       'app/Sources/MeetGPT', 'test']) {
      const count = [...inGit].filter((f) => f.startsWith(dir + '/')).length;
      assert.ok(count > 0, `в клоне пусто: ${dir}`);
    }
  });

  test('артефакты сборки не едут клонирующему', () => {
    // Обратная ошибка того же рода: 114 МБ `.build` в истории делают клон
    // невозможным на медленной сети — а это как раз тот, кого мы зовём.
    const heavy = [...tracked()].filter((f) =>
      /(^|\/)(\.build|node_modules)\//.test(f) || /\.(dmg|zip|o|dylib)$/.test(f));
    assert.deepEqual(heavy, [],
      `в репозитории лежат артефакты сборки:\n  ${heavy.join('\n  ')}`);
  });

  test('.gitignore закрывает артефакты, но не исходники', () => {
    const ignore = readFileSync(resolve(repo, '.gitignore'), 'utf8');
    for (const pattern of ['.build', 'dist']) {
      assert.ok(ignore.includes(pattern), `.gitignore не закрывает ${pattern}`);
    }
    // И не закрывает лишнего: правило вроде `Sources/` тихо выкинуло бы
    // половину проекта, и предыдущие проверки этого бы не увидели —
    // `ls-files --others --exclude-standard` тоже уважает .gitignore.
    //
    // Единственное намеренное исключение — `Secrets.swift`: он генерируется
    // сборкой и содержит ключи. По той же причине `build.sh` выкидывает его
    // из хеша исходников. Список закрытый: любой ДРУГОЙ спрятанный исходник
    // должен всплыть, иначе смысл проверки теряется.
    const deliberate = ['app/Sources/MeetGPT/Secrets.swift'];
    const swallowed = git('ls-files', '--others', '--ignored', '--exclude-standard')
      .split('\n')
      .filter(Boolean)
      .filter((f) => /\.(swift|mjs)$/.test(f))
      .filter((f) => !/(^|\/)(\.build|build|dist|node_modules)\//.test(f))
      .filter((f) => !deliberate.includes(f));
    assert.deepEqual(swallowed, [],
      `.gitignore прячет исходники:\n  ${swallowed.join('\n  ')}`);

    // Исключение обязано оставаться исключением: если `Secrets.swift` попадёт
    // под контроль версий, ключи уедут в открытый репозиторий.
    assert.ok(!tracked().has('app/Sources/MeetGPT/Secrets.swift'),
      'Secrets.swift под контролем версий — ключи уедут в клон');
  });
});
