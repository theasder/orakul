// Учётных данных нет ни в репозитории, ни в собранном приложении.
//
// `Secrets.swift` теперь под контролем версий — иначе `cd app && swift test`
// у клонирующего не собирается вовсе: файл порождается сборкой, в клоне его
// нет, и первая же ссылка на `Secrets.` разваливает вывод типов. Цена этого
// решения — файл, в который сборка пишет из `.env` и который теперь коммитится.
// Значит, нужна проверка, которой раньше не требовалось.
//
// Повод не выдуманный. В унаследованном файле лежали два живых секрета клиента
// Google проекта Cruxwing — и они уехали в опубликованные DMG: `LC_ALL=C grep -a`
// находил обе строки прямо в бинарнике по адресу загрузки. orakul при этом
// аккаунтов не имеет вовсе, README обещает «аккаунт не нужен», а общий с
// Cruxwing идентификатор — ровно то, что запрещают проверки в identity.test.mjs
// про bundle id и Связку ключей.

import { test, describe } from 'node:test';
import assert from 'node:assert';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
const secretsPath = resolve(repo, 'app', 'Sources', 'MeetGPT', 'Secrets.swift');

/// Формы, по которым учётные данные узнаются независимо от имени поля.
/// Именно формы, а не список известных строк: список защищает только от
/// того, что уже утекло.
const CREDENTIAL_SHAPES = [
  [/GOCSPX-[A-Za-z0-9_-]{10,}/, 'секрет клиента Google (GOCSPX-…)'],
  [/\d{11,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com/, 'идентификатор клиента Google'],
  [/sk-[A-Za-z0-9]{20,}/, 'ключ OpenAI (sk-…)'],
  [/sk-ant-[A-Za-z0-9-]{20,}/, 'ключ Anthropic'],
  [/ghp_[A-Za-z0-9]{30,}/, 'токен GitHub'],
  [/AKIA[0-9A-Z]{16}/, 'ключ AWS'],
  [/xox[baprs]-[A-Za-z0-9-]{10,}/, 'токен Slack'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'закрытый ключ'],
];

function builtBinary() {
  return resolve(repo, 'app', 'build', 'orakul.app', 'Contents', 'MacOS', 'MeetGPT');
}

function skipUnbuilt() {
  return existsSync(builtBinary())
    ? false
    : 'приложение ещё не собрано — проверка бинарника запускается после build.sh';
}

describe('учётные данные', () => {
  test('в истории коммитов нет ни одного настоящего секрета', () => {
    // Репозиторий уйдёт в открытый доступ вместе с историей. Секрет, удалённый
    // следующим коммитом, остаётся в ней навсегда и находится за минуту.
    //
    // Ищутся ЗНАЧЕНИЯ, а не формы: сами шаблоны (`GOCSPX-`, `sk-`) лежат в
    // проверках и в тексте страницы, и поиск по форме нашёл бы их же.
    const shallow = execFileSync('git', ['rev-parse', '--is-shallow-repository'],
                                 { cwd: repo, encoding: 'utf8' }).trim();
    assert.equal(shallow, 'false',
      'клон неполный — проверка истории прошла бы, не увидев её; '
      + 'в CI нужен fetch-depth: 0');

    const commits = execFileSync('git', ['rev-list', '--count', '--all'],
                                 { cwd: repo, encoding: 'utf8' }).trim();
    assert.ok(Number(commits) > 5, `в истории ${commits} коммит(ов) — проверять нечего`);

    const history = execFileSync('git', ['log', '--all', '-p'],
                                 { cwd: repo, encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
    const values = history.match(
      /GOCSPX-[A-Za-z0-9_-]{15,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{36}|AIza[0-9A-Za-z_-]{35}/g);
    assert.equal(values, null,
      `в истории найдены настоящие ключи: ${[...new Set(values ?? [])].join(', ')}`);
  });

  test('никакой секрет не пишется в файл настроек', () => {
    // SECURITY.md: «Ключи лежат в Связке ключей macOS, а не в файле
    // настроек». UserDefaults — это как раз файл настроек: обычный plist в
    // ~/Library/Preferences, читаемый любым процессом пользователя.
    //
    // Проверяется только ЗАПИСЬ. Чтение и удаление разрешены: `google.tokens`
    // когда-то лежал там, и код нарочно забирает его оттуда и стирает —
    // запретить это значило бы законсервировать старый ключ на диске.
    const swift = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = resolve(dir, entry.name);
        if (entry.isDirectory()) {
          if (!/(^|\/)(\.build|build|node_modules)$/.test(full)) walk(full);
        } else if (entry.name.endsWith('.swift')) swift.push(full);
      }
    };
    walk(resolve(repo, 'app', 'Sources'));
    walk(resolve(repo, 'mvp', 'Sources'));
    assert.ok(swift.length > 50, `обход нашёл ${swift.length} файлов — проверка была бы фиктивной`);

    // «keywords» содержит «key», но секретом не является — отсюда границы слова.
    const secretish = /(token|secret|password|apikey|api_key|credential|session)/i;
    const offenders = [];
    for (const file of swift) {
      const text = readFileSync(file, 'utf8');
      for (const [, key] of text.matchAll(/UserDefaults\.standard\.set\([^)]*forKey:\s*"([^"]+)"/g)) {
        if (secretish.test(key.replace(/keywords?/gi, ''))) {
          offenders.push(`${file.slice(repo.length + 1)}: ${key}`);
        }
      }
    }
    assert.deepEqual(offenders, [],
      `секрет уходит в файл настроек вместо Связки ключей:\n${offenders.join('\n')}`);
  });

  test('Secrets.swift под контролем версий — иначе клон не собирается', () => {
    const tracked = execFileSync('git', ['ls-files', 'app/Sources/MeetGPT/Secrets.swift'],
                                 { cwd: repo, encoding: 'utf8' }).trim();
    assert.equal(tracked, 'app/Sources/MeetGPT/Secrets.swift',
      'Secrets.swift снова не отслеживается — `cd app && swift test` у клонирующего упадёт');
  });

  test('в Secrets.swift нет ничего похожего на учётные данные', () => {
    const source = readFileSync(secretsPath, 'utf8');
    for (const [shape, what] of CREDENTIAL_SHAPES) {
      const hit = shape.exec(source);
      assert.equal(hit, null,
        `в Secrets.swift лежит ${what}: ${hit?.[0]?.slice(0, 12)}…`);
    }
  });

  test('сборка не вписывает учётные данные Google обратно', () => {
    // Обнулено в build.sh, а не только в файле: иначе первая же сборка
    // вернула бы всё на место, и проверка выше прошла бы ровно до неё.
    const build = readFileSync(resolve(repo, 'app', 'build.sh'), 'utf8');
    for (const field of ['googleClientID', 'googleClientSecret',
                         'googleSignInClientID', 'googleSignInClientSecret']) {
      const line = new RegExp(`static let ${field}\\s*=\\s*"([^"]*)"`).exec(build);
      assert.ok(line, `build.sh больше не задаёт ${field} — проверка ослепла`);
      assert.equal(line[1], '',
        `build.sh снова вписывает ${field} — учётные данные Cruxwing вернутся в сборку`);
    }
  });

  test('пустой идентификатор клиента убирает кнопку входа', () => {
    // Иначе «убрали ключи» означало бы «кнопка есть и не работает».
    const social = readFileSync(
      resolve(repo, 'app', 'Sources', 'MeetGPT', 'Integrations', 'SocialSignIn.swift'), 'utf8');
    assert.match(social, /static func showsGoogle\(hasClient: Bool[^)]*\)\s*->\s*Bool\s*\{\s*\n?\s*hasClient/,
      'показ кнопки Google больше не зависит от наличия клиента');
  });

  test('в собранном приложении учётных данных нет', { skip: skipUnbuilt() }, () => {
    // Единственная проверка, которая смотрит на то, что реально уехало
    // пользователю. Остальные читают исходники — а утекло именно из сборки.
    //
    // Байтовый поиск: строки в бинарнике не разделены. Ограничение метода
    // известно и здесь не мешает — строки короче 16 байт Swift хранит внутри
    // структуры, отдельным литералом их не найти, но все формы выше длиннее.
    const text = readFileSync(builtBinary()).toString('latin1');
    for (const [shape, what] of CREDENTIAL_SHAPES) {
      const hit = shape.exec(text);
      assert.equal(hit, null,
        `в собранном приложении лежит ${what}: ${hit?.[0]?.slice(0, 12)}…`);
    }
  });
});
