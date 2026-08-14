import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const script = resolve(here, '..', 'scripts', 'test-filter.sh');
const run = (...args) => spawnSync('bash', [script, ...args], { encoding: 'utf8' });

describe('сторож пустого фильтра', () => {
  // Настоящий прогон Swift здесь не запускается: он идёт минуты, а проверять
  // надо разбор аргументов и то, что ноль проверок считается провалом.
  test('без аргументов объясняет, что нужно', () => {
    const r = run();
    assert.equal(r.status, 2);
    assert.match(r.stderr, /app\|mvp/);
  });

  test('чужой пакет отвергается с именем в сообщении', () => {
    const r = run('нечто', 'Набор');
    assert.equal(r.status, 2);
    assert.match(r.stderr, /«нечто»/,
      'имя пакета съедено — так было, пока переменную не взяли в скобки');
    assert.doesNotMatch(r.stderr, /unbound variable/,
      'переменная перед многобайтовой кавычкой снова читается как часть имени');
  });

  test('в самом скрипте переменные перед кавычками взяты в скобки', () => {
    // Комментарии не исполняются, а в одном из них эта самая ошибка нарочно
    // показана как пример — читать надо код.
    const source = readFileSync(script, 'utf8')
      .split('\n').filter((l) => !l.trim().startsWith('#')).join('\n');
    const bad = [...source.matchAll(/\$[a-zA-Z_][a-zA-Z0-9_]*[»«]/g)].map((m) => m[0]);
    assert.deepEqual(bad, [], `без скобок: ${bad.join(', ')}`);
  });

  test('ноль проверок описан как провал, а не как успех', () => {
    const source = readFileSync(script, 'utf8');
    assert.match(source, /count" -eq 0/, 'ноль проверок больше не проверяется');
    assert.match(source, /exit 1/, 'провал не возвращает ненулевой код');
  });
});
