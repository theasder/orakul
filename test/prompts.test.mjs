import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// These buttons are the product's whole surface for a free user, so the tests
// guard two things a later translation pass would quietly break: that the
// Russian is written rather than converted, and that the free tier stays
// genuinely free.

const here = dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(
  readFileSync(resolve(here, '..', 'config', 'prompts.ru.json'), 'utf8'),
);
const { buttons } = catalog;

describe('orakul quick-action buttons (ru)', () => {
  test('the catalogue is well formed and every id is unique', () => {
    assert.equal(catalog.locale, 'ru-RU');
    assert.ok(buttons.length >= 6, 'a co-pilot with fewer than six actions is a demo');
    const ids = buttons.map((b) => b.id);
    assert.equal(new Set(ids).size, ids.length, 'duplicate id');
    for (const button of buttons) {
      assert.match(button.id, /^[a-z][a-z0-9-]*$/, `id not kebab-case: ${button.id}`);
      for (const field of ['label', 'prompt', 'tier', 'adapted']) {
        assert.ok(button[field], `${button.id} is missing ${field}`);
      }
      assert.equal(typeof button.offline, 'boolean', `${button.id}.offline must be boolean`);
    }
  });

  test('the free tier is the majority of the product, not a teaser', () => {
    // "Focus on the freemium version": if most buttons are locked, the free
    // tier is a trial with extra steps and the open-source promise reads as
    // bait. Asserting the product decision means changing it takes an argument
    // rather than a quiet edit.
    const free = buttons.filter((b) => b.tier === 'free');
    assert.ok(free.length >= Math.ceil(buttons.length * 0.6),
      `only ${free.length} of ${buttons.length} buttons are free`);
    // The headline capability must never move behind a paywall.
    const recall = buttons.find((b) => b.id === 'what-decided');
    assert.equal(recall.tier, 'free', 'cross-meeting recall is the product; it stays free');
  });

  test('every free button works without a network, and paid ones admit they do not', () => {
    // The free tier's argument is "your audio never leaves the Mac". A free
    // button needing the network breaks the privacy claim and the offline
    // claim at the same time.
    for (const button of buttons) {
      if (button.tier === 'free') {
        assert.equal(button.offline, true, `free button ${button.id} must work offline`);
      } else {
        assert.equal(button.offline, false, `${button.id} is paid; it must not claim offline`);
      }
    }
  });

  test('labels are Russian and short enough to be a button', () => {
    for (const { id, label } of buttons) {
      assert.match(label, /^[А-Яа-яЁё\s,—-]+$/u, `label not plain Russian: ${id}`);
      assert.ok(label.length <= 20, `label too long for a button (${label.length}): ${label}`);
    }
  });

  test('prompts are written in Russian, not converted from English', () => {
    // Latin characters in a prompt mean an untranslated fragment survived.
    // Nothing in this catalogue needs one.
    for (const { id, prompt } of buttons) {
      assert.doesNotMatch(prompt, /[A-Za-z]/, `latin text left in prompt: ${id}`);
      assert.ok(prompt.length > 60, `prompt too thin to steer a model: ${id}`);
    }
  });

  test('no corporate anglicisms where a Russian word exists', () => {
    // The tell of a translated product. Each of these has a natural Russian
    // equivalent already used in the catalogue.
    const calques = /экшн|фоллоу-?ап|блайндспот|стейкхолдер|митинг|дедлайн/i;
    for (const { id, label, prompt } of buttons) {
      assert.doesNotMatch(`${label} ${prompt}`, calques, `anglicism in ${id}`);
    }
    // And the positive form: the word Russian developers actually use.
    assert.ok(buttons.some((b) => /созвон/i.test(b.label + b.prompt)),
      'nothing says "созвон" — this was written for the wrong audience');
  });

  test('prompts demand a quote and forbid invention', () => {
    // The same contract the app enforces in code: grounded, or nothing.
    const recall = buttons.find((b) => b.id === 'what-decided');
    assert.match(recall.prompt, /цитат/i);
    assert.match(recall.prompt, /не додумывай|не выдумывай/i);
    const summary = buttons.find((b) => b.id === 'meeting-summary');
    assert.match(summary.prompt, /которых нет в расшифровке/i);
  });

  test('prompts say what to do when the owner is unknown', () => {
    // "Ответственный не назван" is a result, not a gap to fill with a guess —
    // the single most useful line in a Russian stand-up summary.
    const promises = buttons.find((b) => b.id === 'who-promised');
    assert.match(promises.prompt, /ответственный не назван/i);
  });

  test('no button promises to send anything on the user’s behalf', () => {
    for (const { id, prompt } of buttons) {
      assert.doesNotMatch(prompt, /отправ(ь|ляй|им)|разошли|напиши письмо/i,
        `${id} implies auto-sending; the product never sends`);
    }
    const tracker = buttons.find((b) => b.id === 'to-tracker');
    assert.match(tracker.adapted, /отправляет человек/i);
  });

  test('every button records why it is worded that way', () => {
    // The `adapted` field guards against a future translation pass flattening
    // these back into English idioms: each one carries its decision.
    for (const { id, adapted } of buttons) {
      assert.ok(adapted.length > 40, `${id} has no real adaptation rationale`);
    }
  });
});
