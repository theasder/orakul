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
  test('says up front that there is no app yet', () => {
    // The most expensive lie a README can tell is implying it runs. A visitor
    // who clones this and finds no binary does not come back.
    assert.match(readme, /ядро без приложения/i);
    assert.match(readme, /Чего ещё нет/i);
    for (const missing of [/захват/i, /расшифровщик/i, /интерфейс/i]) {
      assert.match(readme, missing, 'the missing pieces must be named, not implied');
    }
  });

  test('never claims a capability the code does not have', () => {
    assert.doesNotMatch(readme, /записывает созвон|скачать приложение|установить orakul/i);
    // Semantic search is exactly what this does NOT do.
    assert.doesNotMatch(readme, /понимает смысл|семантический поиск/i);
    assert.match(readme, /синонимы\s*—\s*нет/i, 'the search limitation belongs on the front page');
  });

  test('every command it prints is one that exists', () => {
    // `swift test` needs a package; `node --test` needs test files. A README
    // whose first command fails is worse than no README.
    assert.ok(existsSync(resolve(repo, 'app', 'Package.swift')), 'swift test has no package');
    assert.match(readme, /cd app && swift test/);
    assert.ok(readdirSync(resolve(repo, 'test')).some((f) => f.endsWith('.test.mjs')),
      'node --test has nothing to run');
    assert.match(readme, /node --test/);
  });

  test('the module table lists modules that are actually there', () => {
    // A table of contents for code that does not exist is the same lie in
    // tabular form.
    const sources = readdirSync(resolve(repo, 'app', 'Sources', 'OrakulCore'))
      .filter((f) => f.endsWith('.swift'))
      .map((f) => f.replace('.swift', ''));
    const mentioned = [...readme.matchAll(/^\| `(\w+)`/gm)].map((m) => m[1]);
    assert.ok(mentioned.length >= 5, 'expected the module table');
    for (const module of mentioned) {
      assert.ok(sources.includes(module), `README lists ${module}, which does not exist`);
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
});
