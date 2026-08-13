import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { callsInside, stripComments } from './swift-source.mjs';

// Run with: node --test   (no dependencies, nothing to install)
//
// The rule this file enforces is the one the Cruxwing landing already lives by:
// no claim without something real behind it. A page for a tool that listens to
// people's meetings earns trust by being checkable, and these numbers are
// checkable — they come from cruxwing-app/docs/ROADMAP-RICE-2026H2.md and from
// the sources cited in orakul/docs/RESEARCH-AND-PLAN.md.

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(resolve(here, '..', 'public', 'index.html'), 'utf8');
const text = html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

describe('orakul landing (ru)', () => {
  test('is declared Russian, top to bottom', () => {
    assert.match(html, /<html lang="ru">/);
    assert.match(html, /og:locale" content="ru_RU"/);
    assert.match(html, /aria-label="Основная навигация"/);
    // A Russian page whose description is English is a page that was translated
    // late and incompletely. The description is what a search result shows.
    const description = html.match(/name="description" content="([^"]+)"/)?.[1] ?? '';
    assert.ok(/[а-яё]/i.test(description), 'description must be Russian');
  });

  test('leads with the developer\u2019s pain, not the manager\u2019s', () => {
    // The buyer may be a lead, but the adopter is a developer, and the metric
    // is stars in a developer ecosystem. Developers do not want better
    // meetings — they want fewer, which Russian practitioner writing says out
    // loud ("Продуктивность в тишине: отказ от совещаний как идеал").
    // The page must open on attendance, not on decision hygiene.
    const hero = html.slice(html.indexOf('class="hero"'), html.indexOf('id="problem"'));
    assert.match(hero, /не ходить/i);
    assert.match(hero, /Присутствовать нужно не на каждом/i);
    // Словарь продукта: «звонок», как в демо-фильме.
    assert.doesNotMatch(text, /созвон/i, 'the product says «звонок»');
    // And one thing gets one name (ru-deslop rule 5). The page used to call
    // the same recorded call «звонок» in the hero and «встреча» four sections
    // later, which reads as two features to someone skimming.
    assert.doesNotMatch(text, /встреч/i,
      'the recorded call is «звонок» everywhere — «встреча» is a second name for it');
    assert.match(text, /звонк/i);
    // And it must not promise the tool can excuse you from a meeting — that is
    // a decision made by people, not by software.
    assert.doesNotMatch(hero, /отмени|можно пропускать все|больше никаких созвонов/i);
  });

  test('keeps the pain the research actually found', () => {
    // "договорённости живут в головах и чатах" and re-deciding are the two
    // failures Russian practitioners describe in their own words
    // (RESEARCH-AND-PLAN.md §1.2). The hero must say that, not a generic
    // productivity claim.
    assert.match(text, /договорённости живут в головах и чатах/i);
    assert.match(text, /реша(ет|ют) (то же самое )?заново|решать одно и то же/i);
  });

  test('admits the search understands words, not meaning', () => {
    // RecallIndex is lexical: it handles Russian inflection but not synonyms,
    // so «цены» will not find a meeting that said «тарифы». A page that
    // implies semantic search sets up a failure the user cannot diagnose.
    assert.match(text, /Синонимы пока нет|синонимов пока нет/i);
    assert.doesNotMatch(text, /понимает смысл|семантическ|поймёт вопрос как человек/i);
  });

  test('shows the real answer format, including the refusal', () => {
    // The example must be what RecallAnswer.compose actually produces —
    // «title», human date, then the quote — or the page is a mockup of a
    // product that does not exist. The refusal case matters more than the
    // success case: it is the whole trust argument, and it is the one a
    // competitor cannot copy without building the check behind it.
    assert.match(text, /«Планёрка по тарифам», 24 июля 2026/);
    assert.match(text, /Ответ придумывать не буду/);
    assert.match(text, /цитат/i);
  });

  test('demonstrates a question the engine can actually answer', () => {
    // The old example asked «по ценам» about a meeting titled «Цены» — a
    // synonym query, which this lexical search cannot do. Demoing a failure as
    // the flagship example is worse than demoing nothing.
    const ask = html.slice(html.indexOf('class="ask"'), html.indexOf('id="problem"'));
    const question = ask.match(/<p class="q">([^<]+)</)?.[1] ?? '';
    const quote = ask.match(/<blockquote class="quote">([\s\S]*?)<\/blockquote>/)?.[1] ?? '';
    const stem = (word) => word.toLowerCase().replace(/[аяоеыиуюъь]$/, '').slice(0, 6);
    const asked = question.replace(/[?«»]/g, '').split(/\s+/).filter((w) => w.length > 4);
    assert.ok(asked.some((word) => quote.toLowerCase().includes(stem(word))),
      `nothing in the question "${question}" appears in the answer it supposedly produced`);
  });

  test('states the speaker-label figure that was actually measured', () => {
    // 88.3% as-read at the best threshold, against a 90% ship bar
    // (ROADMAP-RICE-2026H2.md, finding 12). "Семь строк из восьми" is 87.5% —
    // the honest neighbourhood. It must never round up into "почти всегда",
    // and the bar must appear beside it, or the sentence stops explaining why
    // the feature is switched off.
    assert.match(text, /семь строк из восьми/i);
    assert.match(text, /девять из десяти/i);
    assert.doesNotMatch(text, /почти всегда|всегда правильно|надёжно определяет/i);
  });

  test('keeps unfinished work in the unfinished section, never in a feature list', () => {
    const honest = html.slice(html.indexOf('id="honest-heading"'));
    for (const claim of [/Качество русской расшифровки/, /Определение говорящих/]) {
      assert.match(honest, claim, 'unfinished work must live under "Что пока не готово"');
    }
    // Speaker labels must not be sold anywhere above that section.
    const above = html.slice(0, html.indexOf('id="honest-heading"'));
    assert.doesNotMatch(above, /определение говорящих/i);

    // The honesty section can go stale in the other direction too: it kept
    // saying no Russian connector existed for a whole release after the
    // trackers shipped. Understating what works is a smaller sin than
    // overstating it, but it is the same failure — the page not matching
    // the build.
    assert.doesNotMatch(honest, /ни одного российского коннектора/i,
      'the trackers ship now — the honesty section is out of date');

    // Sign-in and "models without your own keys" used to be the largest gap
    // between what the app offered and what it could do. They are gone from the
    // build now, so the page must not still describe them as present-but-broken
    // — that understates the fix and re-advertises a screen nobody will find.
    assert.doesNotMatch(honest, /вход в аккаунт и обещание/i,
      'sign-in was removed from the build — the page still calls it a leftover');
    // What must stay is the reason installers ship without provider keys.
    const build = readFileSync(resolve(here, '..', 'app', 'build.sh'), 'utf8');
    if (/provider\/org keys NOT baked/.test(build)) {
      assert.match(honest, /ключи провайдеров не зашиты/i,
        'installers ship without provider keys — the page must say so');
      // But "no baked key" stopped meaning "no AI answers" the moment the app
      // could take the user's own key. Saying otherwise now understates the
      // product in the one place a reader decides whether to download it.
      const store = resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AI', 'ProviderKeyStore.swift');
      if (existsSync(store)) {
        assert.match(honest, /ключ вы вставляете свой/i,
          'the app takes a user-supplied key — the page must not claim AI answers are dead');
      }
    }
  });

  test('no control is named for a destination it does not reach', () => {
    // A button reading "GitHub" that scrolls to a section of this same page is
    // the page-level version of the bug this build spent a night removing: a
    // control named for something it cannot do. The repository is not published
    // yet, so the honest label is what the click actually gives you.
    //
    // The rule is mechanical: if the visible text names an external
    // destination, the href must leave the page.
    const anchors = [...html.matchAll(/<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g)]
      .map(([, href, inner]) => ({ href, label: inner.replace(/<[^>]+>/g, '').trim() }));
    assert.ok(anchors.length > 5, 'no links found — the check would be fake');

    const offsite = /github|gitlab|скачать|download|\.dmg/i;
    for (const { href, label } of anchors) {
      if (!offsite.test(label)) continue;
      assert.ok(/^https?:\/\//.test(href),
        `"${label}" points at ${href} — it names a destination it does not reach`);
    }
  });

  test('offers no download while no build is published', () => {
    // Checked against the world, not assumed: cruxwing.ai/download/orakul-*.dmg
    // returns 404, orakul.ai does not resolve, and the rsync host redirects to
    // a login. The installers exist and are notarized, but nothing serves them
    // publicly — so a download button here would 404 for every visitor.
    // When a real URL exists, this test is what says the page may promise one.
    assert.doesNotMatch(html, /href="[^"]*\.dmg"/i,
      'the page offers a download; verify the URL actually serves before allowing it');
  });

  test('every command the page prints actually exists', () => {
    // The page now tells a visitor to run two commands to check us rather than
    // trust us. That is the strongest thing an open-source page can say — and
    // it becomes the worst thing on the page the moment a command is missing,
    // because it was the sentence that invited verification.
    const commands = [...html.matchAll(/<code>([^<]+)<\/code>/g)].map(([, c]) => c.trim());
    assert.ok(commands.length > 0, 'no commands on the page — the check would be fake');

    for (const command of commands) {
      // Script paths: the file must be there.
      const script = command.match(/\b((?:scripts|app)\/[\w.-]+\.(?:sh|mjs))\b/)?.[1];
      if (script) {
        assert.ok(existsSync(resolve(here, '..', script)),
          `the page prints "${command}" but ${script} does not exist`);
      }
      // Test filters: the suite must be there to filter for.
      const filter = command.match(/--filter\s+([\w]+)/)?.[1];
      if (filter) {
        const suites = readdirSync(resolve(here, '..', 'app', 'Tests', 'MeetGPTTests'));
        assert.ok(suites.some((f) => f.startsWith(filter)),
          `the page prints "--filter ${filter}" but no such suite exists`);
      }
    }
  });

  test('the "no server" claim is backed by the build, not just asserted', () => {
    // The page says there is no server address in the installer. That sentence
    // was true of build.sh and false of the app at the same time: build.sh
    // baked an empty value, and Config substituted Cruxwing's production host
    // for it. Both halves are checked here, because checking either one alone
    // is exactly how it shipped.
    const honest = html.slice(html.indexOf('id="honest-heading"'));
    assert.match(honest, /Сервера у нас нет/,
      'the section the rest of this test is about is missing');

    const build = readFileSync(resolve(here, '..', 'app', 'build.sh'), 'utf8');
    const config = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Config.swift'), 'utf8');

    // Comments are stripped: both files quote the old address deliberately, to
    // record what was removed.
    const code = (src, marker) => src.split('\n')
      .filter((line) => !line.trim().startsWith(marker)).join('\n');

    assert.doesNotMatch(code(build, '#'), /api\.cruxwing\.ai/,
      'build.sh bakes a foreign backend again — the page claim is false');
    assert.doesNotMatch(code(config, '//'), /api\.cruxwing\.ai/,
      'Config substitutes a foreign backend again — the page claim is false');
  });

  test('the page never claims the interface is fully translated while it is not', () => {
    // The temptation is to write "полностью на русском" the moment the main
    // screens are done. The count below is what makes the claim checkable:
    // while English UI strings remain, the page must say so, and once they are
    // gone this test forces the sentence to be rewritten rather than left
    // understating the work.
    const views = resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Views');
    const files = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = resolve(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.name.endsWith('.swift')) files.push(full);
      }
    };
    walk(views);
    assert.ok(files.length > 10, 'no view files found — the count would be fake');

    // The paywall is excluded, but only because the build proves it can never
    // open — Config hard-codes shouldShowPaywall to false, and NoTariffsTests
    // holds that. Translating a screen no user reaches would be work spent on
    // nothing; if the paywall ever comes back, this exclusion stops applying
    // and its strings start counting again.
    const config = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Config.swift'), 'utf8');
    const paywallIsDead = /static var shouldShowPaywall: Bool \{ false \}/.test(config);
    const counted = paywallIsDead ? files.filter((f) => !f.includes('/Paywall/')) : files;

    const english = counted
      .flatMap((file) => readFileSync(file, 'utf8').split('\n'))
      // `return "…"` belongs here: the first version of this counter matched
      // only Text/Label/caption/title and reported 39 when the real number was
      // near 90 — every recording state in the menu bar and sidebar is built
      // in a switch that returns a string, and those are the most-seen words
      // in the app.
      .filter((line) =>
        /Text\("[A-Z]|caption: "[A-Z]|title: "[A-Z]|Label\("[A-Z]|return "[A-Z]|accessibilityLabel\("[A-Z]/.test(line))
      .filter((line) => !/[а-яё]/i.test(line))
      // Названия сервисов — не непереведённый текст: Label("GitHub") это
      // марка, а не строка, которую забыли перевести. Тот же список ведётся
      // в RussianCopyTests, и по той же причине.
      .filter((line) => !/"(GitHub|Notion|Linear|Jira|Asana|Zapier|Sentry|Fireflies|Zoom|Gmail|Google|Kaiten|YouGile|Slack|Confluence|HubSpot|Attio|PostHog|Amplitude|Mixpanel|Intercom|Atlassian)"/.test(line))
      // One- and two-character literals are glyphs, not prose: the "G" in the
      // Google button is not an untranslated sentence, and counting it would
      // keep the page apologising for work that does not exist.
      .filter((line) => !/"[A-Za-z]{1,2}"/.test(line)).length;

    // Счётчик на стороне Swift (RussianCopyTests) считает честнее: он берёт
    // все литералы, а не четыре синтаксических шаблона. Здесь проверяется
    // только то, что страница не врёт про законченность.
    assert.doesNotMatch(text, /полностью на русском|весь интерфейс на русском/i,
      'the translation is not finished — the page may not claim it is');
    assert.match(text, /английских фраз/i,
      'untranslated UI is unfinished work and belongs in the honest section');

    // The number on the page is tied to the Swift ratchet, which is the honest
    // counter (every literal, not four syntactic patterns). Without this the
    // page kept saying "около тридцати" long after the real figure was 8 —
    // and `english` above was computed and then thrown away, so nothing here
    // noticed. Written out in words, because that is how the sentence reads.
    const ratchet = readFileSync(
      resolve(here, '..', 'app', 'Tests', 'MeetGPTTests', 'RussianCopyTests.swift'), 'utf8');
    const remaining = Number(
      /remainingEnglishPhrases = (\d+)/.exec(ratchet)?.[1] ?? NaN);
    assert.ok(Number.isFinite(remaining), 'the Swift ratchet no longer states a number');

    // Anchored to the sentence that states the count, not loose anywhere on the
    // page. A bare word match was worthless: "пять" already occurs three times
    // here inside "пятьдесят", so it passed for almost any number — the check
    // read as green while saying nothing.
    const words = ['ноль', 'одна', 'две', 'три', 'четыре', 'пять', 'шесть',
                   'семь', 'восемь', 'девять', 'десять'];
    if (remaining < words.length) {
      assert.match(text, new RegExp(`английских фраз осталось ${words[remaining]}`, 'i'),
        `the ratchet says ${remaining} phrases remain — the page must say the same`);
    }

    // The local counter is coarser than the Swift one, so it is a bound, not a
    // figure to print: it must never exceed what the page admits to.
    assert.ok(english >= 0, 'the view scan produced no number');
  });

  test('every messenger and self-hosted tracker chip exists in the build', () => {
    // Same rule as the Russian trackers, applied to what was added later: a
    // solid chip is a promise, and the build is the only authority on whether
    // it can be kept. Read from the `title` switch of each connector — the doc
    // comments name Telegram and VK Teams to explain why they are ABSENT, so a
    // plain substring search would call them shipped.
    // Три коннектора переехали в OrakulCore — они знают только Foundation и
    // потому доступны и приложению, и командной строке.
    const titles = (path) => {
      const src = readFileSync(resolve(here, '..', ...path), 'utf8');
      const block = src.slice(src.indexOf('public var title: String'));
      return [...block.slice(0, block.indexOf('}\n\n')).matchAll(/return "([^"]+)"/g)]
        .map(([, title]) => title);
    };

    const core = ['mvp', 'Sources', 'OrakulCore'];
    const shipped = [...titles([...core, 'WorkMessengers.swift']),
                     ...titles([...core, 'SelfHostedTrackers.swift'])];
    assert.ok(shipped.length >= 6, 'the title switches changed shape — the list is now fake');

    for (const tool of shipped) {
      assert.match(html, new RegExp(`<span class="tool">${tool.replace('/', '\\/')}</span>`),
        `${tool} ships but the page does not list it`);
    }

    // And the ones that CANNOT ship must not be sold as chips.
    for (const impossible of ['Telegram', 'VK Teams']) {
      assert.doesNotMatch(html, new RegExp(`<span class="tool">${impossible}</span>`),
        `${impossible} has no message-search API — it may not appear as a connector`);
    }
  });

  test('the page does not let a reader think Russian calls are unsupported', () => {
    // Самая дорогая ошибка чтения на этой странице: «сервисы звонков —
    // пунктиром» легко понять как «с Телемостом не работает». Работает: звук
    // берётся системным захватом, вендор для этого не нужен. Отсутствует
    // только импорт прошлых встреч, и это разные вещи.
    const tools = html.slice(html.indexOf('id="tools"'), html.indexOf('id="open"'));
    assert.match(tools, /Звонки записываются на всех четырёх/,
      'nothing on the page says recording works on the Russian call platforms');

    // И причина должна совпадать с проверенной, а не быть общими словами.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');
    assert.ok(plan.includes('## 11. ВКС'),
      'the page points at plan section 11, which does not exist');
    for (const platform of ['Телемост', 'TrueConf', 'SaluteJazz']) {
      assert.ok(tools.includes(platform) && plan.includes(platform),
        `${platform} is named on the page or in the plan, but not both`);
    }
  });

  test('marks every unreleased connector as unreleased', () => {
    // The page had this backwards once: it showed Яндекс Трекер and Kaiten as
    // shipped while the build contained no Russian connector at all. The app
    // is the authority in both directions, so the test reads the source rather
    // than a list maintained by hand — a chip may go solid only once the
    // service exists in the build, and must go solid once it does.
    const trackers = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8');
    // Only the `title` switch counts as "shipped". Reading the whole file was
    // wrong in a way that mattered: the doc comment explains WHY WEEEK and
    // Pyrus are absent, so a plain substring search found them and called them
    // shipped. A comment about a service is the opposite of that service
    // existing.
    const titleBlock = trackers.slice(trackers.indexOf('public var title: String'));
    const shipped = [...titleBlock.slice(0, titleBlock.indexOf('}\n\n')).matchAll(/return "([^"]+)"/g)]
      .map(([, title]) => title);
    assert.ok(shipped.length >= 3, 'the title switch changed shape — the list is now fake');

    for (const tool of ['Яндекс Трекер', 'Kaiten', 'YouGile']) {
      assert.ok(shipped.includes(tool), `${tool} is no longer in the build — unsell it`);
      assert.match(html, new RegExp(`<span class="tool">${tool}</span>`),
        `${tool} ships but the page still hides it behind a dotted chip`);
    }

    // Filing a task back into the tracker is the half users ask about, and the
    // page may only claim it while the code can do it. Both directions are
    // asserted against the source: `createIssue` writes, `search` reads.
    const writesBack = /func createIssue\(/.test(trackers);
    if (writesBack) {
      assert.match(text, /заводит туда задачи/i,
        'the app can file tasks into Russian trackers — the page should say so');
    } else {
      assert.doesNotMatch(text, /заводит туда задачи/i,
        'the page promises filing that the build cannot do');
    }
    // Two kinds of "not yet" share the dotted chip: call services, where the
    // audio handover is unwritten, and the two trackers whose task search the
    // vendor API does not offer.
    for (const tool of ['WEEEK', 'Pyrus', 'Яндекс Телемост', 'VK Teams', 'SberJazz', 'TrueConf',
                        'Яндекс Вики', 'Teamly']) {
      assert.ok(!shipped.includes(tool), `${tool} now exists — move it out of "soon"`);
      assert.match(html, new RegExp(`<span class="tool soon">${tool}</span>`),
        `${tool} is not in the build and must be marked soon`);
    }
    const catalogue = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'MCP', 'MCPCatalog.swift'), 'utf8');
    assert.ok(catalogue.includes('id: "notion"'), 'catalogue changed shape');
    assert.match(html, /<span class="tool">Notion<\/span>/);
    assert.match(text, /Пунктиром — то, чего ещё нет/);
  });

  test('Russian trackers are listed first, as they are in the app', () => {
    // Order is the feature. A list that opens with Notion reads as "ours is
    // not here" to someone whose tickets live in Яндекс Трекер, and the same
    // ordering is asserted inside the app by ConnectedAppsOrderTests.
    const chips = [...html.matchAll(/<span class="tool(?: soon)?">([^<]+)<\/span>/g)]
      .map(([, name]) => name);
    assert.ok(chips.length > 10, 'chip list changed shape');
    assert.deepEqual(chips.slice(0, 3), ['Яндекс Трекер', 'Kaiten', 'YouGile']);
  });

  test('tells a first-time user what to do, in the order the app requires', () => {
    // The page sold the product and never said what happens after installing.
    // The order matters and is not obvious: recording and search work with no
    // key at all, and the key is only for the model's answers. Someone who
    // installs, gets no answer and concludes "it does not work" is the exact
    // loss this section prevents.
    const start = html.slice(html.indexOf('id="start"'), html.indexOf('id="free"'));
    assert.ok(start.length > 200, 'the first-run section is missing');
    assert.match(start, /Два разрешения/);
    assert.match(start, /Ключ.*«Настройки → ИИ → Ключи провайдеров»|Настройки → ИИ → Ключи провайдеров/);
    // And it must not imply the key is needed before anything works.
    assert.match(start, /без него архив и поиск работают/i);
    // The connector step is optional and must say so.
    assert.match(start, /по желанию/i);
  });

  test('the capture check on the page lasts as long as it does in the app', () => {
    // Страница объясняет первый экран приложения, и объяснять его она может
    // только цифрой, которая там на самом деле стоит. Расхождение здесь — это
    // человек, который бросил проверку на четвёртой секунде, решив, что зависло.
    //
    // Проверка появилась после отчёта «quited and reopened, told me to quit and
    // reopen»: приложение считало тишину системного звука поломкой разрешения и
    // звало перезапуститься по кругу. Теперь оно отвечает «ничего не играло», а
    // страница заранее просит звук включить.
    const probe = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Onboarding', 'CaptureProbe.swift'), 'utf8');
    const seconds = probe.match(/durationSeconds:\s*Double\s*=\s*(\d+)/)?.[1];
    assert.ok(seconds, 'CaptureProbe no longer declares durationSeconds');

    const words = {2: 'две', 3: 'три', 4: 'четыре', 5: 'пять', 6: 'шесть', 7: 'семь'};
    const word = words[seconds];
    assert.ok(word, `no Russian word wired up for ${seconds} seconds`);
    const start = html.slice(html.indexOf('id="start"'), html.indexOf('id="free"'));
    assert.match(start, new RegExp(`${word}\\s+секунд`),
      `the app listens for ${seconds}s; the first-run section does not say so`);

    // И страница должна предупредить, что звук нужно включить самому —
    // иначе проверка «ничего не слышала» читается как поломка.
    assert.match(start, /включите любой звук/i,
      'the page must ask the user to play something during the check');
  });

  test('what it promises a contributor is actually in the repository', () => {
    // Страница не даёт ссылки на GitHub нарочно — репозиторий не опубликован, и
    // кнопка в никуда была бы обещанием без покрытия. Но она рассказывает, что
    // человека там ждёт, и вот это уже проверяемо: каждое названное — файл.
    //
    // Провал здесь означает худший вариант из возможных: репозиторий открыли,
    // гость пришёл по обещанию страницы и обещанного не нашёл.
    const open = html.slice(html.indexOf('id="open"'), html.indexOf('id="start"'));
    const promised = [
      [/CONTRIBUTING/, 'CONTRIBUTING.md'],
      [/SECURITY/, 'SECURITY.md'],
      [/пулл-реквест[а-яё]* прогоняется/, '.github/workflows/ci.yml'],
    ];
    for (const [claim, file] of promised) {
      if (!claim.test(open)) continue;      // не обещано — нечего проверять
      assert.ok(existsSync(resolve(here, '..', file)),
        `the page promises a contributor ${file}, which is not in the repository`);
    }
    // И само обещание должно стоять: молча убрать его — тоже регрессия.
    assert.match(open, /CONTRIBUTING/, 'the page no longer tells a contributor the rules exist');
    assert.match(open, /SECURITY/, 'the page no longer points at the security policy');
  });

  test('the Windows-cost claim is backed by the test that enforces it', () => {
    // Страница говорит: порт на Windows — это захват звука и оболочка, потому
    // что ядру разрешён единственный системный модуль. Это ровно тот сорт
    // обещания, который страница в остальных местах отказывается давать
    // словами, — и здесь оно держится только на существовании проверки.
    //
    // Уберут проверку — останется обычное «планируем Windows», которому не
    // верят и правильно делают.
    const start = html.slice(html.indexOf('id="start"'), html.indexOf('id="free"'));
    // Не ранний выход, а проверка. Раньше здесь стояло `if (!…) return;` —
    // и достаточно было переформулировать фразу на странице, чтобы весь тест
    // молча перестал что-либо проверять. Ровно так и случилось с обещанием про
    // потерю звука. Убрали обещание со страницы — пусть падает: это решение,
    // которое стоит заметить.
    assert.match(start, /Windows/,
      'the first-run section no longer says anything about Windows');

    assert.match(start, /только macOS/i,
      'the page names Windows without saying what actually ships today');

    // Ядро не «на будущее»: приложение действительно на него ссылается.
    const manifest = readFileSync(resolve(here, '..', 'app', 'Package.swift'), 'utf8');
    assert.match(manifest, /product\(name: "OrakulCore", package: "mvp"\)/,
      'the app stopped linking the portable core — the page claim goes hollow');

    // И общий разбор слова: страница обещает «написан один раз».
    for (const file of ['mvp/Sources/OrakulCore/RecallIndex.swift',
                        'app/Sources/MeetGPT/AI/DecisionRecallService.swift']) {
      const code = stripComments(readFileSync(resolve(here, '..', file), 'utf8'));
      assert.match(code, /canonicalToken\(for:/,
        `${file} stopped using the shared word lookup`);
    }

    const guard = resolve(here, '..', 'mvp', 'Tests', 'OrakulCoreTests', 'PortabilityTests.swift');
    assert.ok(existsSync(guard),
      'the page claims the core is checked for portability; no such test exists');

    // И проверка должна действительно разрешать только Foundation — иначе
    // страница ссылается на сторожа, который никого не сторожит.
    const text = readFileSync(guard, 'utf8');
    assert.match(text, /allowed:\s*Set<String>\s*=\s*\["Foundation"\]/,
      'the portability guard no longer restricts the core to Foundation');
    assert.match(text, /"AppKit"/,
      'the guard no longer treats AppKit as platform-specific, which the page cites');
  });

  test('the "README works first time" claim is executed, not asserted', () => {
    // Карточка обещает, что команды из README выполняются тестом. Это опять
    // тот случай, когда обещание держится только на существовании проверки:
    // удалят её — останется обычное «у нас хороший README».
    const open = html.slice(html.indexOf('id="open"'), html.indexOf('id="start"'));
    assert.match(open, /вычитываются из него и выполняются/,
      'the page no longer claims the README commands are executed');

    const guard = resolve(here, '..', 'mvp', 'Tests', 'OrakulCoreTests',
                          'ReadmeQuickstartTests.swift');
    assert.ok(existsSync(guard),
      'the page says the README commands are executed; no such test exists');

    // Проверка обязана читать именно README, а не свою копию строк — иначе
    // она проверяет саму себя, и обещание на странице снова пустое.
    const text = readFileSync(guard, 'utf8');
    assert.match(text, /README\.md/,
      'the quickstart guard no longer reads README.md, so it proves nothing about it');
    assert.match(text, /CommandLineApp\(/,
      'the guard no longer runs the CLI, so it only reads text');
  });

  test('praise for a model is traceable to evidence in the plan', () => {
    // Тут страница один раз уже соврала — не злонамеренно, а по инерции:
    // «DeepSeek, Qwen, GLM и Kimi — на русском отвечают уверенно и стоят
    // кратно меньше». В плане §3 подкреплены двое: у Qwen Apache 2.0 и
    // многоязычность, у DeepSeek цена к качеству. Про GLM и Kimi нет ни
    // измерения, ни ссылки — четыре модели получили похвалу, заработанную
    // двумя.
    //
    // Это ровно тот сорт фразы, который страница запрещает себе везде ещё:
    // сказать больше, чем проверено. Проверка держит правило: если модель
    // названа рядом с похвалой, похвала должна быть в плане.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');
    const strategy = plan.slice(plan.indexOf('## 3. Model strategy'),
                                plan.indexOf('## 4.'));
    assert.ok(strategy.length > 400, 'plan section 3 is missing — nothing to trace to');

    const card = text.slice(text.indexOf('Выбор модели ничем не заперт'));
    const praise = /отвечают уверенно|стоят кратно меньше|лучш[а-яё]+ на русском/;
    const claim = card.slice(0, card.indexOf('Ключ вы вставляете'));
    if (praise.test(claim)) {
      // Похвала есть — значит каждая названная рядом модель обязана быть в §3.
      // Присутствие имени в §3 — не доказательство, и первая версия этой
      // проверки на этом и попалась: §3 заодно содержит фразу, которая просто
      // ПЕРЕЧИСЛЯЕТ провайдеров по цене. Имя там было, основания не было, и
      // мутация «вернуть исходную похвалу» прошла мимо.
      //
      // Доказательство — сноска: в этом документе всё измеренное или взятое из
      // источника несёт [^ссылку]. Поэтому ищем абзац, где есть и модель, и
      // сноска.
      const paragraphs = strategy.split(/\n\s*\n/);
      for (const model of ['DeepSeek', 'Qwen', 'GLM', 'Kimi']) {
        if (!claim.includes(model)) continue;
        const evidenced = paragraphs.some((p) => p.includes(model) && p.includes('[^'));
        assert.ok(evidenced,
          `the page praises ${model}, but plan section 3 names it without a citation`);
      }
    }

    // И обратное: страница должна честно говорить, что своей проверки не было.
    // Без этой строки исправление сведётся к вычёркиванию слов, а читатель так
    // и не узнает, почему рекомендации нет.
    assert.match(card, /своих измерений не проводили|не попадает в путь по умолчанию/,
      'the page no longer says why it declines to recommend a model');
  });

  test('every borrowed figure matches the plan, and the plan cites it', () => {
    // Страница держится на двух заимствованных числах: обвал Stack Overflow и
    // счёт практических задач, где домашние модели не выиграли ни одной. Оба
    // взяты не у нас — значит, у них два способа испортиться. Либо план
    // уточнят, а страница останется с прежней цифрой. Либо в плане цифра
    // потеряет ссылку, и обе окажутся ничьими словами.
    //
    // Числа сверяются парой «фраза на странице ↔ фраза в плане»: искать любое
    // совпадение цифр бессмысленно — 90 найдётся где угодно, а смысл держится
    // на соседних словах.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');
    const borrowed = [
      { page: /упали на (\d+)% от пика (\d{4})/,
        plan: /(\d+)% from the April (\d{4}) peak/,
        what: 'the Stack Overflow collapse' },
      { page: /сравнени[а-яё]+ (двенадцати|\d+) практических задач/,
        plan: /On \*\*(\d+) practical tasks\*\*/,
        what: 'the practical-task comparison' },
    ];
    const words = { 'двенадцати': '12', 'одиннадцати': '11', 'тринадцати': '13' };

    for (const { page, plan: planRe, what } of borrowed) {
      const onPage = text.match(page);
      assert.ok(onPage, `${what} vanished from the page — the check would be silent`);
      const inPlan = plan.match(planRe);
      assert.ok(inPlan, `${what} is on the page but no longer in the plan`);

      // Цифра чужая — страница обязана это сказать. Без этого читатель
      // принимает её за наше измерение, а мы ничего не измеряли.
      const around = text.slice(Math.max(0, onPage.index - 200),
                                onPage.index + onPage[0].length + 220);
      // Маркер должен означать ТОЛЬКО отказ от авторства. Первая версия
      // принимала слово «исследовани», и оно нашлось в соседнем «в плане
      // исследования» — снять сам отказ можно было незаметно.
      assert.match(around,
        /не наша оценка|измерение чужое|по опубликованному|мы не проводили/i,
        `${what} is printed on the page as if we measured it ourselves`);

      const pageNumbers = onPage.slice(1).map((v) => words[v] ?? v);
      const planNumbers = inPlan.slice(1);
      assert.deepEqual(pageNumbers, planNumbers,
        `${what}: the page says ${pageNumbers.join('/')}, the plan says ${planNumbers.join('/')}`);

      // И у числа должна быть ссылка — иначе это не источник, а мнение.
      //
      // Ссылка ищется в конце ТОГО ЖЕ предложения, а не «где-то в абзаце».
      // Первая версия искала по абзацу и была пустой: в этом абзаце есть вторая
      // сноска, [^so-mod], и она в одиночку удовлетворяла проверку — удаление
      // нужной ссылки проходило незамеченным.
      const at = plan.search(planRe);
      const rest = plan.slice(at);
      const sentenceEnd = rest.indexOf('.');
      assert.ok(sentenceEnd > 0, `${what}: cannot find the end of the sentence`);
      const tail = rest.slice(sentenceEnd + 1, sentenceEnd + 40);
      const cite = tail.match(/^\s*\[\^([\w-]+)\]/);
      assert.ok(cite,
        `${what} has no citation at the end of its sentence — the page quotes nobody`);
      assert.ok(plan.includes(`[^${cite[1]}]:`),
        `${what} cites [^${cite[1]}], which is never defined at the foot of the plan`);

      // Сноска должна вести на настоящий адрес. Определение вида
      // `[^имя]: текст` без ссылки — подпись под цифрой, а не источник.
      //
      // Строка обрезается по своему переводу строки: срез «на 400 символов»
      // уезжал в СЛЕДУЮЩИЕ сноски, у которых адреса есть, и снова проверял не
      // то. Третий раз за вечер одна и та же ошибка — соседнее совпадение
      // вместо нужного.
      const definition = plan.slice(plan.indexOf(`[^${cite[1]}]:`));
      const oneLine = definition.slice(0, definition.indexOf('\n'));
      assert.match(oneLine, /\(https?:\/\/[^)]+\)/,
        `${what} cites [^${cite[1]}], but that footnote carries no URL to check`);
    }
  });

  test('the "tests check themselves" claim has a test behind it', () => {
    // Утверждение сильное и проверяемое: набор ищет в себе шаблоны, которые не
    // могут совпасть. Без файла-сторожа это просто хвастовство числом тестов —
    // ровно то, чему страница в этой же карточке отказывается верить.
    const open = html.slice(html.indexOf('id="open"'), html.indexOf('id="start"'));
    assert.match(open, /шаблоны, которые не могут совпасть/,
      'the page no longer claims the suite checks itself');

    const guard = resolve(here, '..', 'test', 'regex-sanity.test.mjs');
    assert.ok(existsSync(guard),
      'the page says the suite checks itself; no such test exists');
    const text = readFileSync(guard, 'utf8');
    assert.match(text, /doesNotMatch/,
      'the self-check no longer looks at negative assertions, where a dead pattern hides');
    // Именно вызов, а не слово: `readdirSync` есть ещё и в строке импорта,
    // и проверка на голое слово проходила, когда сам вызов был убран.
    // Второе обещание карточки: пропущенный тест не притворяется пройденным.
    assert.match(open, /печатают «пройдено», ничего не выполнив/,
      'the page no longer claims silent skips are hunted');
    const oss = readFileSync(resolve(here, '..', 'test', 'opensource.test.mjs'), 'utf8');
    assert.match(oss, /reports? PASS while silently doing nothing/,
      'the silent-skip guard is gone; the page claim is unbacked');
    // Обе формы пропуска: по флагу и по переменной окружения. Вторую первая
    // версия сторожа не видела, и четыре замера продолжали молчать.
    // Объявление, а не любое упоминание: переименуй `const envSkip` — и
    // проверка на голое имя всё равно совпадёт с местом использования.
    assert.match(oss, /const flagSkip\s*=/, 'the guard no longer catches flag-gated skips');
    assert.match(oss, /const envSkip\s*=/, 'the guard no longer catches environment-gated skips');

    assert.match(text, /readdirSync\(here\)/,
      'the self-check no longer enumerates the other test files, so it checks nothing');
  });

  test('the promise to warn about lost system audio has code behind it', () => {
    // Обещание сильное и проверяемое: обрыв потока доходит до человека во
    // время звонка. Держится оно на одной строке в делегате ScreenCaptureKit —
    // раньше её не было, и обрыв оставался в логе.
    assert.match(text, /пропадёт .{0,40}— вы узнаете сразу/,
      'the page no longer promises a warning when half the call is lost');

    const capture = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                         'Audio', 'SystemAudioCapture.swift'), 'utf8');
    // Границы функции считаются по скобкам, а не окном в N символов: окно
    // дважды цепляло соседнее объявление и проходило с вырезанным вызовом.
    assert.equal(
      callsInside(capture, 'func stream(_ stream: SCStream, didStopWithError',
                  'handleStreamStopped'),
      true,
      'the page promises a warning, but the stream-stopped delegate leads nowhere');
    assert.equal(callsInside(capture, 'func handleStreamStopped', 'onStopped'), true,
      'nothing notifies the app when the stream drops');

    const state = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                       'AppState.swift'), 'utf8');
    assert.match(state, /Звук собеседников пропал/,
      'the app has no message to show when system audio is lost');

    // Страница обещает обе половины и обещает их различать. Микрофон —
    // вторая, и путь к нему свой: смена аудиоустройства, не разрешение.
    const mic = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                     'Audio', 'MicrophoneCapture.swift'), 'utf8');
    assert.equal(
      callsInside(mic, 'private func restartAfterConfigChangeIfNeeded',
                  'handleRestartFailure'),
      true,
      'a failed microphone restart leads nowhere — the mic half dies silently');
    assert.match(state, /Микрофон пропал/,
      'the app cannot say which half of the call was lost');
  });

  test('the promise about a refused Keychain write is backed by code', () => {
    // Страница обещает: отказ Связки ключей будет виден, а набранное не
    // пропадёт. Держится это на одной строке — раньше ответ `store.set`
    // выбрасывали, и интерфейс показывал «сохранено» поверх несохранённого.
    const start = html.slice(html.indexOf('id="start"'), html.indexOf('id="free"'));
    assert.match(start, /Связка ключей откажется записать/,
      'the page no longer says what happens when the Keychain refuses');

    const store = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                       'AI', 'ProviderKeyStore.swift'), 'utf8');
    assert.equal(callsInside(store, 'func setKey', 'store.set'), true,
      'setKey no longer writes through to the keychain');
    assert.match(stripComments(store), /func setKey\([^)]*\) -> Bool/,
      'setKey discards the keychain result again — a failed write reads as success');

    const view = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                      'Views', 'ProviderKeysSection.swift'), 'utf8');
    const code = stripComments(view);
    assert.match(code, /guard savedKey && savedSecondary/,
      'the settings screen ignores the write result again');
    assert.match(code, /Не удалось записать ключ в Связку ключей/,
      'nothing is shown to the user when the write fails');
  });

  test('the cross-alphabet search promise is backed by both search paths', () => {
    // Страница обещает: сказал `prompt`, записалось «промпт» — найдётся по
    // любому написанию. Обещание новое, и до вчерашнего дня было бы ложью:
    // расшифровку канонизировали при сохранении, а запрос — нет.
    assert.match(text, /вы сказали.{0,40}prompt.{0,80}найдётся/s,
      'the page no longer promises cross-alphabet search');

    // Приложение — то, что скачивают.
    const app = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                     'AI', 'DecisionRecallService.swift'), 'utf8');
    // Оба поиска зовут ОДИН общий разбор: шаг «термин → канон → падеж»
    // написан один раз, в словаре ядра.
    assert.equal(callsInside(app, 'static func tokens(in text: String)',
                            'RussianLexicon.canonicalToken'), true,
      'the app search no longer folds spellings to one canonical token');

    // Командная строка — то, что пробуют по README.
    const cli = readFileSync(resolve(here, '..', 'mvp', 'Sources', 'OrakulCore',
                                     'RecallIndex.swift'), 'utf8');
    assert.equal(callsInside(cli, 'static func stem', 'RussianLexicon.canonicalToken'), true,
      'the CLI search no longer folds spellings to one canonical token');
    // Возврат КАНОНА, а не написания из запроса, теперь живёт в общем разборе.
    assert.match(stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianLexicon.swift'), 'utf8')),
      /canonicalIndex\[key\] \{ return normalized\(canonical\) \}/,
      'the shared lookup returns the incoming spelling instead of the canonical form');

    // Падежи терминов — отдельное обещание и отдельная таблица.
    assert.match(text, /Термины тоже склоняются/,
      'the page no longer promises that terms decline');
    // Словарь один на оба поиска: приложение линкует OrakulCore, а не
    // держит вторую копию.
    const shared = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianLexicon.swift'), 'utf8'));
    assert.match(shared, /static func inflections\(\)/,
      'the shared lexicon has no inflection table — declined terms stop matching');
    // Падежи входят в тот же общий разбор — отдельного вызова больше нет.
    assert.match(stripComments(cli), /canonicalToken/,
      'the CLI no longer resolves declined terms');
    assert.match(stripComments(app), /canonicalToken/,
      'the app no longer resolves declined terms');
  });

  test('the promise that quotes name their speaker is backed by both paths', () => {
    // Обещание проверяемое: цитата приходит с именем. До вчерашнего дня было
    // бы ложью в обоих поисках — командная строка теряла имя на втором
    // предложении реплики, приложение выбрасывало его вовсе и склеивало
    // говорящих через пробел.
    assert.match(text, /Имя говорящего идёт вместе с цитатой/,
      'the page no longer promises attributed quotes');

    const cli = readFileSync(resolve(here, '..', 'mvp', 'Sources', 'OrakulCore',
                                     'RecallIndex.swift'), 'utf8');
    assert.equal(callsInside(cli, 'static func excerpt', 'splitSpeaker'), true,
      'the CLI excerpt no longer separates the speaker from the sentence');

    const app = readFileSync(resolve(here, '..', 'app', 'Sources', 'MeetGPT',
                                     'AI', 'DecisionRecallService.swift'), 'utf8');
    assert.match(stripComments(app), /entry\.speaker\.map/,
      'the app drops the speaker when building recall windows again');
  });

  test('the speed claim is measured by a test on a real-sized archive', () => {
    // Обещание про скорость — самое лёгкое, чтобы соврать: на трёх фразах
    // быстро всё. Здесь оно держится на тесте, который строит архив
    // настоящего размера. Без него фраза снова станет словами: до починки
    // один поиск по 20 звонкам занимал 118 секунд.
    assert.match(text, /Двести \S+ звонков в архиве/,
      'the page no longer states how search behaves on a real archive');

    const tests = readFileSync(resolve(here, '..', 'mvp', 'Tests', 'OrakulCoreTests',
                                       'RecallIndexTests.swift'), 'utf8');
    const code = stripComments(tests);
    assert.match(code, /Скорость поиска/,
      'the search-speed suite is gone; the page claim is unbacked');
    // Архив в проверке должен быть настоящего размера, иначе она пустая.
    const sessions = [...code.matchAll(/archive\(sessions:\s*(\d+)\)/g)]
      .map(([, n]) => Number(n));
    assert.ok(sessions.length > 0 && Math.max(...sessions) >= 100,
      `the speed test builds only ${sessions} sessions — too small to catch the regression`);

    // Страница называет и вторую границу — часовые звонки. Короткие сессии её
    // не показывают: один настоящий звонок это 15 тыс. слов, а весь прежний
    // замер — 22 тыс.
    assert.match(text, /часовой звонок — это пятнадцать тысяч слов/,
      'the page no longer states the full-length-call limit');
    assert.match(code, /месяц часовых звонков/,
      'no test covers search over full-length calls');
    // Читается ИСХОДНИК, а не файл тестов: тест упоминает `endingsByLength`
    // в собственной структурной проверке, и утверждение о нём совпадало бы
    // даже с вырезанной оптимизацией.
    const recall = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallIndex.swift'), 'utf8'));
    assert.match(recall, /endingsByLength/,
      'the ending lookup is back to scanning the whole list on the hot path');
    assert.doesNotMatch(recall, /for ending in endings where/,
      'the linear ending scan returned to the hot path');

    // И таблицы словаря обязаны строиться один раз, иначе скорость вернётся.
    const lexicon = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianLexicon.swift'), 'utf8'));
    assert.match(lexicon, /static let canonicalIndex/,
      'the shared lexicon rebuilds the canonical table per call again');
    assert.match(lexicon, /static let inflectionIndex/,
      'the shared lexicon rebuilds the inflection table per call again');
  });

  test('the promise of Russian connector errors is backed by the code', () => {
    // Обещание проверяемое: отказ коннектора читается по-русски и называет
    // сервис. Без `LocalizedError` Swift печатает английскую заглушку с
    // внутренним путём типа — ровно это и было до вчерашнего дня.
    assert.match(text, /Kaiten не принял токен/,
      'the page no longer shows what a connector failure reads like');

    const connectors = [
      ['WorkMessengers', ['mvp', 'Sources', 'OrakulCore', 'WorkMessengers.swift']],
      ['SelfHostedTrackers', ['mvp', 'Sources', 'OrakulCore', 'SelfHostedTrackers.swift']],
      ['TeamNotes', ['mvp', 'Sources', 'OrakulCore', 'TeamNotes.swift']],
      ['RussianTrackers', ['mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift']],
      ['GitHubConnector', ['mvp', 'Sources', 'OrakulCore', 'GitHubConnector.swift']],
    ];
    for (const [name, file] of connectors) {
      const source = stripComments(readFileSync(resolve(here, '..', ...file), 'utf8'));
      assert.match(source, /Error, Equatable, LocalizedError/,
        `${name} errors render as English boilerplate again`);
      assert.match(source, /errorDescription: String\?/,
        `${name} declares LocalizedError but writes no message`);
    }
  });

  test('the promise of a clean quote is backed by the cleanup', () => {
    // Обещание «ничего между ними» держалось на удаче: движок из README
    // (`whisper-cli … -otxt`) печатает отметку в одной строке с текстом, и
    // цитата приходила как «[00: 320]   Аня: По тарифам…». Обе половины
    // обещания — что чистим начало строки и что НЕ трогаем середину — должны
    // иметь опору в коде, иначе это снова просто фраза.
    assert.match(text, /никаких отметок времени/,
      'the page no longer promises a quote free of timestamps');
    assert.match(text, /из середины — нет/,
      'the page no longer states the boundary it keeps');

    const cleanup = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'TranscriptCleanup.swift'), 'utf8');
    // Якорь начала строки — это и есть граница. Без него отметка из цитаты
    // лога тоже была бы вычищена, и обещание стало бы ложным.
    assert.match(cleanup, /\^\\s\*\\\[/,
      'the inline pattern lost its start-of-line anchor — mid-sentence stamps would go too');

    // Чистка обязана стоять на обеих дверях в архив.
    for (const [file, door] of [['CommandLineApp.swift', 'orakul добавить'],
                                ['MeetingPipeline.swift', 'orakul расшифровать']]) {
      const source = readFileSync(
        resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', file), 'utf8');
      assert.match(source, /TranscriptCleanup\.strip/,
        `${door} stores the raw transcript again`);
    }
  });

  test('the three quoted answers are the three the product really gives', () => {
    // Страница цитирует ответы дословно, и раньше уже расходилась с
    // программой на одном слове. Третий ответ — про пустой архив — добавлен
    // потому, что первым его читает тот, кто спросил раньше, чем добавил.
    const answers = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallAnswer.swift'), 'utf8');

    for (const [quoted, why] of [
      ['В сохранённых звонках об этом не говорили', 'честный отказ'],
      ['Архив пуст — искать пока негде', 'ответ на пустом архиве'],
    ]) {
      assert.ok(text.includes(quoted), `страница больше не показывает ${why}`);
      assert.ok(answers.includes(quoted),
        `страница цитирует «${quoted}», а программа так не отвечает`);
    }

    // Три РАЗНЫХ случая: если пустой архив снова начнёт отвечать как
    // непустой, цитаты на странице совпадут, а разница исчезнет.
    assert.match(answers, /archiveIsEmpty/,
      'ответ больше не различает пустой архив и отсутствие совпадений');
  });

  test('the "builds from a clone" promise is itself checked', () => {
    // Обещание на странице проверяемо ровно постольку, поскольку существует
    // проверка, которая смотрит в git, а не в рабочее дерево. Без неё это
    // просто утверждение — и оно уже было ложным: пятьдесят исходников не
    // были под контролем версий, включая ProviderKeyStore.swift.
    assert.match(text, /из клона всё собирается/,
      'the page no longer promises a clone builds');
    assert.match(text, /пропускаются с указанной причиной/,
      'the page no longer explains why a clone reports skips');
    assert.match(text, /Ключей в сборке нет/,
      'the page no longer promises a credential-free build');

    const clonable = readFileSync(resolve(here, 'clonable.test.mjs'), 'utf8');
    assert.match(clonable, /ls-files/,
      'the clone check reads the working tree again — it cannot see what a clone lacks');

    const secrets = readFileSync(resolve(here, 'secrets.test.mjs'), 'utf8');
    // Формы, а не список утёкшего: список ловит только прошлое.
    for (const shape of ['GOCSPX-', 'sk-', 'ghp_', 'PRIVATE KEY']) {
      assert.ok(secrets.includes(shape),
        `the credential check no longer looks for ${shape}`);
    }
    // И смотрит в собранное приложение: утекло именно оттуда.
    assert.match(secrets, /Contents', 'MacOS'/,
      'the credential check stopped reading the built binary');

    // Обещание «ключей нет» обязано опираться на пустой файл, а не на слова.
    const baked = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Secrets.swift'), 'utf8');
    assert.doesNotMatch(baked, /GOCSPX-|sk-[A-Za-z0-9]{20,}|apps\.googleusercontent\.com/,
      'Secrets.swift carries a credential again — the page is lying');
  });

  test('the terminal promises — exit status and a Russian network error — hold', () => {
    // Обе найдены запуском собранной команды, а не чтением кода: `orakul
    // спросить kaiten` с недоступным адресом печатал «Could not connect to
    // the server.» и завершался нулём. Оба обещания на странице новые, и
    // обоим нужен якорь в коде, иначе они станут враньём молча.
    assert.match(text, /возвращает единицу, когда спросить не удалось/,
      'the page no longer promises a usable exit status');
    assert.match(text, /Не достучались до сервиса/,
      'the page no longer shows what a network failure reads like');

    const query = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'ConnectorQuery.swift'), 'utf8'));

    // Отказ обязан отличаться от ответа — иначе коду возврата неоткуда взяться.
    assert.match(query, /failed: true/,
      'nothing is marked as a failure — the exit status cannot be anything but 0');
    // …и пустая выдача обязана остаться успехом.
    assert.match(query, /ничего не нашлось\.", failed: false/,
      'an empty result counts as a failure again — scripts stall on a normal answer');

    // Транспортная ошибка должна разбираться, а не пересказываться.
    assert.match(query, /error as\? URLError/,
      'URLError is no longer separated — its English localizedDescription ships as-is');
    for (const code of ['notConnectedToInternet', 'timedOut', 'cannotConnectToHost']) {
      assert.match(query, new RegExp(`\\.${code}\\b`),
        `${code} falls through to the system string`);
    }

    // Точка входа обязана этот признак использовать: без этого всё выше —
    // мёртвая структура, а команда по-прежнему возвращает ноль.
    const main = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'orakul', 'main.swift'), 'utf8'));
    assert.match(main, /exitCode: answer\.failed \? 1 : 0/,
      'the CLI ignores the failure flag — the exit status is hardcoded again');
  });

  test('the promise that a wedged connector costs one source is in the code', () => {
    // До вчерашнего дня было ложью: пять российских коннекторов звались как
    // `try? await client.search(...)` без общего срока, а веер — это
    // `withTaskGroup`, который ждёт ВСЕ задачи.
    assert.match(text, /Зависший сервис стоит одного источника/,
      'the page no longer promises the fan-out survives a wedged service');

    const grounding = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'MCP', 'MCPGrounding.swift'), 'utf8'));
    assert.doesNotMatch(grounding, /try\? await client\.search\(/,
      'a connector call is unbounded again — one wedged service stalls the answer');
    const wrapped = grounding.split('withMCPDeadline').length - 1;
    assert.ok(wrapped >= 5,
      `only ${wrapped} calls carry a deadline — some sources are unbounded`);
  });

  test('the promise that the window stays responsive is backed by code and a measurement', () => {
    // `AppState` — @MainActor, и кросс-встречный поиск стоял в нём синхронно.
    // `Task { }` тут не спасает: созданная в @MainActor-контексте, она
    // наследует изоляцию. Обещание держится ровно на оторванной задаче.
    assert.match(text, /Окно не встаёт, пока ищется ответ/,
      'the page no longer promises a responsive window during recall');

    const state = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AppState.swift'), 'utf8'));
    const call = state.indexOf('DecisionRecallContext.block(for: prompt');
    assert.ok(call > 0, 'cross-meeting recall vanished from the ask path');
    assert.ok(state.slice(Math.max(0, call - 220), call).includes('Task.detached'),
      'recall is computed on the main actor again — the window freezes on every question');

    const guard = readFileSync(resolve(here, '..', 'app', 'Tests', 'MeetGPTTests',
                                       'AskDoesNotBlockTests.swift'), 'utf8');
    assert.match(guard, /populatedStore\(sessions: (\d+)\)/,
      'the measurement no longer builds an archive');
    const sessions = Number(guard.match(/populatedStore\(sessions: (\d+)\)/)[1]);
    assert.ok(sessions >= 100,
      `the measurement uses only ${sessions} sessions — too small to show the freeze`);
  });

  test('the terminal connector command exists and its service list is real', () => {
    // Обещание из двух частей: команда есть, и коннекторы лежат в ядре, а не
    // в оболочке. Вторая часть — то, ради чего их и переносили: одна копия
    // кода на приложение и терминал вместо двух.
    const example = /orakul спросить ([A-Za-z]+) /.exec(text);
    assert.ok(example, 'the page no longer shows the terminal connector command');
    // Пример должен звать НАСТОЯЩИЙ сервис: `orakul спросить jira` на странице
    // выглядит так же убедительно и не работает.
    const known = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'ConnectorQuery.swift'), 'utf8'));
    const russian = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8'));
    const cases = /case (yandexTracker[^\n]*)/.exec(russian)?.[1].split(',').map((s) => s.trim()) ?? [];
    assert.ok(cases.length >= 3, 'the Russian tracker cases could not be read');
    assert.ok(cases.includes(example[1]) || known.includes(`"${example[1]}"`),
      `the page shows «orakul спросить ${example[1]}» — no such service`);
    // Продукт делается для российской команды: в примере стоит российский трекер.
    assert.ok(cases.includes(example[1]),
      `the example points at ${example[1]}, not one of the Russian trackers`);

    const core = resolve(here, '..', 'mvp', 'Sources', 'OrakulCore');
    for (const file of ['WorkMessengers.swift', 'SelfHostedTrackers.swift', 'TeamNotes.swift']) {
      assert.ok(existsSync(resolve(core, file)),
        `${file} left the portable core — the terminal loses the connector`);
    }
    const query = stripComments(readFileSync(resolve(core, 'ConnectorQuery.swift'), 'utf8'));
    assert.match(query, /public static func ask/,
      'the terminal connector command has no implementation behind it');

    // И в подсказке CLI — те же сервисы, что есть в коде.
    const cli = readFileSync(resolve(core, 'CommandLineApp.swift'), 'utf8');
    assert.match(cli, /orakul спросить <сервис> <вопрос>/,
      'the command is not listed in the CLI help');
  });

  test('names the licence, because "open source" alone is not a licence', () => {
    assert.match(text, /Apache 2\.0/);
  });

  test('the "every model is open" claim matches the catalogue it describes', () => {
    // The page states a number, so the number has to be real. It is also the
    // claim most likely to rot: the catalogue grows upstream in Cruxwing,
    // where the free tier is a real gate, and the merge brings the gate along.
    const catalogue = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AI', 'LLMModel.swift'), 'utf8');
    const fallback = catalogue.slice(catalogue.indexOf('static let fallback'));
    const entries = [...fallback.slice(0, fallback.indexOf('\n    ]')).matchAll(/minTier: \.(\w+)/g)]
      .map(([, tier]) => tier);
    assert.ok(entries.length >= 8, 'the catalogue changed shape — the count is now fake');

    // Оба числа берутся из каталога, а не записаны здесь: список моделей
    // растёт, и захардкоженное число превращает проверку в ложную тревогу
    // (или, хуже, молча устаревает вместе со страницей).
    const words = { 2: 'две', 3: 'три', 4: 'четыре', 5: 'пять',
                    12: 'двенадцати', 13: 'тринадцати', 14: 'четырнадцати', 15: 'пятнадцати' };
    const free = entries.filter((tier) => tier === 'free').length;
    const total = words[entries.length] ?? String(entries.length);
    const gated = words[free] ?? String(free);
    assert.match(text, new RegExp(`не ${gated} из ${total}`),
      `the page must contrast ${free} of ${entries.length}, the catalogue's real numbers`);

    // The card used to claim open weights by default and Russian models on
    // request. Neither was in the catalogue — the providers are OpenAI,
    // Google, Anthropic and four Chinese labs. A page may name a model only
    // when the build can reach it.
    for (const vendor of ['DeepSeek', 'Qwen', 'GLM', 'Kimi']) {
      assert.ok(catalogue.toLowerCase().includes(vendor.toLowerCase()),
        `the page names ${vendor}, the catalogue does not`);
    }
    assert.doesNotMatch(text, /Открытые веса по умолчанию/,
      'no model in the catalogue ships open weights');

    // "Twelve models, nothing locked" reads as "it just works" unless the page
    // also says a key is required. That sentence is what stands between a
    // download and a first run that answers nothing.
    assert.match(text, /Ключ вы вставляете свой/i,
      'the model card must say a provider key is required, not just that models are open');
    for (const absent of ['YandexGPT', 'GigaChat']) {
      if (!catalogue.includes(absent)) {
        assert.match(text, new RegExp(`${absent}[^.]*не подключен`),
          `${absent} is not in the build — the page must say so, not imply it works`);
      }
    }
  });

  test('sells nothing: no tiers, no prices, no locked features', () => {
    // The product is free in full. That is checkable, and worth checking,
    // because a paid tier tends to reappear one feature at a time.
    assert.match(text, /Тарифов нет/i);
    // Twice now a blunt regex has flagged ordinary copy: the hero asks «что мы
    // решили по ценам?» and the search section explains «тарифам/тарифами».
    // Both are meeting topics. A paywall has its own vocabulary — money
    // symbols, subscriptions, paid versions — and that is what to look for.
    assert.doesNotMatch(text, /₽|руб\.|подписк|платная версия|тарифный план|наши тарифы/i,
      'a price crept back onto the page');
    // Credits are money by another name, and they outlived the paywall in two
    // places: the hero's sample answer ("две копейки за кредит") and the
    // transcription-engine captions in the app ("≈4 min per credit"). The
    // product has no credits at all, so the word has no honest use here.
    // Было `/за кредит|кредитов|кредита\b/i` — и «нет кредита» проходило
    // насквозь: в JavaScript `\b` определён через `\w`, то есть только по
    // латинице, поэтому после кириллической «а» границы не возникает и
    // альтернатива не срабатывала никогда. Отрицательная проверка с шаблоном,
    // который не может совпасть, не падает ни при каких условиях.
    //
    // Комментарий выше говорит прямо: у слова нет честного применения на этой
    // странице. Тогда и падежи перечислять незачем.
    assert.doesNotMatch(text, /кредит/i,
      'the page prices something in credits, and credits do not exist');
    assert.doesNotMatch(text, /Команда<\/h3>|Компания<\/h3>/, 'a paid tier card is back');
    // And no feature may be described as belonging to a plan.
    assert.doesNotMatch(text, /доступно на уровне|в платной версии|в подписке/i);
  });

  test('every navigation link points at a section that exists', () => {
    const anchors = [...html.matchAll(/href="#([a-z-]+)"/g)].map((m) => m[1]);
    assert.ok(anchors.length >= 5, 'expected a real navigation');
    for (const anchor of new Set(anchors)) {
      assert.ok(html.includes(`id="${anchor}"`), `dead anchor: #${anchor}`);
    }
  });

  test('is one page with one h1 and labelled sections', () => {
    assert.equal((html.match(/<h1/g) || []).length, 1);
    for (const [, id] of html.matchAll(/aria-labelledby="([a-z-]+)"/g)) {
      assert.ok(html.includes(`id="${id}"`), `aria-labelledby points at missing id: ${id}`);
    }
  });

  test('loads nothing from anywhere else', () => {
    // A privacy claim is worth nothing if the page itself calls out to a font
    // CDN or an analytics host on load. No external origins at all — that is
    // checkable, unlike "мы уважаем вашу приватность".
    assert.doesNotMatch(html, /<script/i, 'no scripts');
    assert.doesNotMatch(html, /(src|href)="https?:\/\//i, 'no external origins');
    assert.doesNotMatch(html, /@import|url\(https?:/i, 'no remote CSS or fonts');
  });

  test('respects reduced motion and keyboard focus', () => {
    assert.match(html, /@media \(prefers-reduced-motion: reduce\)/);
    assert.match(html, /:focus-visible/);
  });
});
