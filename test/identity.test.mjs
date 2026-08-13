import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// orakul and Cruxwing must sit on one machine without touching each other. That
// is not a naming preference — macOS ties Screen Recording and Microphone
// permission to the bundle id, so two apps sharing one id share one grant, and
// a user cannot revoke it from one without losing the other. Same for the
// UserDefaults suite and the Keychain service: a shared identifier means
// installing orakul silently edits Cruxwing's settings.
//
// The comparison reads Cruxwing's REAL identity from its own files rather than
// a copy pasted here, so if somebody ever changes Cruxwing's bundle id into
// orakul's, this fails instead of quietly agreeing with itself.

const here = dirname(fileURLToPath(import.meta.url));
const identity = JSON.parse(readFileSync(resolve(here, '..', 'config', 'app.json'), 'utf8'));
const workspace = resolve(here, '..', '..');

const cruxwingPlist = resolve(workspace, 'cruxwing-app', 'Support', 'Info.plist');
const cruxwingDmg = resolve(workspace, 'cruxwing-app', 'dmg.sh');

// Cruxwing — соседний репозиторий, которого у клонирующего нет. Сравнение с
// ним осмысленно только в рабочей области автора; в клоне оно падало ENOENT и
// красило CI на каждом чужом pull request. Пропуск с причиной, не молчаливый.
const needsCruxwing = existsSync(cruxwingPlist)
  ? {}
  : { skip: 'Cruxwing лежит в соседнем репозитории — в клоне его нет' };

function cruxwingBundleId() {
  if (!existsSync(cruxwingPlist)) return null;
  const plist = readFileSync(cruxwingPlist, 'utf8');
  return plist.match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/)?.[1] ?? null;
}

function cruxwingVolumeName() {
  if (!existsSync(cruxwingDmg)) return null;
  return readFileSync(cruxwingDmg, 'utf8').match(/^VOLNAME="([^"]+)"/m)?.[1] ?? null;
}

describe('orakul app identity', () => {
  test('is called orakul, in every field a user or the OS ever sees', () => {
    assert.equal(identity.app.name, 'orakul');
    assert.equal(identity.app.displayName, 'orakul');
    assert.equal(identity.app.volumeName, 'orakul');
  });

  test('shares no identifier with Cruxwing', needsCruxwing, () => {
    const theirs = cruxwingBundleId();
    assert.ok(theirs, 'could not read Cruxwing bundle id — the comparison would be fake');
    assert.notEqual(identity.app.bundleId, theirs);
    // Not merely different: not derived from Cruxwing's names either, since a
    // shared prefix is how these drift back together during a refactor.
    for (const field of ['bundleId', 'defaultsSuite', 'keychainService', 'volumeName']) {
      assert.doesNotMatch(identity.app[field], /cruxwing|meetgpt/i,
        `${field} still carries Cruxwing's identity`);
    }
    assert.notEqual(identity.app.volumeName, cruxwingVolumeName());
  });

  test('keeps settings and credentials in its own store', () => {
    // Distinct from each other as well as from Cruxwing: one string reused for
    // both defaults and Keychain lets a settings reset drop tokens.
    assert.notEqual(identity.app.defaultsSuite, identity.app.keychainService);
    assert.match(identity.app.bundleId, /^[a-z0-9.]+$/);
    for (const field of ['defaultsSuite', 'keychainService']) {
      assert.ok(identity.app[field].startsWith(identity.app.bundleId),
        `${field} should be namespaced under the bundle id`);
    }
  });

  test('ships its own installers, named so neither product can overwrite the other', () => {
    const macos = identity.artifacts.macos.installers;
    const windows = identity.artifacts.windows.installers;
    assert.ok(macos.length >= 2, 'both Mac architectures need an installer');
    for (const file of [...macos, ...windows]) {
      assert.match(file, /^orakul-/, `installer not named for this app: ${file}`);
      assert.doesNotMatch(file, /cruxwing/i, `installer collides with Cruxwing: ${file}`);
    }
    // Downloads land in orakul's own tree, never in the Cruxwing site's.
    assert.match(identity.downloadDir, /^orakul\//);
    assert.doesNotMatch(identity.downloadDir, /cruxwing/i);
  });

  test('states platform status honestly, and never claims shipped', () => {
    // Nothing is built yet. A status of "released" here would put a download
    // button on a page with nothing behind it — the exact failure the Cruxwing
    // site hit today with its Ventura links.
    // macOS is built and notarised now; Windows is not. The statuses must
    // differ, because collapsing them hides which one a user can actually run.
    assert.equal(identity.artifacts.windows.status, 'planned');
    assert.ok(['planned', 'built', 'released'].includes(identity.artifacts.macos.status));
    // "built" is not "released": the artefacts exist locally and are NOT on
    // the site, so the page still must not link them — a link that 404s is
    // worse than no link, which this project has already shipped once.
  });

  test('records that Windows needs its own capture layer', () => {
    // ScreenCaptureKit is macOS-only. Writing this down stops the Windows port
    // being scoped as "recompile the Mac app", which it is not.
    const windows = identity.artifacts.windows;
    assert.match(windows.capture, /WASAPI/i);
    assert.match(windows.note, /ScreenCaptureKit/);
  });

  test('the landing page never offers an installer that does not exist', () => {
    // Until artifacts ship, no download link may appear. The page may say the
    // app is coming; it may not hand out a URL that 404s.
    const html = readFileSync(resolve(here, '..', 'public', 'index.html'), 'utf8');
    const visible = html.replace(/<!--[\s\S]*?-->/g, '');
    for (const file of [
      ...identity.artifacts.macos.installers,
      ...identity.artifacts.windows.installers,
    ]) {
      assert.ok(!visible.includes(file),
        `page links ${file} while artifacts.status is "planned"`);
    }
  });
});
