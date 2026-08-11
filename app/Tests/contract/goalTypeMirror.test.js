import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// The Mac app keeps its own copy of the goal taxonomy, because the decision
// extractor coerces anything outside it to 'planning' BEFORE the API is called.
//
// That makes drift silent instead of loud. While the Swift list held only the
// original six, a retrospective or a design review was rewritten as a planning
// decision, stored as one, and given a planning-shaped follow-up — no 400, no
// warning, no way to notice from either side.
//
// In the monorepo this compared Swift against the server's own module. Across
// repositories it compares against contract/contract.json, the document the API
// publishes. A stale vendored copy makes this test verify agreement with a server
// that no longer exists, so CI must also check the copy is current.
const CONTRACT = JSON.parse(readFileSync(resolve('contract/contract.json'), 'utf8'));
const SWIFT = readFileSync(resolve('Sources/MeetGPT/AI/DecisionLogService.swift'), 'utf8');

function swiftGoalTypes() {
  const match = /static let goalTypes = \[([\s\S]*?)\]/.exec(SWIFT);
  expect(match, 'DecisionLogService must declare `static let goalTypes = [...]`').toBeTruthy();
  return match[1]
    .split(',')
    .map((entry) => entry.trim().replace(/^"|"$/g, '').trim())
    .filter((entry) => entry.length && !entry.startsWith('//'));
}

describe('Mac goal taxonomy mirrors the published contract', () => {
  it('parses a non-trivial list out of the Swift source', () => {
    // Vacuous-pass guard: a regex that silently matched nothing would make every
    // assertion below trivially true.
    const parsed = swiftGoalTypes();
    expect(parsed.length).toBeGreaterThan(5);
    for (const goalType of parsed) expect(goalType).toMatch(/^[a-z][a-z_]*$/);
  });

  it('holds exactly the contract goal types, in the same order', () => {
    expect(swiftGoalTypes()).toEqual(CONTRACT.goalTypes);
  });

  it('every goal the client can send has fields defined server-side', () => {
    for (const goalType of swiftGoalTypes()) {
      expect(CONTRACT.goalFields[goalType], `${goalType} has no server contract`).toBeTruthy();
    }
  });

  it('no server goal is unreachable from the Mac app', () => {
    // The direction that bit: a goal the extractor can never emit is a contract
    // nobody can reach, which is the state all four added goals were in.
    const client = new Set(swiftGoalTypes());
    for (const goalType of CONTRACT.goalTypes) {
      expect(client.has(goalType), `${goalType} exists server-side but the app cannot emit it`).toBe(true);
    }
  });
});

describe('Mac call themes mirror the published contract', () => {
  const THEME_SRC = readFileSync(resolve('Sources/MeetGPT/Models/CallTheme.swift'), 'utf8');

  function swiftThemes() {
    const body = THEME_SRC.slice(THEME_SRC.indexOf('enum CallTheme'), THEME_SRC.indexOf('var id: String'));
    // `[^\n]` deliberately, not `\s`: `\s` matches newlines, so the class spans
    // consecutive `case` lines and captures the word "case" itself as a member.
    return [...new Set([...body.matchAll(/^[ \t]*case[ \t]+([a-zA-Z, \t]+)$/gm)]
      .flatMap((m) => m[1].split(',').map((s) => s.trim()))
      .filter(Boolean))];
  }

  it('parses a real list of themes out of the Swift enum', () => {
    const parsed = swiftThemes();
    expect(parsed.length).toBeGreaterThan(5);
    expect(parsed).toContain('sales');
  });

  it('every theme the app can infer has a server lens', () => {
    // A theme with no lens degrades to a generic scan, invisibly.
    for (const theme of swiftThemes()) {
      expect(CONTRACT.callThemes, `CallTheme.${theme} has no domain lens`).toContain(theme);
    }
  });

  it('no lens is unreachable from the app', () => {
    const themes = new Set(swiftThemes());
    for (const theme of CONTRACT.callThemes) {
      expect(themes.has(theme), `lens "${theme}" matches no CallTheme`).toBe(true);
    }
  });
});
