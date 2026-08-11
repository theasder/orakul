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
      for (const field of ['label', 'prompt', 'adapted']) {
        assert.ok(button[field], `${button.id} is missing ${field}`);
      }
      assert.equal(typeof button.offline, 'boolean', `${button.id}.offline must be boolean`);
    }
  });

  test('every button is free and local — there is nothing to sell', () => {
    // Tiers were removed from the product, so they must not survive in the
    // data either: a `tier` field is where a paywall grows back.
    for (const button of buttons) {
      assert.ok(!('tier' in button), `${button.id} still carries a tier`);
      assert.equal(button.offline, true, `${button.id} needs the network`);
    }
    assert.ok(buttons.some((b) => b.id === 'what-decided'), 'recall is the product');
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

  test('speaks the product\u2019s Russian, not a second dialect of it', () => {
    // The demo film is the shipped Russian voice, so it is the authority —
    // and the test reads the real file rather than a copy, so the two cannot
    // drift. Two words for one thing ("созвон" here, "звонок" in the film)
    // read as two different products.
    const film = readFileSync(
      resolve(here, '..', '..', 'cruxwing-marketing', 'public', 'demo-film', 'scene.ru.js'),
      'utf8',
    );
    for (const term of ['звонк', 'Слепые зоны', 'владельца']) {
      assert.ok(film.includes(term), `the film no longer says "${term}" — re-check the voice`);
    }

    const copy = buttons.map((b) => `${b.label} ${b.prompt}`).join(' ');
    assert.match(copy, /звонк/i, 'the product says "звонок", not "созвон"');
    assert.doesNotMatch(copy, /созвон/i, 'a second word for the same thing');
    assert.ok(buttons.some((b) => /слепые зоны/i.test(b.label)),
      'the film calls them "слепые зоны"');
    assert.ok(buttons.some((b) => /без владельца/i.test(b.prompt)),
      'the film says "без владельца", not "ответственный не назван"');
  });

  test('no corporate anglicisms where a Russian word exists', () => {
    // The tell of a translated product. Each has a natural Russian equivalent
    // already used in the catalogue — and in the film.
    const calques = /экшн|фоллоу-?ап|блайндспот|стейкхолдер|митинг|дедлайн/i;
    for (const { id, label, prompt } of buttons) {
      assert.doesNotMatch(`${label} ${prompt}`, calques, `anglicism in ${id}`);
    }
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
    assert.match(promises.prompt, /без владельца/i);
  });

  test('no button promises to send anything on the user’s behalf', () => {
    for (const { id, prompt } of buttons) {
      assert.doesNotMatch(prompt, /отправ(ь|ляй|им)|разошли|напиши письмо/i,
        `${id} implies auto-sending; the product never sends`);
    }
    // The tracker button went with the paid tier; the promise it carried —
    // that a human does the sending — is now a property of every button,
    // asserted by the loop above rather than by one example.
  });

  test('every button records why it is worded that way', () => {
    // The `adapted` field guards against a future translation pass flattening
    // these back into English idioms: each one carries its decision.
    for (const { id, adapted } of buttons) {
      assert.ok(adapted.length > 40, `${id} has no real adaptation rationale`);
    }
  });
});
