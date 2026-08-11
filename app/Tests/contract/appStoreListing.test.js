import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { resolve } from 'node:path';

// M14a — the App Store Connect listing copy. App Store fields have HARD length
// limits; a field over the limit is rejected at upload. This parses the asc-*
// blocks and enforces the limits, plus the honesty non-negotiable (no "certified"
// claim, no fabricated ratings, no hardcoded prices in the description).

const doc = readFileSync(resolve('launch/app-store-listing.md'), 'utf8');

// Extract a ```asc-<field>\n...\n``` fenced block, trimmed.
function field(name) {
  const re = new RegExp('```asc-' + name + '\\n([\\s\\S]*?)```', 'm');
  const m = doc.match(re);
  expect(m, `listing must contain an asc-${name} block`).toBeTruthy();
  return m[1].trimEnd();
}

// Apple's documented App Store Connect field limits.
const LIMITS = { name: 30, subtitle: 30, promotional: 170, keywords: 100, description: 4000 };

describe('App Store field length limits', () => {
  it.each(Object.entries(LIMITS))('%s stays within its %d-char limit', (fieldName, limit) => {
    const value = field(fieldName).trim();
    expect(value.length, `${fieldName} is ${value.length} chars`).toBeLessThanOrEqual(limit);
    expect(value.length, `${fieldName} must not be empty`).toBeGreaterThan(0);
  });
});

describe('keywords are well-formed for ASO', () => {
  it('is comma-separated with no spaces (spaces waste the 100-char budget)', () => {
    const kw = field('keywords').trim();
    expect(kw).not.toMatch(/,\s/); // no space after commas
    expect(kw.split(',').length).toBeGreaterThanOrEqual(6);
  });
});

describe('honesty guardrails', () => {
  const description = field('description');
  const promotional = field('promotional');

  it('never claims a completed certification', () => {
    for (const text of [description, promotional, field('subtitle'), field('name')]) {
      expect(text).not.toMatch(/\bcertified\b|\bSOC ?2\b|\bISO ?27001\b/i);
    }
  });

  it('does not fabricate ratings, awards, or user counts', () => {
    // Note: the user-count pattern requires a LEADING digit so ordinary list
    // commas (e.g. "Meet, Teams") don't false-positive on "teams".
    expect(description).not.toMatch(/\b\d+(\.\d+)?\s*stars?\b|★|\b#1\b|\baward(s|ed)?\b|\b\d[\d,]*\+?\s*(users|teams|customers)\b/i);
  });

  it('hardcodes no prices — the app shows live catalog prices', () => {
    expect(description).not.toMatch(/\$\d/);
    expect(promotional).not.toMatch(/\$\d/);
  });

  it('describes what ships, including the on-device + human-confirmed-decisions truths', () => {
    expect(description).toMatch(/on-device/i);
    expect(description).toMatch(/human confirms|confirmed by a human|until a human confirms/i);
    expect(description).toMatch(/consent/i);
  });
});
