import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test   (no dependencies, nothing to install)
//
// The rule this file enforces is the one the Cruxwing landing already lives by:
// no claim without something real behind it. A page for a tool that listens to
// people's meetings earns trust by being checkable, and these numbers are
// checkable — they come from cruxwing-app/docs/ROADMAP-RICE-2026H2.md and from
// the sources cited in orakul/docs/RESEARCH-AND-PLAN.md.

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(resolve(here, '..', 'public', 'index.html'), 'utf8');
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

  test('leads with the pain the research actually found', () => {
    // "договорённости живут в головах и чатах" and re-deciding are the two
    // failures Russian practitioners describe in their own words
    // (RESEARCH-AND-PLAN.md §1.2). The hero must say that, not a generic
    // productivity claim.
    assert.match(text, /договорённости живут в головах и чатах/i);
    assert.match(text, /решает то же самое заново|решать одно и то же/i);
  });

  test('promises a quote, and admits what happens without one', () => {
    // The whole trust argument: an answer is grounded in transcript words, and
    // an ungrounded answer is not shown at all.
    assert.match(text, /цитат/i);
    assert.match(text, /Если этих слов в ней нет — ответа не будет/);
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
  });

  test('marks every unreleased connector as unreleased', () => {
    // Dashed chips are a visual promise; the class is what makes it testable.
    // Anything named here that is not built yet must carry `soon`, or the page
    // advertises an integration a user cannot have.
    for (const tool of ['WEEEK', 'YouGile', 'Pyrus', 'SberJazz', 'TrueConf']) {
      const chip = new RegExp(`<span class="tool soon">${tool}</span>`);
      assert.match(html, chip, `${tool} is not built yet and must be marked soon`);
    }
    assert.match(text, /Пунктиром отмечено то, что ещё в работе/);
  });

  test('names the licence, because "open source" alone is not a licence', () => {
    assert.match(text, /Apache 2\.0/);
  });

  test('quotes no price it has not decided', () => {
    // A free tier that is real, and paid tiers that say "not decided" rather
    // than inventing a number somebody might plan a budget around.
    assert.match(text, /0 ₽/);
    const paid = (text.match(/цена уточняется/g) || []).length;
    assert.equal(paid, 2, 'both paid tiers must decline to quote a price');
    assert.doesNotMatch(text, /\d+\s*₽\s*\/\s*мес|\d{3,}\s*₽/, 'no invented prices');
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
    assert.doesNotMatch(html, /(src|href)="https?:\/\//i, 'no external origins');
    assert.doesNotMatch(html, /@import|url\(https?:/i, 'no remote CSS or fonts');
  });

  test('respects reduced motion and keyboard focus', () => {
    assert.match(html, /@media \(prefers-reduced-motion: reduce\)/);
    assert.match(html, /:focus-visible/);
  });
});
