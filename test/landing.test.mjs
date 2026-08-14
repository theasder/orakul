import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { bodyOf, callsInside, stripComments } from './swift-source.mjs';

// Run with: node --test   (no dependencies, nothing to install)
//
// The rule this file enforces is the one the Cruxwing landing already lives by:
// no claim without something real behind it. A page for a tool that listens to
// people's meetings earns trust by being checkable, and these numbers are
// checkable — they come from cruxwing-app/docs/ROADMAP-RICE-2026H2.md and from
// the sources cited in orakul/docs/RESEARCH-AND-PLAN.md.

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(resolve(here, '..', 'public', 'index.html'), 'utf8');

/// Подсказки «где взять ключ» — они видны в настройках рядом с полем, но
/// живут у провайдера, а не в папках интерфейса.
function consoleHints() {
  const model = readFileSync(
    resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AI', 'LLMModel.swift'), 'utf8');
  const body = bodyOf(model, 'var keyConsoleHint: String');
  assert.ok(body, 'the provider key hints are no longer recognisable');
  return [...body.matchAll(/return "([^"]+)"/g)].map((m) => m[1]);
}
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

  test('every test command the PR form asks for is taught in the quickstart', () => {
    // Форма требовала `cd mvp && swift test`, а быстрый старт про mvp молчал:
    // участник, прошедший старт целиком, всё равно не запускал 294 проверки
    // ядра — и узнавал о них из галочки, которую нечем отметить.
    const contributing = readFileSync(resolve(here, '..', 'CONTRIBUTING.md'), 'utf8');
    const template = readFileSync(
      resolve(here, '..', '.github', 'pull_request_template.md'), 'utf8');

    const asked = [...template.matchAll(/- \[ \] `([^`]*(?:swift test|npm test)[^`]*)`/g)]
      .map((m) => m[1].trim());
    assert.ok(asked.length >= 3, `the form asks for ${asked.length} test commands`);

    const quickstart = contributing.slice(contributing.indexOf('## Быстрый старт'));
    const block = quickstart.slice(0, quickstart.indexOf('```', quickstart.indexOf('```') + 3));

    for (const command of asked) {
      // Сверяется исполняемая часть: в старте команды идут с `cd`, в форме —
      // как их набирают. Общее у них — что именно запускается и где.
      const target = command.includes('mvp') ? 'mvp'
        : command.includes('npm') ? 'npm test' : 'swift test';
      assert.ok(block.includes(target),
        `the form asks for "${command}", and the quickstart never shows ${target}`);
    }
  });

  test('the four silent-empty cases the page claims are the four the plan records', () => {
    // Страница называет число закрытых мест. Число на странице устаревает
    // первым: закроют пятое — здесь останется «четыре», и читатель решит, что
    // обход шире, чем он есть.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');

    const words = { 3: 'три', 4: 'четыре', 5: 'пять', 6: 'шесть' };
    // В плане каждое закрытое место названо своим кодом или файлом.
    const closed = ['RussianTrackers', 'SessionStore', 'FirefliesPastCalls']
      .filter((name) => plan.includes(name));
    assert.equal(closed.length, 3, `plan names ${closed.length} of the three modules`);

    // Битрикс — четвёртое: у него отдельная причина, не форма ответа.
    assert.match(plan, /HTTP 200/,
      'the plan no longer records the refusal that arrives with a success code');

    const stated = words[4];
    assert.ok(html.includes(`${stated} таких мест`),
      `the page must state ${stated} closed cases while the plan records four`);

    // И сама формулировка обещания обязана остаться на странице: без неё
    // перечисление превращается в список правок без причины.
    assert.match(html, /Пустота больше нигде не выдаётся за ответ/,
      'the page dropped the claim these four cases are evidence for');
  });

  test('every connector section lists its services from allCases, not by hand', () => {
    // Коннектор, которого нет в настройках, не существует для человека, даже
    // если код к нему написан и закрыт тестами. Проверить это по-настоящему
    // (открыть окно и посмотреть) нельзя без запуска приложения, поэтому
    // проверяется то, от чего зависит появление: список берётся у типа, а не
    // переписан руками. Битрикс24 доехал в настройки только благодаря этому.
    const sections = {
      'RussianTrackersSection.swift': 'RussianTrackers.Service',
      'WorkMessengersSection.swift': 'WorkMessengers.Service',
      'SelfHostedTrackersSection.swift': 'SelfHostedTrackers.Service',
      'TeamNotesSection.swift': 'TeamNotes.Service',
    };
    for (const [file, type] of Object.entries(sections)) {
      const src = readFileSync(
        resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Views', file), 'utf8');
      assert.ok(src.includes(`ForEach(${type}.allCases`),
        `${file} no longer lists ${type} from allCases — a new service would not appear`);
    }
  });

  test('every Russian tracker that ships is listed on the page', () => {
    // Тот же приём, что для мессенджеров и своих серверов: сплошной чип —
    // обещание, и сборка единственный судья, можно ли его сдержать. Для
    // российских трекеров такой проверки не было: Битрикс24 доехал до кода
    // раньше, чем до страницы, и никто бы не заметил.
    const src = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8');
    const block = src.slice(src.indexOf('public var title: String'));
    const titles = [...block.slice(0, block.indexOf('}\n\n')).matchAll(/return "([^"]+)"/g)]
      .map(([, title]) => title);
    assert.ok(titles.length >= 4, `found ${titles.length} tracker titles — the list is now fake`);

    for (const tool of titles) {
      assert.ok(html.includes(`<span class="tool">${tool}</span>`),
        `${tool} ships but the page does not list it`);
    }
  });

  test('GigaChat stays absent from the provider list while the plan says why', () => {
    // Самый очевидный русский вопрос: «а где GigaChat?». Ответ измеренный и
    // лежит в плане; если провайдера когда-нибудь добавят, заметка обязана
    // уйти вместе с ним — иначе страница будет объяснять отсутствие того,
    // что есть.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');
    const model = readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AI', 'LLMModel.swift'), 'utf8');

    const providers = bodyOf(model, 'public enum LLMProvider')
      ?? bodyOf(model, 'enum LLMProvider');
    assert.ok(providers, 'the provider list is no longer recognisable');
    // Варианты перечисления объявляются и через запятую — в этом же файле
    // стоит `case deepSeek, qwen, zhipu, moonshot`. Проверка, ждущая слова
    // сразу после `case`, пропустила бы добавление в такую строку: сначала
    // так и вышло, и мутация «добавили провайдера» прошла зелёной.
    const caseLines = providers.split('\n')
      .filter((line) => /^\s*case\s/.test(line)).join(',');
    const shipsGigaChat = /\bgigaChat\b/.test(caseLines);

    const explained = /GigaChat: не оценка модели/.test(plan);
    assert.equal(shipsGigaChat, !explained,
      shipsGigaChat
        ? 'GigaChat ships, but the plan still explains why it is absent'
        : 'GigaChat is absent and the plan no longer says why');

    if (!shipsGigaChat) {
      for (const host of ['ngw.devices.sberbank.ru', 'api.giga.chat']) {
        assert.ok(plan.includes(host), `the plan stopped naming ${host}`);
      }
      assert.match(plan, /Russian Trusted Root CA/,
        'the plan no longer names the root that macOS does not carry');
      assert.ok(html.includes('GigaChat'),
        'the page never answers the first question a Russian developer asks');
    }
  });

  test('the perf gate documents the same variable the tests read', () => {
    // Бюджеты задержки существуют, проходят и никому не видны: переменная
    // упоминалась только в самих тестах. Правишь поиск, видишь зелёный прогон
    // — а оба набора в нём пропущены и сосчитаны как пройденные.
    //
    // Здесь связываются две половины: имя переменной в тестах и команда в
    // документах. Разъедутся — команда напечатает «пропущено» и промолчит.
    const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const full = resolve(dir, entry.name);
      if (entry.isDirectory()) return walk(full);
      return entry.name.endsWith('.swift') ? [full] : [];
    });
    // Только наборы про скорость: под флагами живут ещё живые пробы
    // коннекторов, диаризация и прогон настоящих моделей — у каждого своя
    // переменная и свой повод, и документировать их одной командой нельзя.
    const perfFiles = walk(resolve(here, '..', 'app', 'Tests'))
      .filter((file) => /Performance[A-Za-z]*\.swift$/.test(file));
    assert.ok(perfFiles.length >= 2, `only ${perfFiles.length} perf file(s) — nothing to document`);

    const names = new Set(perfFiles.flatMap((file) =>
      [...readFileSync(file, 'utf8').matchAll(/environment\["([A-Z_]+)"\]/g)].map((m) => m[1])));
    assert.equal(names.size, 1,
      `perf suites read ${names.size} different variables: ${[...names]}`);
    const variable = [...names][0];

    for (const doc of ['CONTRIBUTING.md', '.github/pull_request_template.md']) {
      const text = readFileSync(resolve(here, '..', ...doc.split('/')), 'utf8');
      assert.ok(text.includes(variable),
        `${doc} never names ${variable}, so the budgets stay invisible`);
      assert.ok(/--filter Performance/.test(text),
        `${doc} names the variable but not a command that runs the gated suites`);
    }

    // Каждый файл про скорость обязан и запираться флагом: незапертый
    // меряет время на занятой машине и падает у случайного участника.
    const unlocked = perfFiles.filter(
      (file) => !/\.enabled\(if:/.test(readFileSync(file, 'utf8')));
    assert.deepEqual(unlocked.map((f) => f.slice(f.lastIndexOf('/') + 1)), [],
      'a perf file runs unconditionally and will flake on a busy machine');
  });

  test('the pull-request template carries every rule CONTRIBUTING enforces', () => {
    // Шесть правил, о которые ломаются чужие правки, лежали только в
    // CONTRIBUTING. Участник узнавал о них из отказа — после того, как вечер
    // уже потрачен. Шаблон повторяет их у поля описания; проверка следит,
    // чтобы седьмое правило не осталось только в документе.
    const contributing = readFileSync(resolve(here, '..', 'CONTRIBUTING.md'), 'utf8');
    const template = readFileSync(
      resolve(here, '..', '.github', 'pull_request_template.md'), 'utf8');

    // Правила — жирные заголовки в своём разделе, а не по всему файлу: выше по
    // тексту тем же способом оформлена подсказка про кеш SwiftPM.
    const section = contributing.slice(
      contributing.indexOf('## Правила, о которые ломаются чужие пулл-реквесты'));
    assert.ok(section.length > 200, 'CONTRIBUTING no longer has the rules section');

    const rules = [...section.matchAll(/^\*\*(.+?)\*\*/gm)].map((m) => m[1].trim());
    assert.ok(rules.length >= 6, `found ${rules.length} rules — the check would be hollow`);

    const missing = rules.filter((rule) => !template.includes(rule));
    assert.deepEqual(missing, [],
      `rules a contributor only learns from a rejection: ${missing.join(' | ')}`);

    // И обратно: пункт в шаблоне без правила в CONTRIBUTING — требование
    // ниоткуда, спорить с которым не с чем.
    const claimed = [...template.matchAll(/- \[ \] \*\*(.+?)\*\*/g)].map((m) => m[1].trim());
    const groundless = claimed.filter((item) => !rules.includes(item));
    assert.deepEqual(groundless, [],
      `template demands what CONTRIBUTING never states: ${groundless.join(' | ')}`);

    // Страница называет их число. Число — первое, что устаревает.
    const words = { 4: 'Четыре', 5: 'Пять', 6: 'Шесть', 7: 'Семь', 8: 'Восемь' };
    const spelled = words[rules.length];
    assert.ok(spelled, `${rules.length} rules — this check has no word for that`);
    assert.match(html, new RegExp(`${spelled} пунктов`, 'i'),
      `there are ${rules.length} rules, and the page says otherwise`);
  });

  test('the Q&A measurement on the page matches the one recorded in the plan', () => {
    // Число, измеренное руками, живёт в двух местах: на странице и в плане.
    // Такие пары и разъезжаются — правят одно, забывают второе. Здесь заодно
    // держится и оговорка: замер названного дня, а не постоянная величина.
    const plan = readFileSync(resolve(here, '..', 'docs', 'RESEARCH-AND-PLAN.md'), 'utf8');

    const planDate = /Измерено нами (\d{4}-\d{2}-\d{2})/.exec(plan);
    assert.ok(planDate, 'the plan no longer says when the Q&A feed was measured');

    const [, year, month, day] = planDate[1].match(/(\d{4})-(\d{2})-(\d{2})/);
    const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
                    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
    const spelled = `${Number(day)} ${months[Number(month) - 1]} ${year}`;
    assert.ok(html.includes(spelled),
      `the plan measured on ${spelled}, and the page does not say so`);

    // Обе ленты должны остаться названными: без адреса замер не перепроверить.
    for (const feed of ['https://qna.habr.com/questions',
                        'https://qna.habr.com/questions/without_answer']) {
      assert.ok(plan.includes(feed), `the plan stopped naming ${feed}`);
    }

    // Число вопросов и число «про разработку» — из одного замера.
    assert.match(plan, /двадцать штук[\s\S]{0,60}семь дней/,
      'the plan no longer states the twenty-questions-over-seven-days measurement');
    assert.match(html, /двадцать штук[\s\S]{0,60}семь дней/,
      'the page no longer states the same measurement as the plan');
  });

  test('the dependency counts README states are the ones the manifests declare', () => {
    // README говорил «внешних зависимостей нет ни одной» прямо перед быстрым
    // стартом. Для `mvp/` это правда, для `app/` — нет: там четыре пакета,
    // и WhisperKit тянется долго. Читатель, собравший `app/`, ждёт клонов
    // репозиториев, о которых ему сказали, что их нет.
    const readme = readFileSync(resolve(here, '..', 'README.md'), 'utf8');
    const count = (manifest) => {
      const src = readFileSync(resolve(here, '..', manifest, 'Package.swift'), 'utf8');
      return [...src.matchAll(/\.package\(url:/g)].length;
    };

    const mvp = count('mvp');
    assert.equal(mvp, 0,
      `mvp declares ${mvp} external package(s) — README promises none`);
    assert.match(readme, /У `mvp\/`[\s\S]{0,80}внешних зависимостей нет ни одной/,
      'README no longer scopes the "no dependencies" promise to mvp');

    // CONTRIBUTING обещало то же самое и так же без оговорки. Участник,
    // читающий его первым, собирает именно `app/` — шаг, который и качает.
    const contributing = readFileSync(resolve(here, '..', 'CONTRIBUTING.md'), 'utf8');
    assert.doesNotMatch(contributing, /зависимостей ставить не нужно ни для одного/,
      'CONTRIBUTING promises no dependencies for every step, including the one that fetches four');

    const app = count('app');
    const words = { 2: 'две', 3: 'три', 4: 'четыре', 5: 'пять', 6: 'шесть' };
    const stated = words[app];
    assert.ok(stated, `app declares ${app} packages — this check has no word for that`);
    assert.match(readme, new RegExp(`У приложения в \`app/\` их ${stated}`),
      `app declares ${app} external packages; README says otherwise`);

    // Прямых четыре, но сборка тянет двадцать семь — столько строк `Fetching`
    // человек и видит. Число живёт в Package.resolved, поэтому проверяется по
    // нему, а не по памяти: сборка из чистого клона 2026-08-13 дала ровно его.
    const resolved = JSON.parse(readFileSync(
      resolve(here, '..', 'app', 'Package.resolved'), 'utf8'));
    const pins = resolved.pins ?? resolved.object?.pins ?? [];
    assert.ok(pins.length > app,
      `Package.resolved lists ${pins.length} pins — fewer than the ${app} direct ones`);
    // Число обязано стоять рядом со словом «пакет». Голое вхождение не
    // годится: в README есть идентификатор из примера, начинающийся на 27,
    // и первая версия проверки прошла на нём, ничего не проверив.
    const saysTotal = new RegExp(`${pins.length}\\s+пакет`);
    for (const [name, text] of [['README.md', readme], ['CONTRIBUTING.md', contributing]]) {
      assert.match(text, saysTotal,
        `the build fetches ${pins.length} packages, and ${name} never says so`);
    }
  });

  test('the systems the page names are the ones CI actually runs on', () => {
    // Страница говорила, что весь набор идёт на macOS. Проверки страницы и
    // README идут на Linux — макбук им не нужен. Мелочь, но это ровно та
    // форма ошибки, за которой тут следят: уверенная фраза о том, чего нет.
    const ci = readFileSync(resolve(here, '..', '.github', 'workflows', 'ci.yml'), 'utf8');
    const runners = [...ci.matchAll(/runs-on:\s*([a-z0-9.-]+)/g)].map((m) => m[1]);
    assert.ok(runners.length >= 2, `CI declares ${runners.length} runner(s) — the claim is unverifiable`);

    const usesMac = runners.some((r) => r.startsWith('macos'));
    const usesLinux = runners.some((r) => r.startsWith('ubuntu'));

    assert.equal(usesMac, /на macOS/.test(html),
      `CI on macOS: ${usesMac}, but the page says otherwise`);
    assert.equal(usesLinux, /на Linux/.test(html),
      `CI on Linux: ${usesLinux}, but the page says otherwise`);
  });

  test('the paired-credential services the page names are the ones the code checks', () => {
    // Страница обещает проверку до запроса. Обещание держится, пока список
    // сервисов на странице и в коде один и тот же.
    const messengers = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'WorkMessengers.swift'), 'utf8');
    const body = bodyOf(messengers, 'public var pairedTokenPrompt: String?');
    assert.ok(body, 'the code no longer marks which services need two values');

    const paired = [...body.matchAll(/case \.([a-zA-Z]+):\s*return "/g)].map((m) => m[1]);
    assert.ok(paired.length >= 2, `only ${paired.length} paired service(s) found`);

    const titles = { rocketChat: 'Rocket.Chat', zulip: 'Zulip' };
    for (const service of paired) {
      const shown = titles[service];
      assert.ok(shown, `${service} needs two values but this check does not know its name`);
      assert.ok(html.includes(shown),
        `${shown} needs two values, and the page never says so`);
    }
  });

  test('the org headers the page names are the ones the app can actually send', () => {
    // Страница обещает, что orakul сам выберет заголовок. Обещание держится,
    // пока обе половины — текст и код — говорят одно и то же.
    const trackers = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8');
    const chooser = bodyOf(trackers, 'static func orgHeader(for organisation: String)');
    assert.ok(chooser, 'the app no longer chooses an organisation header');
    const sendable = [...chooser.matchAll(/"([A-Za-z-]*Org-ID)"/g)].map((m) => m[1]);
    assert.equal(new Set(sendable).size, 2,
      `the app can send ${new Set(sendable).size} organisation header(s): ${sendable}`);

    const named = [...html.matchAll(/<code>([A-Za-z-]*Org-ID)<\/code>/g)].map((m) => m[1]);
    assert.ok(named.length > 0, 'the page stopped naming the organisation headers');
    for (const header of named) {
      assert.ok(sendable.includes(header),
        `the page names ${header}, which the app never sends`);
    }
    for (const header of new Set(sendable)) {
      assert.ok(named.includes(header),
        `the app sends ${header}, but the page never mentions it`);
    }
  });

  test('every card on the page has a heading, not just a paragraph', () => {
    // Абзац, вставленный чуть выше нужной строки, оказался отдельной
    // карточкой без заголовка: тесты прошли, потому что структуру карточек
    // никто не проверял, а на странице она выглядела оборванной.
    //
    // Проверяется заголовок, а не надкатегория: пять карточек обходятся одним
    // <h3>, и требовать «кикер» значило бы придумать правило, которого
    // страница не держится.
    const cards = [...html.matchAll(/<article class="card">([\s\S]*?)<\/article>/g)]
      .map((m) => m[1]);
    assert.ok(cards.length > 3, `too few cards found (${cards.length}) — the markup changed shape`);

    const headless = cards.filter((body) => !/<h[23][^>]*>/.test(body));
    assert.deepEqual(headless, [],
      `${headless.length} card(s) have no heading; first starts: `
      + `${headless[0]?.trim().slice(0, 70)}`);
  });

  test('notarisation credentials are checked before anything is compiled', () => {
    // 2026-08-13 профиль нотаризации пропал из связки, и выяснилось это после
    // сборки и подписи arm64: шесть минут впустую, ошибка из середины
    // конвейера. Проверка ставится первой — иначе она бесполезна.
    const script = readFileSync(resolve(here, '..', 'app', 'notarize.sh'), 'utf8');

    const check = script.indexOf('notarytool history');
    assert.ok(check > 0, 'the preflight credential check is gone');

    // Всё, что стоит денег или времени, обязано идти ПОСЛЕ проверки.
    for (const expensive of ['swift build', 'codesign', 'notarytool submit']) {
      const at = script.indexOf(expensive);
      if (at < 0) continue;
      assert.ok(at > check,
        `"${expensive}" runs before the credential check — the failure would come late`);
    }

    // И сообщение обязано называть команду, которой это чинится.
    assert.match(script, /store-credentials/,
      'the check fails without telling anyone how to fix it');
  });

  test('the documented build produces every disk image the audit checks', () => {
    // Проверка сверяет два DMG, а README до 2026-08-13 описывал сборку одной
    // архитектуры. Кто шёл по README, собирал arm64, оставлял Intel вчерашним
    // и получал от проверки расхождение без объяснения причины.
    const audit = readFileSync(resolve(here, '..', 'scripts', 'audit-dmg.sh'), 'utf8');
    const loop = /for arch in ([^;\n]+); do/.exec(audit);
    assert.ok(loop, 'the audit no longer loops over architectures');
    const distinct = [...new Set(loop[1].trim().split(/\s+/))];
    assert.ok(distinct.length > 0, 'the audit no longer names any architecture');

    const readme = readFileSync(resolve(here, '..', 'README.md'), 'utf8');
    const build = /Сборка установщика: `([^`]+)`/.exec(readme);
    assert.ok(build, 'README no longer states how to build the installer');

    if (distinct.length > 1) {
      assert.ok(build[1].includes('dist-all.sh'),
        `the audit checks ${distinct.length} architectures, but README documents `
        + `"${build[1]}" — following it leaves the others stale`);
    }
  });

  test('every console the page sends you to is the one the app actually names', () => {
    // Страница обещает: адрес рядом с полем ключа — тот же, куда пойдёт
    // запрос. Обещание держится ровно до тех пор, пока кто-нибудь не
    // поправит одну половину. Здесь проверяется, что страница называет
    // международные консоли и что приложение говорит то же самое.
    const promised = [...html.matchAll(/<code>([a-z0-9.-]+\.(?:ai|com|cn))<\/code>/g)]
      .map((m) => m[1]).filter((host) => host !== 'platform.openai.com');
    assert.ok(promised.length >= 2, `the page stopped naming consoles: ${promised}`);

    const hints = consoleHints().join('\n');
    for (const host of promised) {
      assert.ok(hints.includes(host),
        `the page sends people to ${host}, but no provider hint mentions it`);
    }

    // Китайские половины: ключ оттуда отвечает 401 на международном адресе,
    // а регистрация обычно упирается в местный телефон.
    for (const chinaOnly of ['platform.moonshot.cn', 'open.bigmodel.cn']) {
      assert.ok(!html.includes(chinaOnly),
        `the page points at ${chinaOnly} — a Russian developer cannot use a key from there`);
      assert.ok(!hints.includes(chinaOnly),
        `a provider hint points at ${chinaOnly}, which does not match the endpoint`);
    }
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
    // Считается по САМОМУ списку, а не по числу рядом с ним: храповик теперь
    // пришпиливает набор фраз, и число выводится из него. Регулярка на
    // `= (\d+)` после этого перестала совпадать — а страница молча осталась бы
    // с прежней цифрой, если бы проверку не поправили.
    const listed = /deliberateEnglish: Set<String> = \[([\s\S]*?)\n    \]/.exec(ratchet);
    assert.ok(listed, 'the Swift ratchet no longer pins the list of phrases');
    const inViews = listed[1].split('\n').filter((line) => line.trim().startsWith('"')).length;

    // Плюс подсказки «где взять ключ»: они видны в настройках, но лежат у
    // провайдера рядом с адресом запроса, а не в папках интерфейса. Считать
    // надо ОБА источника — иначе страница назовёт число меньше того, что
    // человек видит глазами.
    // Только те, где нет кириллицы: у Zhipu, Qwen и Яндекса подсказки уже
    // по-русски, и числить их в «осталось английских» — приписать себе
    // работу, которая сделана.
    const hints = consoleHints().filter((s) => !/[А-Яа-яЁё]/.test(s)).length;
    assert.ok(hints > 0, 'no provider hints found — the page would undercount');

    const remaining = inViews + hints;

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

  test('the number the page quotes for the racing suite is the real one', () => {
    // Мелкая величина, но живая: страница называет 600 секунд как то, что
    // выставляет один из наборов. Изменят на 300 — страница соврёт в детали,
    // и заметить это будет некому. Тот же случай, что и с «полторы секунды»,
    // только дешевле.
    const stated = /срок ответа в (\d+) секунд/.exec(text);
    assert.ok(stated, 'the page no longer quotes the deadline the suite sets');

    const policy = readFileSync(
      resolve(here, '..', 'app', 'Tests', 'MeetGPTTests', 'GroundingContextPolicyTests.swift'),
      'utf8');
    const used = /withValue\((\d+)\)/.exec(policy);
    assert.ok(used, 'the suite no longer overrides the deadline at all');
    assert.equal(stated[1], used[1],
      `page says ${stated[1]} s, the suite sets ${used[1]} s`);
  });

  test('the parallel-suite hazard the page describes is actually closed', () => {
    // Страница признаёт породу поломок, которая живёт в самом наборе, и
    // называет лечение. Признание без лечения — просто текст, поэтому здесь
    // проверяется, что общей изменяемой переменной больше нет.
    assert.match(text, /подмена живёт внутри своей задачи/,
      'the page no longer describes how the race is closed');
    assert.match(text, /воспроизвести её не удалось/,
      'the page dropped the honest note that the race was never reproduced');

    const grounding = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'MCP', 'MCPGrounding.swift'), 'utf8'));
    assert.match(grounding, /@TaskLocal static var deadlineOverrideForTesting/,
      'the deadline override is not task-local — suites can race over it again');
    assert.doesNotMatch(grounding, /static var groundingDeadline[^{]*=/,
      'groundingDeadline is a stored mutable static again');

    // И ни один тест не должен присваивать срок напрямую.
    const suites = readdirSync(resolve(here, '..', 'app', 'Tests', 'MeetGPTTests'))
      .filter((n) => n.endsWith('.swift'));
    for (const name of suites) {
      const source = readFileSync(
        resolve(here, '..', 'app', 'Tests', 'MeetGPTTests', name), 'utf8');
      assert.doesNotMatch(source, /groundingDeadline\s*=/,
        `${name} assigns the deadline directly — that is the race`);
    }
  });

  test('the "partly unreadable archive" promise reaches both surfaces', () => {
    // Обещание проверяемо только по коду обеих поверхностей: командная строка
    // и приложение читают архив РАЗНЫМИ хранилищами, и правка, дошедшая до
    // одного, оставляет второе врать. Ровно это и было: ядро имя файла
    // запоминало, приложение выбрасывало его через `compactMap { try? decode }`.
    assert.match(text, /ответ может быть неполным/,
      'the page no longer shows what a partly unreadable archive reads like');
    assert.match(text, /не добавленный факт, а отсутствующий/,
      'the page no longer explains why silence here is the worse lie');

    const answer = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallAnswer.swift'), 'utf8'));
    assert.match(answer, /unreadable: \[String\]/,
      'the shared answer no longer accepts the unreadable list');
    assert.match(answer, /guard !unreadable\.isEmpty else \{ return answer \}/,
      'the warning is unconditional — a line printed always stops being read');

    // Приложение: хранилище обязано ИМЕНОВАТЬ нечитаемые файлы, а не глотать.
    const store = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Persistence', 'SessionStore.swift'), 'utf8'));
    assert.doesNotMatch(store, /compactMap \{ try\? decoder\.decode/,
      'the app store silently drops unreadable files again');
    assert.match(store, /func listWithUnreadable/,
      'the app store no longer reports which files failed');

    // …и это должно доходить до модели, иначе она уверенно скажет «не обсуждали».
    const context = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'AI', 'DecisionRecallContext.swift'), 'utf8'));
    assert.match(context, /INCOMPLETE RECORD/,
      'the model is no longer told the record is partial');
  });

  test('the performance number on the page is tied to the suite', () => {
    // Ровно тот класс, что чинился весь вечер, но направленный на claim:
    // страница называла «полторы секунды», комментарий в тесте — «стало 2.8 с»,
    // а замер даёт 0.4 с. Ничто их не связывало: потолок в тесте — 12 секунд,
    // нарочно с запасом, и любое число между нулём и двенадцатью проходило.
    //
    // Проверяется не сам замер (он зависит от машины, и тест на него был бы
    // хлипким), а то, что ПОТОЛОК на странице и потолок в наборе — одно число.
    assert.match(text, /0,4 секунды/,
      'the page no longer states the measured search time');
    assert.match(text, /замер на M-процессоре, а не обещание/,
      'the page presents the number as a guarantee rather than a measurement');

    const perf = readFileSync(
      resolve(here, '..', 'mvp', 'Tests', 'OrakulCoreTests', 'RecallIndexTests.swift'), 'utf8');
    // Из ТЕЛА нужной функции, а не поиском по файлу: рядом лежит другой
    // замер со своим потолком, и первая версия этой проверки поймала именно
    // его — ровно та ошибка соседнего совпадения, что уже случалась здесь.
    const body = bodyOf(perf, 'func searchStaysUsableOnFullLengthCalls');
    assert.ok(body, 'the month-of-calls measurement is gone from the suite');
    const budget = /#expect\(elapsed < (\d+)/.exec(body);
    assert.ok(budget, 'the month-of-calls budget is no longer recognisable in the suite');

    const stated = /потолок в (\d+) секунд/.exec(text);
    assert.ok(stated, 'the page no longer quotes the regression ceiling');
    assert.equal(stated[1], budget[1],
      `page says ${stated[1]} s, the suite enforces ${budget[1]} s`);
  });

  test('the re-import promise names both halves of its key', () => {
    assert.match(text, /Импорт того же звонка второй раз тоже узнаётся/,
      'the page no longer promises re-imports are recognised');
    assert.match(text, /по началу звонка и названию/,
      'the page no longer says what the check compares');

    const store = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Persistence', 'SessionStore.swift'), 'utf8'));
    assert.match(store, /startedAt == candidate\.startedAt && \$0\.title == candidate\.title/,
      'the re-import key is no longer start-time AND title');
    // Решение обязано жить в хранилище: пока оно стояло в AppState, мутация,
    // отключавшая его, не роняла ни одного теста.
    assert.match(store, /func saveImported/,
      'the save-or-return decision left the store, where it can be tested');
  });

  test('the duplicate check compares text, and the answer cap makes it matter', () => {
    assert.match(text, /не заводится дважды/,
      'the page no longer promises duplicates are refused');
    assert.match(text, /Сравнивается текст, а не название/,
      'the page no longer states what the check compares');

    const cli = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'CommandLineApp.swift'), 'utf8'));
    assert.match(cli, /\$0\.digest == text/,
      'the duplicate check compares something other than the transcript text');

    // Обещание опирается на то, что мест в ответе мало. Если предел вырастет
    // настолько, что копии перестанут вытеснять, довод на странице обветшает —
    // пусть об этом узнают здесь, а не читатели.
    const answer = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallAnswer.swift'), 'utf8'));
    const cap = /maximumMeetings = (\d+)/.exec(answer);
    assert.ok(cap, 'the answer cap is gone — the page argues from it');
    assert.ok(Number(cap[1]) <= 5,
      `page says three copies fill the answer; the cap is now ${cap[1]}`);
    assert.match(text, /не больше трёх звонков/,
      'the page no longer states the cap its argument rests on');
  });

  test('the "first ten, not all" notice is real and conditional', () => {
    assert.match(text, /Показаны первые 10/,
      'the page no longer shows the truncation notice');
    assert.match(text, /Когда нашлось меньше десяти, приписки нет/,
      'the page no longer states the notice is conditional');

    const query = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'ConnectorQuery.swift'), 'utf8'));
    assert.match(query, /lines\.count >= searchLimit/,
      'the notice is unconditional or gone — either way the page is wrong');
    assert.match(query, /Показаны первые \\\(searchLimit\)/,
      'the notice no longer quotes the same limit it enforces');

    // Число на странице обязано быть тем же, что просят у сервиса.
    const limit = /static let searchLimit = (\d+)/.exec(query);
    assert.ok(limit, 'the shared limit constant is gone');
    const onPage = /Показаны первые (\d+)/.exec(text);
    assert.equal(onPage[1], limit[1],
      `page says ${onPage[1]}, the code asks for ${limit[1]}`);
  });

  test('the "empty file" message distinguishes who emptied it', () => {
    // Из того же класса, что записан в плане: уверенная фраза о файле,
    // который человек может открыть и увидеть, что она неверна.
    assert.match(text, /только когда он правда пустой/,
      'the page no longer promises the distinction');
    assert.match(text, /пустым файл стал у нас/,
      'the page no longer says who emptied it');

    const cli = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'CommandLineApp.swift'), 'utf8'));
    assert.match(cli, /let fileWasEmpty = raw\.trimmingCharacters/,
      'the two causes are conflated again — a file with markup reads as empty');
    assert.match(cli, /В файле нет реплик/,
      'the message for a markup-only file is gone');
  });

  test('the encoding promise covers both surfaces and still refuses binary', () => {
    // Обещание про кодировки держится на двух разных читателях файлов —
    // командной строке и импортёре контекста приложения. Правка, дошедшая до
    // одного, оставляет второй портить текст молча; ровно это тут и было.
    assert.match(text, /Кодировка файла — не проблема пользователя/,
      'the page no longer promises non-UTF-8 transcripts are read');
    assert.match(text, /тридцать управляющих символов/,
      'the page no longer states how binary is told apart');

    const decoder = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'TranscriptFile.swift'), 'utf8'));
    assert.match(decoder, /windowsCP1251/, 'the CP1251 fallback is gone');
    // Метка порядка байтов обязательна: без неё UTF-16 берётся за любые байты
    // и возвращает иероглифы, которые выглядят как успех.
    assert.match(decoder, /0xFF, 0xFE|0xFE, 0xFF/,
      'UTF-16 is attempted without requiring a byte-order mark');
    assert.match(decoder, /looksLikeText/,
      'nothing checks the CP1251 result is text — an image would import as garbage');

    // Импортёр приложения обязан ходить через тот же разбор.
    const importer = stripComments(readFileSync(
      resolve(here, '..', 'app', 'Sources', 'MeetGPT', 'Context', 'ContextImporter.swift'), 'utf8'));
    assert.match(importer, /TranscriptFile\.decode/,
      'the app importer decodes on its own again');
    assert.doesNotMatch(importer, /encoding: \.utf16\)/,
      'the app importer tries UTF-16 without a BOM again — that produced 샭Ｚ⃏⃯');
  });

  test('the "writing is stricter than reading" promise is in the write path', () => {
    // Обещание про запись проверяемо только по коду записи. Тихая подстановка
    // нуля вместо номера доски — это не косметика: запись уходит в чужой
    // трекер, и повторить её нельзя.
    assert.match(text, /Запись строже чтения/,
      'the page no longer promises the write path checks first');
    assert.match(text, /доской номер ноль/,
      'the page no longer names the failure it fixed');

    const trackers = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianTrackers.swift'), 'utf8'));
    assert.doesNotMatch(trackers, /Int\(place\)\s*\?\?\s*0/,
      'the silent zero is back — a board name would ship as board 0');
    assert.match(trackers, /guard let board = Int\(place\.trimmingCharacters/,
      'the write path no longer refuses a non-numeric board before the request');

    // Запись обязана оставаться строгой и в разборе ответа: «завели задачу,
    // которой нет» — худшее, что может сделать кнопка после звонка.
    assert.match(trackers, /guard let created = parseCreated\(data\) else/,
      'createIssue accepts an unparseable response again');
  });

  test('the "server error names its number" promise holds in every connector', () => {
    // Обещание проверяемо только по коду: страница называет 502, а держится
    // это на том, что КАЖДЫЙ коннектор отличает ошибку сервера от мусора в
    // ответе. Три из пяти этого не делали, и находилось это лишь настоящим
    // рейсом до сервера, отвечающего как сломанный прокси.
    assert.match(text, /ответил ошибкой 502/,
      'the page no longer shows what a server error reads like');
    assert.match(text, /502 или 504/,
      'the page no longer names the on-premise failure it is about');

    const core = resolve(here, '..', 'mvp', 'Sources', 'OrakulCore');
    for (const file of ['SelfHostedTrackers.swift', 'TeamNotes.swift',
                        'WorkMessengers.swift']) {
      const source = stripComments(readFileSync(resolve(core, file), 'utf8'));
      assert.match(source, /case http\(Int\)/,
        `${file} has no distinct case for a server error`);
      assert.match(source, /200\.\.<300/,
        `${file} only inspects 401/403 again — 502 will read as unreadable`);
      // И противоположная ветка обязана уцелеть: 200 с мусором это мусор.
      assert.match(source, /ConnectorError\.unreadable/,
        `${file} lost the unreadable case — garbage with a 200 needs it`);
    }

    // Те два, с которых брался образец, обязаны остаться правильными.
    for (const file of ['RussianTrackers.swift', 'GitHubConnector.swift']) {
      const source = stripComments(readFileSync(resolve(core, file), 'utf8'));
      assert.match(source, /default:\s*throw/,
        `${file} stopped handling unexpected statuses`);
    }

    // Вторая половина того же рейса: состояние не выдумывается.
    assert.match(text, /Не сообщили — не пишем/,
      'the page no longer promises an absent state stays absent');
    const tracker = stripComments(readFileSync(resolve(core, 'SelfHostedTrackers.swift'), 'utf8'));
    assert.doesNotMatch(tracker, /\?\? "unknown"/,
      'the connector invents a state again — the page says it does not');
    const label = stripComments(readFileSync(resolve(core, 'IssueLabel.swift'), 'utf8'));
    assert.match(label, /isEmpty \? "\[/,
      'the shared label lost the branch that omits an absent state');
  });

  test('the infrastructure-name promise is backed by a search-only table', () => {
    // Обещание из двух половин, и вторая важнее: имена ищутся на обоих
    // алфавитах, но расшифровку НЕ переписывают. Если таблица переедет в
    // общий канон, «купили редис» превратится в «купили Redis» — и страница
    // станет враньём ровно там, где обещает обратное.
    assert.match(text, /имена инфраструктуры/i,
      'the page no longer promises infrastructure names work in both alphabets');
    assert.match(text, /не переписывает расшифровку/,
      'the page no longer states the boundary that makes this safe');

    const lexicon = readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RussianLexicon.swift'), 'utf8');

    // Имена, названные на странице, обязаны быть в таблице.
    for (const name of ['redis', 'postgres', 'git', 'nginx', 'clickhouse']) {
      assert.ok(lexicon.includes(`"${name}"`),
        `the page names ${name}; the lexicon does not carry it`);
    }

    // Таблица читается ТОЛЬКО поиском. `restore` строит канон из
    // canonicalForms(), и infrastructure не должна туда попадать.
    const canonical = /private static func buildCanonicalForms\(\)[\s\S]*?\n    \}/.exec(lexicon);
    assert.ok(canonical, 'buildCanonicalForms is no longer recognisable');
    assert.ok(!canonical[0].includes('infrastructure'),
      'infrastructure names leaked into the rewrite canon — transcripts will be altered');

    // …и наоборот: поиск обязан её читать, иначе обещание пустое.
    const token = /public static func canonicalToken[\s\S]*?\n    \}/.exec(lexicon);
    assert.ok(token, 'canonicalToken is no longer recognisable');
    assert.match(token[0], /infrastructureIndex/,
      'search stopped consulting the infrastructure table');
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

  test('the "nothing to search for" answer is distinct from "not discussed"', () => {
    // Тот же принцип, что и с пустым архивом: уверенная фраза о результате
    // поиска, которого не было, отправляет человека с ложным выводом о
    // собственных звонках.
    assert.match(text, /искать не по чему/,
      'the page no longer distinguishes an unsearchable question');
    assert.match(text, /архив никто не открывал/,
      'the page no longer says why the old answer was wrong');

    const answer = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallAnswer.swift'), 'utf8'));
    // Только когда ничего не нашлось: находка означает, что вопрос был
    // достаточно конкретным, и придираться к нему поздно.
    assert.match(answer, /grounded\.isEmpty, RecallIndex\.tokens\(query\)\.isEmpty/,
      'the complaint fires regardless of hits, or not at all');

    // Держится на том, что указательные слова считаются служебными.
    const index = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallIndex.swift'), 'utf8'));
    for (const word of ['"это"', '"там"', '"этому"']) {
      assert.ok(index.includes(word),
        `${word} is searchable again — «а что там по этому» would search for noise`);
    }
  });

  test('the page admits where the question-answer rule stops working', () => {
    // Правило простое и потому ограниченное: между вопросом и ответом на
    // живом звонке встревает «секунду, найду документ». Проверено прогоном.
    // Обещание без этой оговорки было бы преувеличением.
    assert.match(text, /секунду, найду документ/,
      'the page no longer admits the filler case');
    assert.match(text, /не пытаемся угадать/,
      'the page no longer says why the rule is not made smarter');

    const index = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallIndex.swift'), 'utf8'));
    // Оговорка правдива только пока правило действительно простое: если
    // появится отбор «какая реплика настоящая», страница станет врать.
    assert.doesNotMatch(index, /bestLineIndex \+ 2/,
      'the rule now reaches past the next line; the page says it does not');
  });

  test('the headline example shows the answer, and the rule behind it', () => {
    // Главный пример на странице — первое, что видит пришедший. Он показывал
    // решение Бориса, а быстрый старт из README на своём же примере возвращал
    // строку Ани, то есть сам вопрос: отвечающий не повторяет тему, и
    // словарный поиск до ответа не дотягивается.
    assert.match(text, /Аня: По тарифам — что решили в итоге/,
      'the headline example no longer shows the question it answers');
    assert.match(text, /Борис: Годовой не трогаем до декабря/,
      'the headline example no longer shows the answer');
    assert.match(text, /вопрос без ответа остаётся один/,
      'the page no longer states the boundary that keeps this honest');

    const index = stripComments(readFileSync(
      resolve(here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallIndex.swift'), 'utf8'));
    assert.match(index, /guard bestWasQuestion/,
      'the next line is attached to every hit, or to none — both make the page wrong');
    assert.match(index, /character == "\?"/,
      'a question is no longer told apart from a statement');
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

  test('the deletion-by-prefix promise carries the same threshold as the code', () => {
    // Обещание разрушающей операции: если страница говорит «четырёх знаков», а
    // в коде стоит другое число, человек узнает об этом, стерев чужой звонок.
    const promise = /начало короче ([а-яё]+) знаков не принимается/.exec(text);
    assert.ok(promise, 'the page no longer states the minimum prefix length');
    const words = { двух: 2, трёх: 3, четырёх: 4, пяти: 5, шести: 6, восьми: 8 };
    const stated = words[promise[1]];
    assert.ok(stated, `unknown number word on the page: ${promise[1]}`);

    const cli = stripComments(readFileSync(resolve(
      here, '..', 'mvp', 'Sources', 'OrakulCore', 'CommandLineApp.swift'), 'utf8'));
    const threshold = /needle\.count >= (\d+)/.exec(cli);
    assert.ok(threshold, 'the minimum prefix length is gone from the code');
    assert.equal(Number(threshold[1]), stated,
      `the page promises ${stated} characters, the code requires ${threshold[1]}`);

    // Вторая половина обещания: при неоднозначности не удаляется НИЧЕГО.
    // Ветка обязана возвращать список совпадений, а не первое из них.
    const resolveBody = bodyOf(cli, 'func resolveIdentifier');
    assert.ok(resolveBody, 'resolveIdentifier is gone — the promise has no code behind it');
    assert.match(resolveBody, /default:\s*return \.ambiguous/,
      'ambiguous prefixes no longer refuse — the page promises they delete nothing');
  });

  test('the findings list says how many findings it has, and has that many', () => {
    // Число прописью в подводке — ровно та мелочь, которая тихо разъезжается
    // с содержимым: восемнадцатую находку допишут, а слово останется прежним.
    const items = html.match(/<details class="finding">/g) ?? [];
    // Числительное по-русски меняет и себя, и существительное: двадцать одна
    // проверка, двадцать две проверки, двадцать пять проверок. Проверка,
    // знавшая одну форму, падала на верной записи и пропускала неверную.
    const units = {
      одна: 1, две: 2, три: 3, четыре: 4, пять: 5, шесть: 6, семь: 7,
      восемь: 8, девять: 9,
    };
    const teens = {
      десять: 10, одиннадцать: 11, двенадцать: 12, тринадцать: 13,
      четырнадцать: 14, пятнадцать: 15, шестнадцать: 16, семнадцать: 17,
      восемнадцать: 18, девятнадцать: 19,
    };
    const tens = { двадцать: 20, тридцать: 30, сорок: 40 };
    const lead = /([А-Яа-я]+(?:\s+[А-Яа-я]+)?)\s+(проверка|проверки|проверок)\s+ниже/.exec(text);
    assert.ok(lead, 'the findings list lost its lead-in');
    const words = lead[1].toLowerCase().split(/\s+/);
    const value = (w) => teens[w] ?? tens[w] ?? units[w];
    const stated = words.reduce((sum, w) => {
      const v = value(w);
      assert.ok(v !== undefined, `unknown number word: ${w}`);
      return sum + v;
    }, 0);

    const n = stated % 100;
    const noun = (n >= 11 && n <= 14) ? 'проверок'
      : [, 'проверка', 'проверки', 'проверки', 'проверки'][stated % 10] ?? 'проверок';
    assert.equal(lead[2], noun,
      `${stated} — по-русски «${noun}», а написано «${lead[2]}»`);
    assert.equal(items.length, stated,
      `the page says ${stated} findings, the list holds ${items.length}`);

    // Заголовок виден всегда, доказательство раскрывается. Значит заголовок
    // обязан быть законченной фразой: с двоеточием он обещает продолжение,
    // которого в свёрнутом виде не видно.
    const summaries = [...html.matchAll(/<summary>(.*?)<\/summary>/gs)]
      .map((m) => m[1].replace(/<[^>]+>/g, '').trim());
    assert.equal(summaries.length, items.length, 'a finding lost its summary');
    for (const s of summaries) {
      assert.ok(s.length > 10, `a summary is too short to be a claim: «${s}»`);
      assert.ok(!/[:—-]$/.test(s), `a summary dangles on punctuation: «${s}»`);
      // Заголовок виден вместо абзаца, значит он и есть предложение целиком.
      assert.ok(/[.?!»)]$/.test(s), `a summary is not a finished sentence: «${s}»`);
    }
  });

  test('the clone command on the page is the one README was verified with', () => {
    // Страница показывает три строки как рабочие. Если README поправят, а
    // страницу забудут — человек скопирует то, что уже не работает, и узнает
    // об этом на своей машине.
    const onPage = /git clone (\S+) orakul/.exec(text);
    assert.ok(onPage, 'the page stopped showing how to get the source');
    const readme = readFileSync(resolve(here, '..', 'README.md'), 'utf8');
    const inReadme = /git clone (\S+) orakul/.exec(readme);
    assert.ok(inReadme, 'README stopped showing the clone command');
    assert.equal(onPage[1], inReadme[1],
      `page clones ${onPage[1]}, README clones ${inReadme[1]}`);
    assert.match(onPage[1], /^https:\/\/github\.com\//,
      'the clone URL is not a public GitHub address');

    // И кнопка ведёт туда же, где лежит то, что предлагают клонировать.
    const button = /<a class="btn ghost" href="(https:\/\/[^"]+)"/.exec(html);
    assert.ok(button, 'the header button no longer points at the repository');
    assert.ok(onPage[1].startsWith(button[1]),
      `the button goes to ${button[1]}, the command clones ${onPage[1]}`);
  });

  test('the version the page advertises is the version the app is built with', () => {
    // Страница обещает конкретный выпуск. Версию поднимут в Info.plist, а
    // страницу забудут — и человек скачает не то, что ему обещали.
    const onPage = /·\s*(\d+\.\d+\.\d+)\s*</.exec(html);
    assert.ok(onPage, 'the page no longer names a version');
    const plist = readFileSync(resolve(here, '..', 'app', 'Support', 'Info.plist'), 'utf8');
    const built = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist);
    assert.ok(built, 'the app version is gone from Info.plist');
    assert.equal(onPage[1], built[1],
      `the page offers ${onPage[1]}, the app is built as ${built[1]}`);
  });

  test('the download button points at releases of the same repository', () => {
    const download = /<a class="btn" href="(https:\/\/[^"]+)"/.exec(html);
    assert.ok(download, 'the page stopped offering a download');
    assert.match(download[1], /\/releases\/latest$/,
      'the download link does not point at a release');
    const clone = /git clone (\S+?)(?:\.git)? orakul/.exec(text);
    assert.ok(download[1].startsWith(clone[1]),
      `download from ${download[1]}, sources from ${clone[1]}`);
  });

  test('nothing on the page still promises the publication that already happened', () => {
    // Страница писалась, когда репозитория ещё не было, и обещала будущее:
    // «репозиторий уйдёт в открытый доступ». Он ушёл. Обещание, сбывшееся
    // и оставшееся обещанием, читается как «до сих пор не сделали».
    for (const promise of ['уйдёт в открытый доступ', 'будет опубликован',
                           'ещё не опубликован', 'пока не опубликован',
                           'когда репозиторий появится']) {
      assert.ok(!text.includes(promise),
        `страница всё ещё обещает то, что сделано: «${promise}»`);
    }
    // И наоборот: раз обещание сбылось, адрес обязан быть на странице.
    assert.match(html, /https:\/\/github\.com\/[\w-]+\/[\w-]+/,
      'на странице нет адреса репозитория');
  });

  test('small text meets AA contrast against the ground it sits on', () => {
    // Подписи и надзаголовки набраны 11–12.5px цветом --faint. Он давал
    // 3.49:1 — ниже 4.5, положенных для текста мельче 18.66px. Проверить это
    // глазами нельзя: на тёмном фоне блёклая подпись выглядит «стильно»
    // ровно до того, как её попробуют прочитать.
    const token = (name) => {
      const m = new RegExp(`--${name}:\\s*(#[0-9A-Fa-f]{6})`).exec(html);
      assert.ok(m, `токен --${name} пропал`);
      return m[1];
    };
    const channel = (hex, i) => {
      const v = parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16) / 255;
      return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    };
    const luminance = (hex) =>
      0.2126 * channel(hex, 0) + 0.7152 * channel(hex, 1) + 0.0722 * channel(hex, 2);
    const contrast = (a, b) => {
      const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
      return (x + 0.05) / (y + 0.05);
    };

    const ground = token('ink');
    for (const name of ['text', 'muted', 'faint']) {
      const ratio = contrast(token(name), ground);
      assert.ok(ratio >= 4.5,
        `--${name} даёт ${ratio.toFixed(2)}:1 на --ink, нужно 4.5 для мелкого текста`);
    }
    // Кнопка своим фоном: тёмный текст на янтарном.
    assert.ok(contrast(token('ink'), token('amber')) >= 4.5,
      'текст на главной кнопке не дотягивает до AA');
  });

  test('the label spacing rule is not cancelled by the one it rides on', () => {
    // `.eyebrow` задан сокращённой записью `margin: 0 0 14px`, и она обнуляет
    // верхний отступ. `.findings-label` стоял ВЫШЕ по файлу, специфичность у
    // них одинаковая — и правило не применялось вовсе: 46px превращались в 0.
    // Глазами это не видно: подпись просто стоит чуть теснее, чем задумано.
    const eyebrow = html.indexOf('.eyebrow {');
    const label = html.indexOf('.findings-label {');
    assert.ok(eyebrow > -1 && label > -1, 'одно из правил пропало');
    assert.ok(label > eyebrow,
      '.findings-label стоит выше .eyebrow — сокращённый margin его обнулит');
    assert.match(html.slice(label, label + 120), /margin-top/,
      '.findings-label больше не задаёт верхний отступ');
  });

  test('the promise about cases is backed by the endings the code strips', () => {
    // Страница обещает, что падеж вопроса сходится с падежом речи, и называет
    // именно тот разряд, который был сломан. Обещание держится на списке
    // окончаний: без семейства на «и» «развёртыванием» и «развёртывание»
    // дают разные основы, и обещание становится неправдой.
    const claim = /падеж вопроса и падеж речи сходятся/.test(text);
    assert.ok(claim, 'страница больше не обещает падежи');
    const source = readFileSync(resolve(
      here, '..', 'mvp', 'Sources', 'OrakulCore', 'RecallIndex.swift'), 'utf8');
    for (const ending of ['"ием"', '"ия"', '"ию"', '"ии"']) {
      assert.ok(source.includes(ending),
        `окончание ${ending} пропало — обещание про падежи перестало быть правдой`);
    }
    assert.match(source, /stride\(from: 4/,
      'цикл снова начинается не с четырёх — четырёхбуквенные окончания не сработают');
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
    assert.doesNotMatch(html, /src="https?:\/\//i, 'nothing is fetched from another host');
    // `rel` решает, тянет ли <link> что-нибудь. canonical и alternate — это
    // сведения о странице, они не загружают ничего; stylesheet, icon, preload
    // и родня — загружают. Прежний запрет не различал их и валил честный
    // canonical, из-за чего страница не могла назвать свой собственный адрес.
    const loading = /(stylesheet|icon|preload|prefetch|preconnect|dns-prefetch|manifest)/i;
    for (const tag of html.match(/<link[^>]*>/gi) ?? []) {
      if (!/href="https?:\/\//i.test(tag)) continue;
      const rel = /rel="([^"]+)"/i.exec(tag)?.[1] ?? '';
      assert.ok(!loading.test(rel), `страница тянет ${rel} со стороны: ${tag}`);
    }
    assert.doesNotMatch(html, /@import|url\(https?:/i, 'no remote CSS or fonts');

    // Ссылка — не загрузка: по ней переходят, её не тянут при открытии
    // страницы. Поэтому <a href> сюда не попадает, но и открытым его не
    // оставляем: чужой хост в ссылке — это счётчик, пришедший через заднюю
    // дверь. Разрешён ровно один, и это репозиторий.
    const hosts = [...html.matchAll(/<a[^>]+href="https?:\/\/([^/"]+)/gi)].map((m) => m[1]);
    const allowed = new Set(['github.com']);
    for (const host of hosts) {
      assert.ok(allowed.has(host), `the page links out to ${host}`);
    }
  });

  test('respects reduced motion and keyboard focus', () => {
    assert.match(html, /@media \(prefers-reduced-motion: reduce\)/);
    assert.match(html, /:focus-visible/);
  });
});
