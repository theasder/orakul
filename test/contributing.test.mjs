import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// CONTRIBUTING is the first file a would-be contributor opens, and the metric
// this project is judged by is adoption. A guide whose first command fails, or
// whose example file was renamed, costs exactly the contributor it was written
// for — so every concrete thing it promises is checked here against the repo.

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..');
const guide = readFileSync(resolve(repo, 'CONTRIBUTING.md'), 'utf8');

describe('CONTRIBUTING', () => {
  test('is written in the language of the people it is asking for help', () => {
    // A Russian-first project whose contribution guide is English tells the
    // reader the Russian part was marketing.
    const cyrillic = (guide.match(/[а-яё]/gi) ?? []).length;
    assert.ok(cyrillic > 500, 'the guide is not actually in Russian');
    assert.match(guide, /Issue, pull request, обсуждение — на русском/);
    // And it must not turn that into a barrier: English contributions are fine.
    assert.match(guide, /Английский\s+тоже примут/);
  });

  test('every command it prints is one that exists', () => {
    assert.ok(existsSync(resolve(repo, 'app', 'Package.swift')), 'swift build has no package');
    assert.match(guide, /swift build/);
    assert.match(guide, /swift test/);
    assert.match(guide, /npm test/);
    const pkg = JSON.parse(readFileSync(resolve(repo, 'package.json'), 'utf8'));
    assert.ok(pkg.scripts?.test, 'the guide promises npm test, package.json has no test script');
  });

  test('the example it points a new connector at is still there', () => {
    // "Look at this file" is the most useful line in the guide and the first
    // to rot: the file gets renamed and nobody re-reads the docs.
    const referenced = guide.match(/`((?:app|mvp)\/[^`]+\.swift)`/g)?.map((m) => m.slice(1, -1)) ?? [];
    assert.ok(referenced.length > 0, 'the guide names no example file');
    for (const path of referenced) {
      assert.ok(existsSync(resolve(repo, path)), `CONTRIBUTING points at a missing file: ${path}`);
    }
  });

  test('the rules it states are the rules the tests enforce', () => {
    // A guide may only promise what something checks. Each of these lines has
    // a test behind it, and naming the test is what makes the promise real.
    assert.match(guide, /NoTariffsTests/);
    assert.ok(existsSync(resolve(repo, 'app', 'Tests', 'MeetGPTTests', 'NoTariffsTests.swift')),
      'the guide cites a test that does not exist');
    assert.match(guide, /InMemoryKeychain/);
    assert.match(guide, /Не заявляйте того, чего нет/);
  });

  test('names the same licence as the repository, and says why', () => {
    const licence = readFileSync(resolve(repo, 'LICENSE'), 'utf8');
    assert.match(licence, /Apache License/);
    assert.match(guide, /Apache 2\.0/);
    // "Permissive" is the brief's requirement; the reason matters more than the
    // name to the person who has to get it past their employer.
    assert.match(guide, /патент/i);
  });
});
