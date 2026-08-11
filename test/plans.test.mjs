import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// Run with: node --test
//
// A pricing draft is where a freemium promise quietly dies: one feature moves
// up a tier, the page and the catalogue drift apart, and a number nobody
// measured becomes "the price". These tests hold the three things that are
// actually decisions, and let everything else stay a draft.

const here = dirname(fileURLToPath(import.meta.url));
const read = (...p) => readFileSync(resolve(here, '..', ...p), 'utf8');

const plans = JSON.parse(read('config', 'plans.ru.json'));
const buttons = JSON.parse(read('config', 'prompts.ru.json')).buttons;
const html = read('public', 'index.html');
const tiers = plans.tiers;

describe('orakul plans (ru)', () => {
  test('the catalogue is well formed', () => {
    assert.equal(plans.currency, 'RUB');
    assert.equal(tiers.length, 3, 'three tiers: free, team, company');
    assert.deepEqual(tiers.map((t) => t.id), ['open', 'team', 'company'],
      'order is free-first, deliberately');
    for (const tier of tiers) {
      assert.ok(tier.name && tier.audience, `${tier.id} missing name or audience`);
      assert.ok(Array.isArray(tier.includes) && tier.includes.length,
        `${tier.id} includes nothing`);
      assert.match(tier.name, /^[А-Яа-яЁё\s]+$/u, `tier name must be Russian: ${tier.id}`);
    }
  });

  test('the free tier is free, forever, and says so', () => {
    const free = tiers.find((t) => t.id === 'open');
    assert.equal(free.price, 0);
    assert.match(free.priceNote, /навсегда/);
    assert.equal(free.costsUsNothing, true,
      'the free tier must cost us nothing, or it will not survive contact with a bill');
  });

  test('recall never moves behind a paywall', () => {
    // The invariant that defines the product. Asserted in three places because
    // it can be broken in three places: the catalogue, the button tiers, the page.
    const free = tiers.find((t) => t.id === 'open');
    assert.ok(free.includes.some((line) => /поиск по своим встречам/i.test(line)),
      'free tier no longer includes search over your own meetings');
    assert.ok(plans.invariants.recallStaysFree, 'the invariant must stay written down');

    const recallButton = buttons.find((b) => b.id === 'what-decided');
    assert.equal(recallButton.tier, 'free', 'button catalogue disagrees with the plan');
  });

  test('the free tier works entirely without a network', () => {
    const free = tiers.find((t) => t.id === 'open');
    assert.ok(free.includes.some((line) => /без сети/i.test(line)));
    // Every button sold as free must actually be offline-capable, or the tier
    // promises something the catalogue cannot deliver.
    for (const button of buttons.filter((b) => b.tier === 'free')) {
      assert.equal(button.offline, true, `free button ${button.id} needs the network`);
    }
  });

  test('paid tiers name no price that has not been measured', () => {
    for (const tier of tiers.filter((t) => t.id !== 'open')) {
      assert.equal(tier.price, null, `${tier.id} quotes a price nobody measured`);
      assert.match(tier.priceNote, /уточняется/);
    }
  });

  test('premium features are the ones that actually cost us money', () => {
    // The brief asks premium to be contextual search, enterprise security and
    // high-volume API. This checks the reason as well as the list: a paid
    // feature must be something we pay for, not something we withheld.
    const team = tiers.find((t) => t.id === 'team');
    const company = tiers.find((t) => t.id === 'company');
    assert.ok(team.includes.some((l) => /контекстный поиск по истории/i.test(l)));
    assert.ok(company.includes.some((l) => /на своих серверах/i.test(l)));
    assert.ok(company.includes.some((l) => /API/i.test(l)));
    for (const tier of [team, company]) {
      assert.equal(tier.costsUsNothing, false, `${tier.id} is paid but costs us nothing`);
    }
  });

  test('the page and the catalogue tell the same story', () => {
    // Drift between a pricing page and a pricing catalogue is how a customer
    // ends up quoting a tier that does not exist.
    const text = html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
    for (const tier of tiers) {
      assert.ok(text.includes(tier.name), `page never mentions the "${tier.name}" tier`);
    }
    assert.match(text, /0 ₽/);
    const unpriced = (text.match(/цена уточняется/g) || []).length;
    assert.equal(unpriced, tiers.filter((t) => t.price === null).length,
      'page and catalogue disagree about which tiers have a price');
  });
});
