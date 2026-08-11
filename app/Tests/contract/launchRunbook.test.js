import { readFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { resolve } from 'node:path';

// The launch runbook is the human go-live path. These tests keep it HONEST: every
// repo path it cites must be tracked (so a fresh clone / the operator actually has
// it — the gitignored rotation docs are referenced in prose, not backticked), and
// the safety invariants the sequence depends on are stated.

const doc = readFileSync(resolve('launch/LAUNCH_RUNBOOK.md'), 'utf8');

// Tracked files, so a backticked path that isn't tracked (e.g. a gitignored
// secret doc or a typo) fails the test rather than a fresh clone.
const tracked = new Set(
  execSync('git ls-files', { encoding: 'utf8' }).split('\n').filter(Boolean)
);

// Backticked tokens that look like a repo path (has a slash + extension), minus
// env-style placeholders (https://api.<domain>/… ) and API routes (/api/…).
function citedPaths(md) {
  const out = new Set();
  for (const m of md.matchAll(/`([^`]+)`/g)) {
    const t = m[1].trim();
    if (!/^[\w./-]+\.[a-z]{2,5}$/.test(t)) continue; // path-shaped only
    if (!t.includes('/')) continue;
    if (t.startsWith('/api') || t.includes('<') || t.includes(' ')) continue;
    if (t.startsWith('dist/')) continue; // build output, not a repo source file
    out.add(t);
  }
  return [...out];
}

describe('runbook cites only tracked files (fresh-clone safe)', () => {
  const paths = citedPaths(doc);

  it('extracts a meaningful set of cited paths', () => {
    expect(paths.length).toBeGreaterThanOrEqual(6);
  });

  // Repo-scoped since the split. The runbook describes a system that now spans
  // four repositories, so it cites `functions/…` (cruxwing-api),
  // `web/landing/…` (cruxwing-marketing) and `extension/…` (cruxwing-web) — paths
  // this checkout cannot see. Verifying only what THIS repo owns keeps the check
  // meaningful; asserting on the rest would fail for a reason that is not a bug.
  // The cross-repo citations are listed by the test below so they stay visible
  // rather than silently unverified.
  const FOREIGN = /^(functions|web|extension|deploy|docs|test|contract|server\.js|package)/;
  const ownPaths = citedPaths(doc).filter((p) => !FOREIGN.test(p));
  const foreignPaths = citedPaths(doc).filter((p) => FOREIGN.test(p));

  it('still owns a meaningful number of the cited paths', () => {
    // Guard against the filter swallowing everything and passing vacuously.
    expect(ownPaths.length).toBeGreaterThanOrEqual(3);
  });

  it('records which citations now live in another repository', () => {
    // Not a failure — a fact worth seeing in the output, so nobody assumes the
    // runbook is fully verified here.
    if (foreignPaths.length) {
      console.info('[launch] cross-repo citations, unverified here:', foreignPaths.join(', '));
    }
    expect(Array.isArray(foreignPaths)).toBe(true);
  });

  it.each(ownPaths)('cited path is tracked in git: %s', (p) => {
    expect(tracked.has(p) || existsSync(resolve(p)), `${p} is cited but not tracked`).toBe(true);
    // Stronger: must be tracked, not just present on this disk.
    expect(tracked.has(p), `${p} is cited in the runbook but not tracked in git`).toBe(true);
  });
});

describe('runbook states the safety invariants the sequence relies on', () => {
  it('the StoreKit verifier is fail-closed until configured (503)', () => {
    expect(doc).toMatch(/fail-closed|503/);
    expect(doc).toMatch(/appleReceiptVerifier\.js/);
  });

  it('the secret gate must pass before signing (no baked keys ship)', () => {
    expect(doc).toMatch(/assert-no-baked-secrets\.sh/);
    expect(doc).toMatch(/keyless/i);
  });

  it('analytics must be cookieless (privacy-policy consistency)', () => {
    expect(doc).toMatch(/cookieless/i);
    expect(doc).toMatch(/no-tracking|no tracking/i);
  });

  it('flags the permanent bundle-id decision before submission', () => {
    expect(doc).toMatch(/PERMANENT/);
    expect(doc).toMatch(/com\.meetgpt\.macapp/);
  });

  it('demo account for App Review is email+password, not OTP', () => {
    expect(doc).toMatch(/email\+password/i);
    expect(doc).toMatch(/NOT OTP|not.*OTP/);
  });
});
