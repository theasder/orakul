import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// Проверка проверок: единственный тест, который смотрит не на продукт, а на
// остальной набор.
//
// Повод конкретный. В шаблоне `/сравнени\w+ практических задач/` `\w` не
// совпадает с кириллицей — в JavaScript это `[A-Za-z0-9_]`, и суффикс «ю» под
// него не попадает. Шаблон не мог сработать никогда. Рядом нашлись ещё два
// таких же, один жил незамеченным с момента написания.
//
// Опаснее всего это в отрицательных проверках. `assert.doesNotMatch` с
// шаблоном, который не может совпасть, проходит при любом содержимом: так
// `/за кредит|кредитов|кредита\b/i` пропускал строку «нет кредита» — `\b` тоже
// определён через `\w`, и после кириллической буквы границы не возникает. Тест
// был зелёным, потому что не мог быть другим.
//
// Отличить такой тест от настоящего по виду нельзя. Поэтому — здесь.

const here = dirname(fileURLToPath(import.meta.url));
const files = readdirSync(here).filter((f) => f.endsWith('.test.mjs'));
const ASCII_CLASS_NEAR_CYRILLIC = /[а-яёА-ЯЁ]\\[wbS]|\\[wbS][а-яёА-ЯЁ]/;

import { bodyOf, callsInside, stripComments } from './swift-source.mjs';

describe('swift-source helper', () => {
  // Помощник существует ради трёх конкретных промахов. Здесь каждый из них —
  // отдельный случай, потому что «зелёный помощник» ничего не значит, если он
  // ловит только то, что и раньше ловилось.
  // Порядок здесь важен, и это выяснилось мутацией. В первой версии образца
  // `schedule` стоял ПОСЛЕ вызывающей функции, а объявление `handleFailure` —
  // в стороне; тогда обе ловушки не срабатывали: расширь тело до конца файла
  // или ищи одно имя — тест всё равно зелёный. Теперь `schedule` идёт первым,
  // упоминает имя не вызовом, а следом за ним лежит функция, которая вызывает
  // по-настоящему.
  const sample = [
    'final class Capture {',
    '    private func schedule() {',
    '        // handleFailure(error) — здесь только в комментарии',
    '        let pending = handleFailure',
    '        _ = pending',
    '    }',
    '',
    '    private func restart() {',
    '        do {',
    '            try startEngine()',
    '        } catch {',
    '            handleFailure(error)',
    '        }',
    '    }',
    '',
    '    func handleFailure(_ error: Error) {',
    '        onStopped?(error)',
    '    }',
    '}',
  ].join('\n');

  test('a call is found inside the function that makes it', () => {
    assert.equal(callsInside(sample, 'private func restart', 'handleFailure'), true);
  });

  test('a bare mention of the name is not a call', () => {
    // Промах №1: помощник искал имя, а не вызов, и `func handleFailure(_:)`
    // засчитывалось за обращение к нему. `schedule` упоминает имя значением —
    // если это снова сойдёт за вызов, проверка станет бесполезной.
    assert.equal(callsInside(sample, 'private func schedule', 'handleFailure'), false,
      'a bare mention of the name is being counted as a call again');
  });

  test('a call in the NEXT function does not leak across the closing brace', () => {
    // Промах №2: окно в N символов доставало до соседнего кода. Сразу за
    // `schedule` идёт `restart`, который вызывает по-настоящему, — если
    // границы тела считаются неверно, этот вызов утечёт внутрь.
    assert.equal(callsInside(sample, 'private func schedule', 'handleFailure'), false,
      'a call leaked in from the following function');
  });

  test('a call that exists only in a comment does not count', () => {
    // В образце такая строка уже есть — комментарий внутри `schedule`.
    assert.ok(sample.includes('// handleFailure(error)'));
    assert.equal(callsInside(sample, 'private func schedule', 'handleFailure'), false);
  });

  test('a missing function is null, not false', () => {
    // Разные случаи с разными действиями: «функцию переименовали» и «вызова в
    // ней нет» нельзя молча свести к одному, иначе переименование гасит
    // проверку вместо того, чтобы её уронить.
    assert.equal(callsInside(sample, 'private func renamedAway', 'handleFailure'), null);
    assert.equal(bodyOf(sample, 'private func renamedAway'), null);
  });

  test("Swift's optional call is still a call", () => {
    // `onStopped?(error)` — из-за этого помощник сначала не увидел ровно тот
    // вызов, ради которого писался.
    assert.equal(callsInside(sample, 'func handleFailure', 'onStopped'), true);
  });

  test('comments are stripped before anything is matched', () => {
    assert.ok(!stripComments(sample).includes('здесь только в комментарии'));
  });
});

