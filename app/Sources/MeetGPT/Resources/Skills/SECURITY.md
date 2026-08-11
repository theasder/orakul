# Skills security

Third-party Agent Skills are untrusted methodology. Before they reach the model:

1. Quarantine denylist — `BundledSkillSanitizer.quarantineIDs`
2. Risk gate — `BundledSkillLibrary.rankable` drops every `risk: critical` skill
   from the set the relevance ranker may pick automatically
3. Sanitize — strip invisible unicode; neutralize role / override lines
4. Wrap — `<<<UNTRUSTED_THIRD_PARTY_SKILL>>>` … `<<<END_…>>>`
5. Cap — `BundledSkillRouter.maxBodyChars` + script-fence stripping

Do not map quarantined skills into `BundledSkillRouter.map`. Re-run a catalog
scan after any bulk ingest (see `.context/skills-security-audit/`).

## Reading `SECURITY-AUDIT.md`

The audit is a pattern scan, so its severity column is not a verdict. Most
`crit_*` hits are skills that *teach about* prompt injection (`skill-audit`,
`skill-security-auditor`, `ai-security`, `effective-agent-skills`), and every
`curl | bash` / `rm -rf` hit but one sits inside a fenced block that step 5
deletes before the body reaches the model. Do not quarantine on a pattern hit
alone — check whether the match survives steps 3–5 first.

What the scan does *not* catch is the risk that matters here: a skill whose
methodology is to take a real-world action (send mail, post to social, move
funds, administer a server) being auto-injected into a live meeting prompt.
That is what `risk: critical` marks and what step 2 gates — 74 of 1,188 skills.
They stay in the bundle and resolvable by id; they are only barred from being
chosen for the user. A skill needing an explicit action must be mapped
deliberately, never surfaced by transcript similarity.

## The `risk:` field is the gate, so treat a missing one as a bug

An audit on 2026-07-26 found two action-taking skills rankable —
`google-workspace-cli` (Gmail/Drive/Calendar administration, against an account
this app already holds OAuth tokens for) and `baoyu-post-to-x` (publishes to a
live X account via Chrome automation). Neither was malicious; neither carried a
`risk:` field at all, and the gate only ever excluded an exact `critical`.

Since then:

- an unrecognized value (`risk: high`, or a typo like `crit`) parses to
  `SkillRisk.unrecognized` and is **gated**, not waved through;
- `BundledSkillCatalogTests` fails the build if any shipped skill lands there, so
  a new vocabulary is a deliberate mapping decision rather than a silent
  exclusion.

Missing and explicitly-`unknown` verdicts stay rankable on purpose: 968 of 1,188
skills carry one, so gating them would empty the catalog the ranker exists to
search. That is the residual risk — the gate is only as good as the labels, and
most of the corpus carries no positive safety assertion. When ingesting, label
anything that acts on a real account, and re-run the action-verb sweep over
`description:` lines rather than trusting the pattern scan's severity column.
