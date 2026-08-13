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

    const suites = readdirSync(resolve(repo, 'app', 'Tests', 'MeetGPTTests'));
    for (const named of doc.match(/\b[A-Z][A-Za-z]+Tests\b/g) ?? []) {
      assert.ok(suites.includes(`${named}.swift`),
        `the doc cites ${named}, which is not a suite in app/Tests/MeetGPTTests`);
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

  test('keeps the dead ends recorded, with the date they were checked', () => {
    // The doc's real value is that impossible things stay recorded as
    // impossible — Pyrus, WEEEK, Telegram history, keyless GitHub OAuth.
    // Without that, each one gets re-attempted by the next person. Dates
    // matter because "we checked" ages, and the reader deserves to know how
    // old the check is.
    for (const deadEnd of [/Pyrus/, /WEEEK/, /Telegram/, /GitHub/]) {
      assert.match(doc, deadEnd, 'a researched dead end vanished from the doc');
    }
    const dated = doc.match(/проверено \d{4}-\d{2}-\d{2}/g) ?? [];
    assert.ok(dated.length >= 3,
      `only ${dated.length} findings carry a verification date; they all should`);
  });
});
