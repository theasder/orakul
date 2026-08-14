import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// The stated metric for this project is stars, and a star is decided by the
// README before any code is read. So the README gets tests — not for style,
// but for the two ways a front page loses trust: promising what does not
// exist, and printing a command that does not work.

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
const readme = readFileSync(resolve(repo, 'README.md'), 'utf8');

describe('README', () => {
  test('README does not claim the images are unpublished', () => {
    // Файл длинный, и утверждения в нём разъезжаются между собой: быстрый
    // старт вёл в выпуск, а раздел «чего ещё нет» в это же время сообщал,
    // что скачать неоткуда, — два противоположных факта в одном документе.
    const readme = readFileSync(resolve(repo, 'README.md'), 'utf8');
    for (const stale of ['на сайт не выложены', 'откуда скачать: DMG',
                         'ссылки на них не будет']) {
      assert.ok(!readme.includes(stale), `README всё ещё утверждает: «${stale}»`);
    }
    // И наоборот: раз выпуск есть, на него должна быть ссылка.
    assert.match(readme, /releases\/latest/, 'README не ведёт в выпуск');
  });

  test('the Bitrix24 caveat is in README, because the issue says it is', () => {
    // Выпуск #1 зовёт помочь и ссылается на README со словами «так и написано».
    // Написано не было: про Битрикс24 в README не стояло ни строки, а
    // коннектор к нему сделан по документации, не по живому порталу. Обещание
    // о собственных документах — такое же обещание, как любое другое.
    const readme = readFileSync(resolve(repo, 'README.md'), 'utf8');
    assert.match(readme, /Битрикс24/, 'README снова молчит про Битрикс24');
    assert.match(readme, /по документации, а не проверен на живом\s*портале/,
      'оговорка про живой портал пропала из README');
    // И ссылка на разбор, который эту оговорку объясняет.
    assert.match(readme, /RESEARCH-AND-PLAN\.md`, §2\.0\.1/,
      'README не ведёт к разбору Битрикс24');
    const doc = readFileSync(resolve(repo, 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');
    assert.match(doc, /### 2\.0\.1 Битрикс24/, 'раздел §2.0.1 пропал из исследования');
  });

  test('the dependency counts in the quick start are the real ones', () => {
    // README обещает, сколько строк «Fetching» человек увидит при первой
    // сборке. Число проверяемое: прямые зависимости — в Package.swift,
    // полное — в Package.resolved. Сверять его глазами никто не будет.
    const readme = readFileSync(resolve(repo, 'README.md'), 'utf8');
    const words = { две: 2, три: 3, четыре: 4, пять: 5, шесть: 6,
                    двадцать: 20, 'двадцать три': 23, 'двадцать четыре': 24 };

    const direct = /У приложения в `app\/` их ([а-яё]+)/.exec(readme);
    assert.ok(direct, 'README больше не говорит, сколько прямых зависимостей');
    const manifest = readFileSync(resolve(repo, 'app', 'Package.swift'), 'utf8');
    // `.package(path:)` — соседний каталог, его не скачивают: в «Fetching» он
    // не появится, и считать его среди зависимостей значит соврать на единицу.
    const remote = (manifest.match(/\.package\(url:/g) ?? []).length;
    assert.equal(words[direct[1]], remote,
      `README обещает ${direct[1]} (${words[direct[1]]}) прямых, в манифесте их ${remote}`);

    const total = /всего (\d+) пакет/.exec(readme);
    assert.ok(total, 'README больше не называет полное число пакетов');
    const resolved = JSON.parse(readFileSync(resolve(repo, 'app', 'Package.resolved'), 'utf8'));
    const pins = resolved.pins ?? resolved.object?.pins ?? [];
    assert.ok(pins.length > 0, 'Package.resolved не разобрался — проверка бы прошла впустую');
    assert.equal(Number(total[1]), pins.length,
      `README обещает ${total[1]} пакетов, в Package.resolved их ${pins.length}`);

    // И третье число — сколько тянут за собой: разница между ними.
    const transitive = /Они тянут за собой ещё ([а-яё]+ ?[а-яё]*) —/.exec(readme);
    assert.ok(transitive, 'README больше не говорит про непрямые зависимости');
    const stated = words[transitive[1].trim()];
    assert.ok(stated !== undefined, `непонятное число: ${transitive[1]}`);
    assert.equal(stated, pins.length - remote,
      `README обещает ${stated} непрямых, а их ${pins.length - remote}`);
  });

  test('every repo file it links to exists', () => {
    // README-ссылки гниют тише всего: файл переименовали, README остался, и
    // гость упирается в 404 на первой же полезной ссылке. Внешние адреса не
    // трогаем — их проверить без сети нельзя, и врать о них тест не должен.
    const links = [...readme.matchAll(/\]\((?!https?:|#)([^)]+)\)/g)].map(([, l]) => l);
    assert.ok(links.length >= 3, `only ${links.length} local links — check the parse`);
    for (const link of links) {
      assert.ok(existsSync(resolve(repo, link.split('#')[0])),
        `README links to ${link}, which does not exist`);
    }
  });

  test('says up front that there is no app yet', () => {
    // The most expensive lie a README can tell is implying it runs. A visitor
    // who clones this and finds no binary does not come back.
    // Приложение теперь есть — форк Cruxwing, DMG собраны и нотаризованы.
    // Но «есть приложение» и «его можно скачать» — разные утверждения, и
    // страница обязана различать их.
    assert.match(readme, /форк Cruxwing/i);
    assert.match(readme, /Чего ещё нет/i);
  });

  test('never claims a capability the code does not have', () => {
    // The CLI exists now, so "runnable" is true — but recording a call is
    // still not, and that is the claim that must never appear.
    // Скачать пока негде: артефакты собраны локально и на сайт не выложены.
    assert.doesNotMatch(readme, /скачать приложение|ссылка на загрузку/i);
    // Semantic search is exactly what this does NOT do.
    assert.doesNotMatch(readme, /понимает смысл|семантический поиск/i);
    assert.match(readme, /синонимы\s*—\s*нет/i, 'the search limitation belongs on the front page');
  });

  test('every command it prints is one that exists', () => {
    // `swift test` needs a package; `node --test` needs test files. A README
    // whose first command fails is worse than no README.
    assert.ok(existsSync(resolve(repo, 'app', 'Package.swift')), 'swift test has no package');
    assert.match(readme, /swift build -c release/);
    assert.match(readme, /swift test/);
    assert.ok(readdirSync(resolve(repo, 'test')).some((f) => f.endsWith('.test.mjs')),
      'the documented test command has nothing to run');
    // Проверяем, что команда из README реально существует, а не что она
    // записана определённой строкой: раньше здесь стоял литерал, и README,
    // перешедший на npm test, уронил тест, хотя команда была верной.
    assert.match(readme, /npm test/);
    const pkg = JSON.parse(readFileSync(resolve(repo, 'package.json'), 'utf8'));
    assert.ok(pkg.scripts?.test, 'README promises npm test, package.json has no test script');
  });

  test('the binary the quick start runs is built by the directory it enters', () => {
    // The check above proves a package exists and that the words "swift build"
    // appear. It never tied the two together, so the README said `cd app` and
    // then ran `.build/release/orakul` — and `app/` builds `MeetGPT`. The first
    // command a visitor types died with "no such file or directory", which is
    // the most expensive possible failure for a project measured in stars.
    const quickStart = /```bash\n([\s\S]*?)```/.exec(readme)?.[1] ?? '';
    assert.ok(quickStart.includes('swift build'), 'the quick start no longer builds anything');

    const dir = /cd (\w+) && swift build/.exec(quickStart)?.[1];
    assert.ok(dir, 'the quick start does not say which directory to build in');

    const binaries = [...quickStart.matchAll(/\.build\/release\/(\w+)/g)].map(([, n]) => n);
    assert.ok(binaries.length > 0, 'the quick start builds but runs nothing');

    const manifest = readFileSync(resolve(repo, dir, 'Package.swift'), 'utf8');
    for (const binary of new Set(binaries)) {
      assert.ok(manifest.includes(`.executable(name: "${binary}"`),
        `README runs .build/release/${binary} after "cd ${dir}", but ${dir}/Package.swift declares no such executable`);
    }
  });

  test('the refusal it quotes is the refusal the program prints', () => {
    // The README showed «В сохранённых звонках…» while the CLI said
    // «В сохранённых созвонах…» — the page quoting words the binary never
    // produced. The refusal is the product's central promise (no invented
    // answers), so a paraphrase there costs more than anywhere else on the page.
    const source = readFileSync(
      resolve(repo, 'mvp', 'Sources', 'OrakulCore', 'RecallAnswer.swift'), 'utf8');
    // Строка ищется где угодно, а не только после `return`: отказ переехал в
    // локальную переменную, когда к нему стала приписываться подсказка про
    // опечатку, и привязанный к `return` образец перестал совпадать. Сторож
    // тогда не промолчал — `assert.ok` ниже поймал исчезновение, — но чинить
    // проверку после каждой перестановки строк незачем.
    const refusal = /"(В сохранённых [^"]+)"/.exec(source)?.[1];
    assert.ok(refusal, 'the refusal string is gone from RecallAnswer.swift');
    assert.ok(readme.includes(refusal),
      `README quotes a refusal the program does not print; it prints: ${refusal}`);

    // And one word for the thing, everywhere a reader can see it.
    for (const wrong of ['созвон', 'встреч']) {
      assert.ok(!refusal.includes(wrong), `the refusal calls a call a "${wrong}"`);
    }
  });

  test('the licence it names is the licence in the repo', () => {
    const licence = readFileSync(resolve(repo, 'LICENSE'), 'utf8');
    assert.match(licence, /Apache License\s+Version 2\.0, January 2004/);
    assert.match(licence, /TERMS AND CONDITIONS/);
    assert.match(readme, /Apache 2\.0/);
    const identity = JSON.parse(readFileSync(resolve(repo, 'config', 'app.json'), 'utf8'));
    assert.equal(identity.app.name, 'orakul');
  });

  test('quotes the measurement, not a rounder number', () => {
    // 71% → 89% term agreement, measured on three fragments of real Russian
    // speech. If the README ever rounds this up, the claim and its source have
    // parted company.
    assert.match(readme, /71%/);
    assert.match(readme, /89%/);
    assert.doesNotMatch(readme, /9[5-9]%|100%/, 'no figure here reaches that');
  });

  test('states the price, because "free" is the product', () => {
    assert.match(readme, /Тарифов нет/i);
    assert.doesNotMatch(readme, /₽|подписк|платная версия/i);
  });

  test('the test count is the real one, not the one it had when written', () => {
    // "2607 тестов проходят" is the README's one hard number, and a stale one
    // is worse than none: a visitor who runs the suite and counts something
    // else stops believing the rest of the page. It sat at 2598 through nine
    // added tests with nothing to notice.
    //
    // Swift Testing reports a parameterized @Test as ONE test regardless of its
    // argument count, so counting declarations matches the reported total
    // exactly — which is what makes an equality check honest here rather than
    // a bound.
    // Counted per suite, not just the app's. Moving the connectors into the
    // core moved 23 tests with them, and a headline that counts only
    // app/Tests would have dropped by 23 while nothing was lost — the exact
    // reading that makes a visitor stop trusting the page.
    const countSwift = (...segments) => {
      const dir = resolve(repo, ...segments);
      const files = readdirSync(dir).filter((n) => n.endsWith('.swift'));
      assert.ok(files.length > 3, `no Swift test files in ${segments.join('/')}`);
      return files
        .flatMap((name) => readFileSync(resolve(dir, name), 'utf8').split('\n'))
        .filter((line) => /^\s*@Test\b/.test(line)).length;
    };
    const appTests = countSwift('app', 'Tests', 'MeetGPTTests');
    const coreTests = countSwift('mvp', 'Tests', 'OrakulCoreTests');
    assert.ok(appTests > 20, 'the app suite count would be fake');

    // The per-suite numbers in the run command.
    // Форма слова зависит от числа: 2657 штук, 2663 штуки, 2661 штука.
    // Раньше здесь стояло только «штук», и правильная по-русски запись роняла
    // проверку — а неправильная проходила.
    const counted = /swift test` \((\d{3,5}) (штук|штуки|штука)\)/.exec(readme);
    const inCommand = Number(counted?.[1] ?? NaN);
    if (counted) {
      const n = inCommand % 100;
      const tail = (n >= 11 && n <= 14) ? 'штук'
        : [, 'штука', 'штуки', 'штуки', 'штуки'][inCommand % 10] ?? 'штук';
      assert.equal(counted[2], tail,
        `${inCommand} — по-русски «${tail}», а написано «${counted[2]}»`);
    }
    assert.equal(inCommand, appTests,
      `README says ${inCommand} app tests, the suite declares ${appTests}`);
    const inCore = Number(/mvp — (\d{2,5})/.exec(readme)?.[1] ?? NaN);
    assert.equal(inCore, coreTests,
      `README says ${inCore} core tests, the suite declares ${coreTests}`);

    // The npm number too — it went stale the moment this very test was added,
    // which is the whole argument for checking it rather than trusting it.
    // Counted here instead of in its own test on purpose: a new test() would
    // change the number it is trying to verify.
    const suites = readdirSync(here).filter((n) => n.endsWith('.test.mjs'));
    const nodeTests = suites
      .flatMap((name) => readFileSync(resolve(here, name), 'utf8').split('\n'))
      .filter((line) => /^\s*test\(/.test(line)).length;
    const statedNode = Number(/`npm test` в корне \((\d{1,4})/.exec(readme)?.[1] ?? NaN);
    assert.equal(statedNode, nodeTests,
      `README says ${statedNode} npm tests, the suites declare ${nodeTests}`);

    // The headline is the sum of all three, checked last so a mismatch names
    // the parts. Checking it as a sum is what stops the number drifting when
    // a test only moves between suites.
    // Числительное согласуется, а не приписывается: «3251 тестов проходят» —
    // не по-русски, и на 3251 это выяснилось только потому, что образец с
    // жёстким «тестов проходят» перестал совпадать. Форма проверяется здесь
    // же, иначе следующий раз пройдёт молча.
    const headline = /(\d{3,5}) (тест|теста|тестов) (проходит|проходят)/.exec(readme);
    assert.ok(headline, 'в README пропало число проходящих тестов');
    const stated = Number(headline[1]);
    assert.equal(stated, appTests + coreTests + nodeTests,
      `README claims ${stated} tests; suites declare ${appTests} + ${coreTests} + ${nodeTests}`);

    const teen = stated % 100 >= 11 && stated % 100 <= 14;
    const last = stated % 10;
    const noun = teen ? 'тестов' : last === 1 ? 'тест' : last >= 2 && last <= 4 ? 'теста' : 'тестов';
    const verb = !teen && last === 1 ? 'проходит' : 'проходят';
    assert.equal(headline[2], noun,
      `${stated} — по-русски «${noun}», а написано «${headline[2]}»`);
    assert.equal(headline[3], verb,
      `${stated} ${noun} «${verb}», а написано «${headline[3]}»`);
  });
});
