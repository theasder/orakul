import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const guard = resolve(here, '..', 'scripts', 'build-running.sh');

/// Поддельный репозиторий: тот же сторож, свой каталог `app`.
function fakeRepo() {
  const root = mkdtempSync(resolve(tmpdir(), 'orakul-guard-'));
  mkdirSync(resolve(root, 'scripts'));
  mkdirSync(resolve(root, 'app'));
  copyFileSync(guard, resolve(root, 'scripts', 'build-running.sh'));
  writeFileSync(resolve(root, 'app', 'dist-all.sh'), '#!/bin/bash\nsleep 30\n');
  return root;
}

const running = (root) =>
  spawnSync('bash', [resolve(root, 'scripts', 'build-running.sh')], { encoding: 'utf8' }).status === 0;

describe('сторож «идёт ли сборка»', () => {
  const repos = [fakeRepo(), fakeRepo()];
  // Запуск ровно такой, как настоящий: `cd app && bash dist-all.sh`. Именно
  // из-за него в командной строке процесса нет пути, и прежний шаблон
  // `pgrep -f "orakul/app.*dist-all\.sh"` не совпадал ни разу.
  const build = spawn('bash', ['dist-all.sh'], {
    cwd: resolve(repos[0], 'app'), detached: true, stdio: 'ignore',
  });
  after(() => {
    try { process.kill(-build.pid); } catch { /* уже умер */ }
    for (const root of repos) rmSync(root, { recursive: true, force: true });
  });

  test('замечает сборку своего репозитория', () => {
    assert.ok(running(repos[0]),
      'сборка идёт, а сторож молчит — мутация посреди сборки её уронит');
  });

  test('чужую сборку за свою не принимает', () => {
    // Тот же сторож, тот же процесс в системе, другой каталог. Без этого
    // сторож кричал бы всегда, к нему бы привыкли и перестали читать.
    assert.ok(!running(repos[1]),
      'чужая сборка принята за свою — ложная тревога');
  });

  test('личность процесса берётся из каталога, а не из командной строки', () => {
    const source = spawnSync('cat', [guard], { encoding: 'utf8' }).stdout;
    assert.match(source, /lsof -a -p "\$pid" -d cwd/,
      'проверка каталога исчезла — остаётся сравнение строк запуска');
  });
});