describe('test suite sanity', () => {
  test('the suite is big enough that this check means something', () => {
    // Без этого пустой каталог (переименовали, перенесли) прошёл бы все
    // проверки ниже, ничего не осмотрев, и выглядел бы как успех.
    assert.ok(files.length >= 5,
      `only ${files.length} test files found — the sanity check is looking in the wrong place`);
  });

  test('no ASCII-only character class is used against Russian text', () => {
    // `\w`, `\b` и `\S` описывают латиницу. Рядом с кириллицей они значат не
    // то, что кажется, а обычно — «никогда».
    const offenders = [];
    for (const file of files) {
      readFileSync(resolve(here, file), 'utf8').split('\n').forEach((line, index) => {
        const trimmed = line.trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) return;
        // Строки-образцы в этом же файле: они содержат плохой шаблон нарочно.
        if (line.includes('String.raw')) return;
        if (ASCII_CLASS_NEAR_CYRILLIC.test(line)) {
          offenders.push(`${file}:${index + 1}: ${trimmed.slice(0, 90)}`);
        }
      });
    }
    assert.deepEqual(offenders, [],
      `ASCII-only classes next to Cyrillic — these patterns cannot match:\n${offenders.join('\n')}`);
  });

  test('the guard itself can still tell a broken pattern from a correct one', () => {
    // Проверка выше ищет по тексту файлов. Испортить её собственное выражение —
    // и она замолчит, оставшись такой же зелёной. Здесь оно применяется к
    // заведомо плохой и заведомо хорошей строке.
    const bad = String.raw`assert.match(text, /сравнени\w+ задач/)`;
    const good = String.raw`assert.match(text, /сравнени[а-яё]+ задач/)`;
    assert.ok(ASCII_CLASS_NEAR_CYRILLIC.test(bad),
      'the sanity check no longer recognises a broken pattern');
    assert.ok(!ASCII_CLASS_NEAR_CYRILLIC.test(good),
      'the sanity check now flags a correct pattern too');
  });

  test('negative assertions are given patterns that can actually match', () => {
    // `doesNotMatch` — место, где мёртвый шаблон невидим полностью. Такой тест
    // не просто бесполезен: он утверждает, что запрещённого текста нет, не
    // будучи способным его увидеть.
    //
    // Как проверяется. Для каждой альтернативы шаблона строится текст, который
    // она описывает: экранированные символы разэкранируются, из группы
    // берётся первый вариант, а `\b`, `^` и `$` убираются — они ничего не
    // занимают. Затем ИСХОДНАЯ альтернатива применяется к этому тексту. Не
    // совпала с тем, что сама же описывает, — совпасть не может нигде.
    //
    // Первая версия брала из шаблона одно слово и требовала совпадения с ним.
    // Она объявила сломанными десяток исправных проверок вроде
    // `/понимает смысл/`: два слова, а сверялось одно. Проверка, у которой
    // ложных срабатываний больше, чем настоящих, — это шум, который научат
    // игнорировать.
    const literalOf = (branch) => branch
      .replace(/\((?:\?:)?([^()|]*)(?:\|[^()]*)?\)/g, '$1')   // (a|b) → a
      .replace(/\\b|\^|\$/g, '')                             // ничего не занимают
      .replace(/\\(.)/g, '$1');                               // \. → .

    const broken = [];
    let checked = 0;
    for (const file of files) {
      const source = readFileSync(resolve(here, file), 'utf8');
      for (const [, body] of source.matchAll(/doesNotMatch\([^,]+,\s*\/((?:[^/\\\n]|\\.)+)\//g)) {
        for (const branch of body.split('|')) {
          if (!/[а-яёА-ЯЁ]/.test(branch)) continue;
          // Кванторы и классы литералом не выражаются — такие ветки пропускаем,
          // чтобы не выдумывать за них текст.
          if (/[[\]*+?{}]/.test(branch)) continue;
          const literal = literalOf(branch);
          if (!literal) continue;
          let re;
          try { re = new RegExp(branch, 'i'); } catch { continue; }
          checked += 1;
          if (!re.test(literal)) {
            broken.push(`${file}: /${branch}/ cannot match «${literal}», the text it describes`);
          }
        }
      }
    }
    assert.ok(checked >= 5,
      `only ${checked} Russian branches parsed — the extraction is broken`);
    assert.deepEqual(broken, [],
      `these negative assertions can never fire:\n${broken.join('\n')}`);
  });

  test('the dead-pattern check recognises the bug it was written for', () => {
    // `кредита\b` — тот самый шаблон, что пропускал «нет кредита».
    const build = (branch) => branch
      .replace(/\((?:\?:)?([^()|]*)(?:\|[^()]*)?\)/g, '$1')
      .replace(/\\b|\^|\$/g, '')
      .replace(/\\(.)/g, '$1');
    assert.ok(!new RegExp(String.raw`кредита\b`, 'i').test(build(String.raw`кредита\b`)),
      'the check no longer recognises a Cyrillic word boundary as dead');
    assert.ok(new RegExp('понимает смысл', 'i').test(build('понимает смысл')),
      'the check calls a perfectly good two-word pattern dead');
  });
});
