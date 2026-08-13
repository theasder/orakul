import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// The research doc is the second thing a visitor reads and the first thing a
// contributor reads before touching a decision. It names specific symbols and
// makes specific guarantees. A doc naming a function that no longer exists is
// worse than a vague one: it reads as authoritative and is wrong.

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
const doc = readFileSync(resolve(repo, 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');

describe('RESEARCH-AND-PLAN', () => {
  test('every symbol it names still exists in the code', () => {
    // §5.1 states the no-backend rule and names what enforces it. Those names
    // are the doc's load-bearing part: rename one and the doc sends the next
    // contributor looking for something that is not there.
    const config = readFileSync(
      resolve(repo, 'app', 'Sources', 'MeetGPT', 'Config.swift'), 'utf8');
    assert.match(doc, /resolveBackendBaseURL/,
      'the doc no longer names the function that implements the rule');
    assert.match(config, /static func resolveBackendBaseURL/,
      'the doc names Config.resolveBackendBaseURL, which no longer exists');

    // Наборы живут в двух пакетах: интерфейсные — в приложении, ядро — в mvp.
    // Проверка сначала смотрела только в приложение и объявила несуществующим
    // набор, который лежит в ядре. Ссылка была верной, узок был обход.
    const trees = [['app', 'Tests', 'MeetGPTTests'], ['mvp', 'Tests', 'OrakulCoreTests']];
    const files = trees.flatMap((tree) => readdirSync(resolve(repo, ...tree)));

    // Имя набора может стоять и внутри файла: один файл нередко содержит
    // несколько @Suite. Поэтому проверяется и имя файла, и объявление.
    const declarations = trees.flatMap((tree) =>
      readdirSync(resolve(repo, ...tree))
        .filter((name) => name.endsWith('.swift'))
        .map((name) => readFileSync(resolve(repo, ...tree, name), 'utf8')))
      .join('\n');

    for (const named of doc.match(/\b[A-Z][A-Za-z]+Tests\b/g) ?? []) {
      assert.ok(files.includes(`${named}.swift`)
        || new RegExp(`struct ${named}\\b`).test(declarations),
        `the doc cites ${named}, which exists in neither test package`);
    }
  });

  test('the build-time guard it promises is actually in build.sh', () => {
    // The doc claims the build STOPS when a backend address is present. That is
    // the strongest claim in the file — it makes "there is no server" a
    // property rather than an intention. Comments are stripped first: they
    // quote the removed address on purpose, so a plain substring search would
    // pass on the wrong evidence.
    const build = readFileSync(resolve(repo, 'app', 'build.sh'), 'utf8');
    const code = build.split('\n')
      .filter((line) => !line.trim().startsWith('#')).join('\n');

    assert.match(code, /\[ "\$1" = "BACKEND_URL" \] && \{ printf ''; return; \}/,
      'the doc promises DIST bakes no backend address; build.sh no longer does that');
    assert.match(code, /exit 1/, 'the doc promises the build halts; nothing halts it');
    assert.doesNotMatch(code, /api\.cruxwing\.ai/,
      'a foreign backend is back in build.sh, and the doc says it cannot be');
  });

  test('the shipped installer can be traced back to the source it was built from', () => {
    // The commit stamp alone is not traceability. With an uncommitted tree it
    // is identical across every build: nine DMGs went out on 2026-08-12 all
    // stamped 04bf887 while 149 files were modified, so the stamp could not
    // tell last night's build from one with ten new connectors.
    //
    // build.sh therefore also stamps a hash of Sources/MeetGPT, and
    // scripts/audit-dmg.sh reads it back off the published DMG. Both halves
    // are checked here: a stamp nobody reads, or a reader with nothing
    // stamped, is the same as having neither.
    const build = readFileSync(resolve(repo, 'app', 'build.sh'), 'utf8');
    const audit = readFileSync(resolve(repo, 'scripts', 'audit-dmg.sh'), 'utf8');

    assert.match(build, /OrakulSourceHash/,
      'build.sh no longer stamps the source hash — the DMG becomes untraceable');
    assert.match(audit, /OrakulSourceHash/,
      'the audit no longer reads the stamp back');

    // Both sides must exclude the generated Secrets.swift, or dev and dist
    // builds of identical source hash differently and the audit cries wolf.
    for (const [name, script] of [['build.sh', build], ['audit-dmg.sh', audit]]) {
      assert.match(script, /! -name Secrets\.swift/,
        `${name} includes the generated Secrets.swift in the hash`);
    }

    // И приложение, И ядро. Приложение линкует OrakulCore — коннекторы,
    // словарь и поиск физически едут в том же бинарнике. Пока в хеш входило
    // только Sources/MeetGPT, три изменённых файла ядра оставили штамп
    // прежним: аудит отвечал «совпадает» на сборку, собранную из другого
    // кода. Штамп, слепой к половине отгружаемого, хуже отсутствующего —
    // на него ссылается форма отчёта об ошибке.
    for (const [name, script] of [['build.sh', build], ['audit-dmg.sh', audit]]) {
      assert.match(script, /Sources\/MeetGPT/,
        `${name} stopped hashing the app sources`);
      assert.match(script, /Sources\/OrakulCore/,
        `${name} does not hash the core — a connector change leaves the stamp unmoved`);
    }

    // Сборка обязана заставлять SwiftPM перечитать состав ядра. Кеш
    // зависимости-по-пути живёт отдельно на каждую архитектуру и нового
    // файла в ядре не видит: установщик падал с «cannot find X in scope»
    // ровно тогда, когда обычный `swift build` в app/ уже собирался.
    assert.match(build, /swift package "\$\{SWIFT_BUILD_ARGS\[@\]\}" clean/,
      'the installer build reuses a stale scratch path — a new core file breaks it with "cannot find X in scope"');

    // Один выпуск — один коммит на обе архитектуры. Хеш исходников этого не
    // ловит: коммит, трогающий только страницу или тесты, оставляет хеш
    // прежним. Так и вышло — правка документации легла между сборкой arm64 и
    // сборкой Intel, и два DMG уехали со штампами 1928241 и 686618f при
    // одинаковом хеше, а аудит дважды сказал «совпадает».
    assert.match(audit, /РАСХОЖДЕНИЕ КОММИТОВ/,
      'the audit no longer notices two architectures built from different commits');

    // Обе стороны обязаны считать ОДИНАКОВО, а не просто по одним папкам.
    // `shasum` печатает путь рядом с хешем, поэтому один и тот же файл,
    // записанный как `mvp/…` и как `app/../mvp/…`, даёт разный итог. Ровно на
    // этом аудит и разошёлся со сборкой: обе включили ядро, обе назвали
    // «расхождение», хотя код был один. Сравниваются сами конвейеры.
    const pipeline = (script) => {
      const match = /find (app\/[\s\S]*?)cut -c1-12/.exec(script);
      assert.ok(match, 'the hash pipeline is no longer recognisable');
      return match[1].replace(/\s+/g, ' ').trim();
    };
    assert.equal(pipeline(build), pipeline(audit),
      'build.sh and audit-dmg.sh hash differently — the audit will cry wolf on identical source');

    // Относительные пути от корня — то, что делает их сравнимыми.
    for (const [name, script] of [['build.sh', build], ['audit-dmg.sh', audit]]) {
      assert.match(script, /cd "[^"]+" && find app\/Sources/,
        `${name} hashes with absolute paths again — the two sides stop agreeing`);
    }
  });

  test('no stray non-Russian script crept into the Russian text', () => {
    // Ловит ровно то, что случилось при написании §11: в русскую фразу попали
    // два иероглифа — «на котором полагается生成 транспортный токен». Опечатку
    // такого рода не видно при беглом чтении и не ловит ни один тест на смысл,
    // а читателю она сообщает, что текст писали невнимательно.
    //
    // Латиница разрешена: в документе полно имён API, путей и заголовков.
    const stray = [...doc].filter((ch) => {
      const code = ch.codePointAt(0);
      return (code >= 0x3000 && code <= 0x9fff)      // CJK
          || (code >= 0x0590 && code <= 0x08ff)      // иврит, арабица
          || (code >= 0x0e00 && code <= 0x0fff);     // тайский, тибетский
    });
    assert.deepEqual([...new Set(stray)], [],
      `the Russian text contains characters from another script: ${[...new Set(stray)].join(' ')}`);
  });

  test('every source it cites resolves, and every source it lists is cited', () => {
    // Сноска без определения выглядит как ссылка на источник и не является ею:
    // markdown печатает «[^tag]» как есть, и утверждение остаётся голым. Живость
    // адресов здесь не проверяется — для этого нужна сеть, а проверки идут и
    // без неё; проверяется то, что ломается при правке: разъехавшиеся пары.
    const refs = new Set([...doc.matchAll(/\[\^([a-z0-9-]+)\](?!:)/g)].map((m) => m[1]));
    const defs = new Set([...doc.matchAll(/^\[\^([a-z0-9-]+)\]: /gm)].map((m) => m[1]));
    assert.ok(refs.size >= 10, `found only ${refs.size} citations — the check would be hollow`);

    const undefined_ = [...refs].filter((tag) => !defs.has(tag));
    assert.deepEqual(undefined_, [], `cited but never defined: ${undefined_.join(', ')}`);

    const unused = [...defs].filter((tag) => !refs.has(tag));
    assert.deepEqual(unused, [], `defined but never cited: ${unused.join(', ')}`);

    // Определение без адреса — это «мы что-то читали», а не источник.
    const addressless = [...doc.matchAll(/^\[\^([a-z0-9-]+)\]: (.*)$/gm)]
      .filter(([, , body]) => !/https?:\/\//.test(body))
      .map(([, tag]) => tag);
    assert.deepEqual(addressless, [],
      `sources with no address, so nothing can be checked: ${addressless.join(', ')}`);
  });

  test('the recurring defect class is recorded with real cases', () => {
    // Раздел стоит не ради красивого обобщения: он предсказывает, где
    // появится следующая ошибка того же рода. Обобщение без случаев быстро
    // превращается в лозунг, поэтому проверяется, что случаи на месте и что
    // они настоящие — каждый из них лежит починенным в истории.
    const section = doc.slice(doc.indexOf('Одна форма ошибки повторяется'));
    assert.ok(section.length > 400, 'the recurring-defect section is missing or a stub');

    for (const seen of ['Удалено', '502', 'unknown', 'служебные слова']) {
      assert.ok(section.includes(seen),
        `the section no longer cites the ${seen} case`);
    }
    // Правило важнее таблицы: таблица стареет, правило переносится на новое.
    assert.match(section, /найдите\s+случай, когда исхода не было/,
      'the rule the table exists to support is gone');
  });

  test('no stray CJK crept into Russian comments or copy', () => {
    // Уже случалось дважды: «на котором полагается生成 транспортный токен» в
    // документе и «принесёт三сотни символов» в комментарии теста. Опечатка
    // такого рода не видна при беглом чтении, не ломает сборку и сообщает
    // читателю ровно одно: текст писали невнимательно.
    //
    // Три файла — исключение и перечислены поимённо: это проверки того, как
    // продукт обходится с китайским текстом, и иероглифы там по делу. Список
    // закрытый, чтобы новый случайный иероглиф всплыл.
    const deliberate = new Set([
      'app/Tests/MeetGPTTests/LLMStreamingClientTests.swift',
      'app/Tests/MeetGPTTests/LoopbackCallbackTests.swift',
      'app/Tests/MeetGPTTests/AssistantDOCXExporterTests.swift',
    ]);

    const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const full = resolve(dir, entry.name);
      if (entry.isDirectory()) {
        return /(^|\/)(\.build|build|node_modules|\.git)$/.test(full) ? [] : walk(full);
      }
      // Только .swift и страница: под Resources/Skills лежат готовые
      // определения навыков с китайскими подсказками — они там по делу, и
      // это не русская проза, за которой тут следят.
      return /\.swift$/.test(entry.name) ? [full] : [];
    });

    const offenders = [];
    for (const dir of ['mvp', 'app/Sources/MeetGPT', 'app/Tests']) {
      for (const file of walk(resolve(repo, dir))) {
        const relative = file.slice(repo.length + 1);
        if (deliberate.has(relative)) continue;
        const stray = [...new Set([...readFileSync(file, 'utf8')].filter((ch) => {
          const code = ch.codePointAt(0);
          return code >= 0x3000 && code <= 0x9fff;
        }))];
        if (stray.length) offenders.push(`${relative}: ${stray.join('')}`);
      }
    }
    for (const file of ['public/index.html', 'README.md', 'CONTRIBUTING.md']) {
      const stray = [...new Set([...readFileSync(resolve(repo, file), 'utf8')].filter((ch) => {
        const code = ch.codePointAt(0);
        return code >= 0x3000 && code <= 0x9fff;
      }))];
      if (stray.length) offenders.push(`${file}: ${stray.join('')}`);
    }

    assert.deepEqual(offenders, [],
      `Russian text carries characters from another script:\n  ${offenders.join('\n  ')}`);
  });

  test('the VoIP verdict names all four platforms and says what blocks each', () => {
    // Бриф прямо просит коннекторы к ВКС. Ответ «их нет» без причины — это не
    // ответ, и через месяц кто-нибудь начнёт писать их заново. Раздел обязан
    // назвать все четыре и по каждой — что именно мешает.
    const section = doc.slice(doc.indexOf('## 11. ВКС'));
    assert.ok(section.length > 500, 'the VoIP section is missing or a stub');
    for (const platform of ['Телемост', 'VK Teams', 'TrueConf', 'SaluteJazz']) {
      assert.ok(section.includes(platform),
        `the VoIP verdict does not mention ${platform}`);
    }
    // И должно быть сказано, что запись звонка при этом работает — иначе
    // раздел читается как «продукт не работает с российскими ВКС».
    assert.match(section, /системным захватом/,
      'the section does not say local capture still works on all four');
  });

  test('the blueprint lists the error cases the connector actually has', () => {
    // Чертёж перечисляет виды ошибок и объясняет, чем каждый чинится. Список
    // отстал на один случай, пока не заметили: `vendor` появился в коде, а в
    // чертеже осталось четыре имени. Читатель чертежа тогда не знает, что
    // делать с пятым — и, что хуже, не знает, что тот есть.
    const src = readFileSync(
      resolve(repo, 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8');
    const block = src.slice(src.indexOf('public enum TrackerError'));
    const cases = [...block.slice(0, block.indexOf('\n        }')).matchAll(/case ([a-zA-Z]+)/g)]
      .map(([, name]) => name);
    assert.ok(cases.length >= 4, `found ${cases.length} error cases — the check would be hollow`);

    const blueprint = doc.slice(doc.indexOf('### 2.2'));
    const section = blueprint.slice(0, blueprint.indexOf('\n## '));
    for (const name of new Set(cases)) {
      assert.ok(section.includes(name),
        `the connector can fail with ${name}, and the blueprint never mentions it`);
    }
  });

  test('the moderation claim on the page keeps its source in the plan', () => {
    // Бриф спрашивал про предвзятость модерации отдельно. Претензии взяты из
    // обсуждения правил самого Хабра, а не из чужого пересказа, и страница
    // повторяет их. Утверждение без источника через месяц не отличить от
    // мнения — здесь они держатся вместе.
    const html = readFileSync(resolve(repo, 'public', 'index.html'), 'utf8');

    assert.match(doc, /habr\.com\/ru\/companies\/habr\/articles\/1019036/,
      'the plan lost the thread the moderation complaints came from');
    assert.match(doc, /прочитано 2026-\d{2}-\d{2}/,
      'the moderation reading has no date, so nobody knows how stale it is');

    // Три механизма — не риторика, а то, что реально называют авторы.
    for (const mechanism of [/карм/i, /корпоративн/i, /оспорить|обжалован/i]) {
      assert.match(doc, mechanism, `the plan dropped a named moderation mechanism: ${mechanism}`);
    }

    // Страница обязана говорить то же, что план, а не сильнее.
    if (/модерац/i.test(html)) {
      assert.match(html, /карм/i,
        'the page mentions moderation without the concrete mechanism the plan records');
    }
  });

  test('the tracker census matches the trackers that actually ship', () => {
    // Перепись — таблица «подключён / нет» с причинами. Такие таблицы устаревают
    // первыми: сервис доезжает до кода, а строка остаётся прежней. Здесь она
    // сверяется с типом: каждый сервис из `RussianTrackers.Service` обязан
    // стоять в таблице со словом «подключён», и наоборот.
    const src = readFileSync(
      resolve(repo, 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8');
    const block = src.slice(src.indexOf('public var title: String'));
    const shipped = [...block.slice(0, block.indexOf('}\n\n')).matchAll(/return "([^"]+)"/g)]
      .map(([, title]) => title);
    assert.ok(shipped.length >= 4, `found ${shipped.length} titles — the census would be hollow`);

    const census = doc.slice(doc.indexOf('### 2.0.3'));
    const table = census.slice(0, census.indexOf('\n\n###'));

    for (const service of shipped) {
      const row = table.split('\n').find((line) => line.startsWith(`| ${service} `));
      assert.ok(row, `${service} ships and is missing from the census`);
      assert.match(row, /подключён/,
        `${service} ships, and the census does not say so: ${row}`);
    }

    // Обратная сторона: строка «подключён» про сервис, которого в коде нет.
    const claimed = table.split('\n')
      .filter((line) => /^\| .+ \| подключён/.test(line))
      .map((line) => line.split('|')[1].trim());
    for (const name of claimed) {
      assert.ok(shipped.includes(name),
        `the census calls ${name} connected, but no such service ships`);
    }
  });

  test('keeps the dead ends recorded, with the date they were checked', () => {
    // The doc's real value is that impossible things stay recorded as
    // impossible — Pyrus, WEEEK, Telegram history, keyless GitHub OAuth.
    // Without that, each one gets re-attempted by the next person. Dates
    // matter because "we checked" ages, and the reader deserves to know how
    // old the check is.
    for (const deadEnd of [/Pyrus/, /WEEEK/, /Telegram/, /GitHub/, /Мегаплан/, /GigaChat/]) {
      assert.match(doc, deadEnd, 'a researched dead end vanished from the doc');
    }

    // Тупик без причины — это «мы не стали», а не результат исследования.
    // У каждого должно быть сказано, что именно закрыло путь.
    for (const [name, cause] of [['Мегаплан', /долгоживущего ключа нет/i],
                                 ['GigaChat', /Russian Trusted Root CA/]]) {
      assert.match(doc, cause, `${name} is listed as a dead end with no stated cause`);
    }
    const dated = doc.match(/проверено \d{4}-\d{2}-\d{2}/g) ?? [];
    assert.ok(dated.length >= 3,
      `only ${dated.length} findings carry a verification date; they all should`);
  });
});
