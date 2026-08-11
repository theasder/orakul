import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// The Mac app mirrors the server's tariff so the credits rail can render without
// a round-trip. A drifted mirror shows the user an allowance the server will not
// honour — they are told they have credits and the request is refused.
//
// Compared against contract/contract.json rather than the server's own module,
// which this repository can no longer import.
const CONTRACT = JSON.parse(readFileSync(resolve('contract/contract.json'), 'utf8'));
const SWIFT = readFileSync(resolve('Sources/MeetGPT/Tariff/TariffAllowance.swift'), 'utf8');

function swiftAllowances() {
  // `1_500` is legal Swift, so digit separators must be stripped or ultra is
  // silently skipped and the test passes without checking it.
  const rows = [...SWIFT.matchAll(
    /case \.(\w+):\s*\n\s*return TariffAllowance\(copilotHours: ([\d_]+), computeCredits: ([\d_]+), groundedCycles: ([\d_]+)\)/g
  )];
  const n = (s) => Number.parseInt(s.replace(/_/g, ''), 10);
  return Object.fromEntries(rows.map((m) => [m[1], {
    copilotHours: n(m[2]), computeCredits: n(m[3]), groundedCycles: n(m[4]),
  }]));
}

describe('Swift tariff mirror matches the published contract', () => {
  it('parses every tier out of the Swift source', () => {
    // Vacuous-pass guard: an empty parse would make the comparison trivially true.
    const parsed = swiftAllowances();
    expect(Object.keys(parsed).sort()).toEqual(['free', 'premium', 'pro', 'ultra']);
  });

  it('agrees on hours, cloud credits and research runs for every tier', () => {
    const parsed = swiftAllowances();
    for (const [tier, swift] of Object.entries(parsed)) {
      const server = CONTRACT.allowances[tier];
      expect(server, `contract has no ${tier}`).toBeTruthy();
      expect(swift.copilotHours, `${tier} copilotHours`).toBe(server.copilotHours);
      expect(swift.computeCredits, `${tier} computeCredits`).toBe(server.computeCredits);
      expect(swift.groundedCycles, `${tier} groundedCycles`).toBe(server.groundedCycles);
    }
  });

  it('the contract carries the copilot pool the client does not yet mirror', () => {
    // Deliberate asymmetry, recorded rather than assumed: the Mac app gates the
    // co-pilot on HOURS, so it has no need of copilotCredits — but the pool must
    // exist server-side or the advertised hours are unfunded again.
    for (const tier of Object.keys(CONTRACT.allowances)) {
      expect(CONTRACT.allowances[tier].copilotCredits, tier).toBeGreaterThan(0);
    }
  });

  it('visible compute-credit copy agrees with the enforced allowance', () => {
    for (const [tier, allowance] of Object.entries(CONTRACT.allowances)) {
      const feature = CONTRACT.tierFeatures[tier]
        .find((item) => /compute credits \/ month/i.test(item));
      expect(feature, `${tier} has no visible compute-credit allowance`).toBeTruthy();
      const visibleCredits = Number.parseInt(feature.match(/[\d,]+/)[0].replace(/,/g, ''), 10);
      expect(visibleCredits, `${tier} visible compute-credit copy`).toBe(allowance.computeCredits);
    }
  });
});
