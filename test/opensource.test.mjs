import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// The stated metric is stars and adoption. Before anyone reads a line of Swift
// they meet the repository furniture: the security policy, the CI badge, the
// issue form. Each is a promise, and the failure mode is always the same — the
// promise outlives the thing it describes. A CI file naming a directory that
// was renamed, a security policy pointing at a mailbox nobody owns, an issue
// form asking for a field the build stopped stamping.
//
// None of that breaks a build. It breaks the first impression of the one
// visitor who tried to help, which is the only currency this project has.
//
// The licence is deliberately not checked here — `contributing`, `readme` and
// `landing` already assert it, and a fourth copy would be a fourth thing to
// update.

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
const read = (...p) => readFileSync(resolve(repo, ...p), 'utf8');

describe('open-source furniture', () => {
  describe('CI', () => {
    const ci = read('.github', 'workflows', 'ci.yml');

    test('runs on pull requests, not only on the maintainer push', () => {
      // CI that fires only on main tells the contributor nothing at the moment
      // it would still matter — before the merge.
      //
      // Anchored to the `on:` block, not to the word anywhere in the file.
      // A bare /pull_request:/ passed with the trigger COMMENTED OUT, because
      // `# pull_request:` still contains it — and the concurrency block below
      // mentions `github.event_name == 'pull_request'` besides.
      const triggers = ci.split('\n')
        .filter((line) => !line.trim().startsWith('#'))
        .join('\n')
        .match(/^on:\n((?:[ \t]+.*\n|\n)*)/m)?.[1];
      assert.ok(triggers, 'CI declares no `on:` block at all');
      assert.match(triggers, /^\s+pull_request:/m,
        'CI does not run on pull requests, so a contributor learns nothing');
    });

    test('is structurally valid YAML in the ways YAML usually breaks', () => {
      // No YAML parser is available here and adding a dependency to a
      // zero-dependency test suite to lint one file is a bad trade. These are
      // the two failures that actually happen, and both are cheap to see:
      // a tab in the indentation (YAML forbids it outright) and a missing
      // top-level key (GitHub then ignores the workflow silently).
      //
      // Neither can be caught locally any other way — the first real run of
      // this file happens on someone else's pull request.
      for (const [file, required] of [
        ['.github/workflows/ci.yml', ['name', 'on', 'jobs']],
        ['.github/ISSUE_TEMPLATE/oshibka.yml', ['name', 'description', 'body']],
      ]) {
        const text = readFileSync(resolve(repo, file), 'utf8');
        const tab = text.split('\n').findIndex((line) => /^\s*\t/.test(line));
        assert.equal(tab, -1, `${file} line ${tab + 1} indents with a tab; YAML forbids it`);
        for (const key of required) {
          assert.match(text, new RegExp(`^${key}:`, 'm'),
            `${file} has no top-level "${key}:" — GitHub ignores the file`);
        }
      }
    });

    test('every working directory it names exists', () => {
      // A renamed directory turns into a red X on a stranger's first pull
      // request, with an error about a missing path rather than their change.
      const dirs = [...ci.matchAll(/working-directory:\s*(\S+)/g)].map(([, d]) => d);
      assert.ok(dirs.length > 0, 'no working directories declared — check the parse');
      for (const dir of dirs) {
        assert.ok(existsSync(resolve(repo, dir)),
          `CI runs in "${dir}", which does not exist`);
      }
    });

    test('it runs the suites this repo actually has', () => {
      // Per package, not "swift test appears somewhere". There are two Swift
      // packages, so a single match let the app suite be swapped for `echo`
      // while the mvp one kept the assertion green — the app is the 2668 of
      // the 2788 tests, and it was the half that could go silently missing.
      for (const pkg of ['app', 'mvp']) {
        assert.match(ci, new RegExp(`working-directory:\\s*${pkg}\\s*\\n\\s*run:\\s*swift test`),
          `CI no longer runs the Swift tests in ${pkg}/`);
      }
      assert.match(ci, /run:\s*npm test/, 'CI no longer runs the node tests');

      // And `npm test` has to be a real script, or the step is decoration.
      const pkg = JSON.parse(read('package.json'));
      assert.ok(pkg.scripts?.test, 'package.json has no test script for CI to run');
    });

    test('the cached path is one SwiftPM actually builds into', () => {
      // A cache key pointing at the wrong directory is the worst kind of green:
      // every run is a cold build, and nobody notices because it still passes.
      const cached = ci.match(/path:\s*(\S*\.build)/)?.[1];
      assert.ok(cached, 'the SwiftPM cache step no longer names a .build path');
      const manifest = cached.replace(/\.build$/, 'Package.swift');
      assert.ok(existsSync(resolve(repo, manifest)),
        `CI caches "${cached}", but there is no Swift package at that level`);
    });

    test('the build output it caches is not something the repo commits', () => {
      // `.build` was committed once and left 114 MB of stale compiler cache in
      // the history. Caching it in CI is right; tracking it is not, and the
      // ignore rule is what keeps those two apart.
      // Checked per file, not on the two joined together. Joined, deleting the
      // ROOT rule still passed on the copy in `app/.gitignore` — and the root
      // one is the whole point: `build/orakul.app` at the top level is what
      // actually got committed, home path and all.
      assert.match(read('.gitignore'), /^build\/$/m,
        'root build/ is not ignored — the built app returns to the repository');
      assert.match(read('app', '.gitignore'), /^build\/$/m,
        'app/build/ is not ignored');
      assert.match(read('app', '.gitignore'), /^\.build\/$/m,
        'app/.build/ is not ignored — the 114 MB compiler cache comes back');
    });
  });

  test('the build script publishes what it builds', () => {
    // Дважды за вечер `audit-dmg.sh` ловил одно и то же: собрано, но не
    // выложено. Сборка зелёная, DMG на месте, в папке публикации — вчерашний
    // файл. Шаг копирования был ручным, поэтому иногда его не было.
    const dist = readFileSync(resolve(repo, 'app', 'dist-all.sh'), 'utf8');
    const code = dist.split('\n')
      .filter((line) => !line.trim().startsWith('#')).join('\n');
    assert.match(code, /cp .*PUBLISH|cp "\$dmg" "\$PUBLISH/,
      'dist-all.sh builds the installers but no longer publishes them');
    // И адрес публикации должен быть тем, который потом уезжает по rsync.
    assert.match(code, /cruxwing-marketing\/public\/download/,
      'the publish directory is not the one rsync sends');
  });

  test('no Swift test reports PASS while silently doing nothing', () => {
    // `guard enabled else { return }` в теле теста печатает «passed». Шесть
    // проверок производительности так и молчали — во всех прогонах и в CI, —
    // а «250 сессий укладываются в бюджет» не значило ничего.
    //
    // Пропуск обязан быть виден: трейт `.enabled(if:)` печатает «skipped».
    // Разница между «проверено» и «не запускалось» — это вся ценность отчёта.
    const roots = ['app/Tests/MeetGPTTests', 'mvp/Tests/OrakulCoreTests'];
    const offenders = [];
    for (const root of roots) {
      const dir = resolve(repo, root);
      if (!existsSync(dir)) continue;
      for (const file of readdirSync(dir).filter((f) => f.endsWith('.swift'))) {
        const source = readFileSync(resolve(dir, file), 'utf8');
        source.split('\n').forEach((line, index) => {
          if (line.trim().startsWith('//')) return;
          // Две формы, и обе печатают «passed».
          //
          // Первая — флаг: `guard enabled`, `guard Self.preciseRunEnabled`.
          // Точка обязательна, `\w` её не берёт: на этом проверка промахнулась.
          //
          // Вторая — переменная окружения: `guard let dir = env["…"]`. Её
          // первая версия шаблона не видела вовсе, потому что искала слово
          // «enabled», а таких пропусков нашлось ещё четыре — замеры
          // диаризации и русского корпуса, молчавшие во всех прогонах.
          const flagSkip = /guard\s+[\w.]*[Ee]nabled[\w.]*\s+else\s*\{\s*return\s*\}/;
          const envSkip = /guard\s+let\s+\w+\s*=\s*[\w.]*[Ee]nv(?:ironment)?\[[^\]]+\]\s+else\s*\{\s*return\s*\}/;
          if (flagSkip.test(line) || envSkip.test(line)) {
            offenders.push(`${file}:${index + 1}: ${line.trim()}`);
          }
        });
      }
    }
    assert.deepEqual(offenders, [],
      `these tests report PASS while skipping their body:\n${offenders.join('\n')}`);
  });

  test('the Russian dictionary exists once, not once per package', () => {
    // Копий было две — в приложении и в ядре, — и каждая правка вносилась в
    // обе руками: кросс-алфавитный поиск, падежи терминов, кэш таблиц. Три
    // раза подряд это сработало только потому, что я помнил. Следующий не
    // вспомнит, и словарь тихо разъедется: приложение станет искать иначе,
    // чем командная строка, на том же архиве.
    const copies = [];
    for (const root of ['app/Sources', 'mvp/Sources']) {
      const dir = resolve(repo, root);
      if (!existsSync(dir)) continue;
      const walk = (d) => {
        for (const entry of readdirSync(d, { withFileTypes: true })) {
          const full = resolve(d, entry.name);
          if (entry.isDirectory()) walk(full);
          else if (entry.name === 'RussianLexicon.swift') copies.push(full.slice(repo.length + 1));
        }
      };
      walk(dir);
    }
    assert.deepEqual(copies, ['mvp/Sources/OrakulCore/RussianLexicon.swift'],
      `the Russian dictionary is duplicated again:\n${copies.join('\n')}`);
  });

  test('the canonical lookup is written once, not once per search path', () => {
    // Разбор слов у приложения и командной строки разный — разные стоп-слова,
    // разная обрезка, — но шаг «термин → его канон → его падеж» был одинаковый
    // и написан дважды. Кросс-алфавитный поиск и падежи чинились в обеих
    // копиях руками; на третий раз это перестало быть случайностью.
    const paths = [
      ['CLI', 'mvp/Sources/OrakulCore/RecallIndex.swift'],
      ['app', 'app/Sources/MeetGPT/AI/DecisionRecallService.swift'],
    ];
    for (const [name, file] of paths) {
      const code = readFileSync(resolve(repo, file), 'utf8')
        .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
      assert.match(code, /RussianLexicon\.canonicalToken\(for:/,
        `${name} no longer uses the shared canonical lookup`);
      assert.doesNotMatch(code, /canonicalForms\(\)\[|inflections\(\)\[/,
        `${name} reimplemented the canonical lookup inline again`);
    }
  });

  test('the app links the portable core instead of copying it', () => {
    const manifest = readFileSync(resolve(repo, 'app', 'Package.swift'), 'utf8');
    assert.match(manifest, /\.package\(path: "\.\.\/mvp"\)/,
      'the app no longer depends on OrakulCore — the copy is on its way back');
    assert.match(manifest, /product\(name: "OrakulCore", package: "mvp"\)/,
      'OrakulCore is declared as a dependency but never linked');
  });

  describe('правила поведения', () => {
    const coc = resolve(here, '..', 'CODE_OF_CONDUCT.md');

    test('файл есть — иначе GitHub считает проект не готовым к людям', () => {
      assert.ok(existsSync(coc), 'CODE_OF_CONDUCT.md нет');
    });

    // Смысл файла — не в списке недопустимого (его даёт Contributor Covenant),
    // а в двух обязательствах мейнтейнера. Без них останется шаблон, который
    // защищает площадку от человека, — ровно то, из-за чего уходят с форумов.
    test('обещает объяснять решения и разрешает их обжаловать', () => {
      const text = readFileSync(coc, 'utf8');
      assert.match(text, /объясняется|объяснить/,
        'пропало обязательство объяснять каждое закрытие');
      assert.match(text, /обжаловать|пересмотр/,
        'пропало право потребовать пересмотра');
      assert.match(text, /дубликат/i,
        'закрытие дубликатом — самый частый случай, он должен быть назван');
      assert.match(text, /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i,
        'некуда написать — правила без адреса не работают');
    });

    test('README ведёт к нему, а не оставляет его для одного GitHub', () => {
      const readme = readFileSync(resolve(here, '..', 'README.md'), 'utf8');
      assert.match(readme, /\(CODE_OF_CONDUCT\.md\)/,
        'README не ссылается на правила поведения');
    });
  });

  describe('security policy', () => {
    const security = read('SECURITY.md');

    test('names a reporting channel that exists', () => {
      // The tempting line is "email security@orakul.ai". That domain does not
      // resolve, so it would be a channel that silently drops vulnerability
      // reports — strictly worse than offering none at all.
      assert.doesNotMatch(security, /[\w.-]+@orakul\.ai/,
        'the policy prints an address at a domain that does not resolve');
      assert.match(security, /Report a vulnerability/,
        'no working private-reporting channel is named');
    });

    test('the self-check commands it prints are real', () => {
      const script = security.match(/bash (scripts\/[\w.-]+\.sh)/)?.[1];
      assert.ok(script, 'the policy no longer offers a way to verify the build');
      assert.ok(existsSync(resolve(repo, script)),
        `the policy prints "${script}", which does not exist`);

      const filter = security.match(/--filter\s+(\w+)/)?.[1];
      assert.ok(filter, 'the policy no longer offers a live connector check');
      const suites = readdirSync(resolve(repo, 'app', 'Tests', 'MeetGPTTests'));
      assert.ok(suites.some((f) => f.startsWith(filter)),
        `the policy names --filter ${filter}, but no such suite exists`);
    });

    test('its "no server" claim matches what the build enforces', () => {
      // The policy says the build HALTS on a baked backend address. That is a
      // checkable claim about build.sh and the strongest sentence in the file.
      // Comments are stripped first: they quote the removed address on purpose,
      // so a plain substring search would pass on the wrong evidence.
      assert.match(security, /build\.sh/);
      const code = read('app', 'build.sh').split('\n')
        .filter((line) => !line.trim().startsWith('#')).join('\n');
      assert.match(code, /exit 1/, 'the policy promises the build halts; nothing halts it');
      assert.doesNotMatch(code, /api\.cruxwing\.ai/,
        'a foreign backend is back in build.sh, and the policy says it cannot be');
    });
  });

  describe('issue form', () => {
    const form = read('.github', 'ISSUE_TEMPLATE', 'oshibka.yml');

    test('asks for the version field the build actually stamps', () => {
      // It asks for OrakulSourceHash because the commit alone cannot tell two
      // builds of the same dirty tree apart — nine installers went out in one
      // day under one commit. If build.sh stops stamping it, the form starts
      // asking for something nobody can supply.
      assert.match(form, /OrakulSourceHash/);
      assert.match(read('app', 'build.sh'), /OrakulSourceHash/,
        'the form asks for a stamp the build no longer writes');
    });

    test('steers vulnerabilities away from the public tracker', () => {
      assert.match(form, /Security|SECURITY\.md/,
        'nothing steers a security report out of the public tracker');
    });

    test('is written in the language of the people it is for', () => {
      // The audience is Russian-speaking developers; an English form filters
      // out exactly the contributors this is meant to attract.
      const labels = [...form.matchAll(/label:\s*(.+)/g)].map(([, l]) => l.trim());
      assert.ok(labels.length >= 4, `only ${labels.length} fields — check the parse`);
      for (const label of labels) {
        assert.match(label, /[А-Яа-яЁё]/, `the field "${label}" is not in Russian`);
      }
    });
  });
});
