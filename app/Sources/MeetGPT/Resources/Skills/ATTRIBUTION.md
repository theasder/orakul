# Vendored Agent Skills — attribution & licenses

These are **real, third-party Agent Skills** (`SKILL.md` files) vendored into
the app bundle and loaded at runtime by `BundledSkillLibrary`. Only
**permissively licensed** skills are included (MIT / Apache-2.0 / equivalent
frontmatter). Proprietary Anthropic document skills (`docx` / `pptx` / `xlsx` /
`pdf`) are deliberately excluded.

Each skill keeps its upstream license. Full license texts live alongside this
file (`LICENSE-*.txt`). Machine-readable provenance for the bulk ingest is in
`INGEST_MANIFEST.json`.

At prompt time, `BundledSkillRouter` **relevance-ranks** skills for each
quick-prompt button using on-device sentence embeddings (Apple
`NLEmbedding`) when available, with token-overlap as fallback. Curated
`map` seeds get a small boost; a clearer catalog match for the call goal /
transcript / user prompt can still win. One capped body is layered after
the distilled `PromptSkill` guidance.

## Catalog (high-star GitHub sources)

| Skills | Stars (approx) | License | Repository |
|-------:|---------------:|---------|------------|
| 491 | 43k | MIT (packaging) + per-skill frontmatter | [sickn33/agentic-awesome-skills](https://github.com/sickn33/agentic-awesome-skills) |
| 345 | 23k | MIT | [alirezarezvani/claude-skills](https://github.com/alirezarezvani/claude-skills) |
| 144 | 31k | MIT | [K-Dense-AI/scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) |
| 73 | 23k | MIT | [Donchitos/Claude-Code-Game-Studios](https://github.com/Donchitos/Claude-Code-Game-Studios) |
| 47 | 40k | MIT | [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills) |
| 41 | 174k | MIT | [mattpocock/skills](https://github.com/mattpocock/skills) |
| 22 | 24k | MIT | [JimLiu/baoyu-skills](https://github.com/JimLiu/baoyu-skills) |
| 13 | 162k | Apache-2.0 | [anthropics/skills](https://github.com/anthropics/skills) (OSS subset only) |
| 10 | 2.7k | Apache-2.0 | [RKiding/Awesome-finance-skills](https://github.com/RKiding/Awesome-finance-skills) |
| 6 | 25k | MIT | [OthmanAdi/planning-with-files](https://github.com/OthmanAdi/planning-with-files) |
| 1 | 29k | MIT | [blader/humanizer](https://github.com/blader/humanizer) |

**Total: 1,189** (after security quarantine) unique `SKILL.md` folders (~20 MB). Counts above include earlier
seeds. Duplicates by content hash and id collisions are skipped; `.gemini` /
plugin mirrors are not vendored. Exact id → repo map: `INGEST_MANIFEST.json`.

### Apache-2.0 — anthropics/skills (OSS subset)

Includes: `internal-comms`, `brand-guidelines`, `doc-coauthoring`, plus additional
Apache skills such as `frontend-design`, `mcp-builder`, `skill-creator`,
`canvas-design`, `algorithmic-art`, `webapp-testing`, `theme-factory`,
`claude-api`, `slack-gif-creator`, `web-artifacts-builder`.

### MIT — meeting / product seeds (alirezarezvani + peers)

Primary meeting-copilot mappings still prefer skills such as
`meeting-analyzer`, `product-discovery`, `challenge`, `stress-test`, `capture`,
`research-summarizer`, `scrum-master`, `senior-pm`, `hard-call`, `decision-logger`,
`board-meeting`, `brief`, `founder-coach`, `executive-mentor`, `postmortem`,
`incident-response`, `humanizer`, `planning-with-files`, marketing skills
(`copywriting`, `competitive-intel`, `pricing-strategist`), and Matt Pocock
workflow skills (`research`, `grill-with-docs`, `to-tickets`, `brainstorm`).

See `INGEST_MANIFEST.json` for the full id → repo → license map.

## Security & prompt-injection review (2026-07-16)

All **1,193** vendored `SKILL.md` files were pattern-scanned for prompt injection,
role hijacks, credential harvest, curl|shell, hidden unicode, and similar risks.

**Findings**
- No routed meeting-prompt skills contained real imperative injection payloads.
- Nearly all "critical" pattern hits were **educational false positives** (security
  auditor skills quoting attack strings as examples to detect).
- **Quarantined & removed** (also denylisted in `BundledSkillSanitizer.quarantineIDs`):
  - `fable-safe-prompt` — rewrites prompts to evade safety classifiers
  - `red-team`, `security-pen-testing` — offensive attack planning / exploitation
  - `emblemai-crypto-wallet` — executes crypto transfers (upstream `risk: critical`)
- One zero-width character was stripped from `aws-sst-development`.

**Runtime hardening**
- Skill bodies are sanitized (`BundledSkillSanitizer`) before prompt use: invisible
  unicode stripped, role markers / override lines neutralized.
- Applied skills are wrapped in `<<<UNTRUSTED_THIRD_PARTY_SKILL>>>` delimiters so
  the model treats them as methodology data, not system authority.
- Bodies remain capped (~3,500 chars) and script fences are stripped.

Full scan notes: `SECURITY-AUDIT.md` in this folder.

## Notes

- Skills are vendored as their `SKILL.md` body (frontmatter: `name`,
  `description`, often `license`). Upstream `examples/`, scripts, and assets are
  not vendored. Script-invocation lines are stripped at apply time.
- Distilled methodology also lives in built-in `PromptSkill` guidance
  (`Sources/MeetGPT/Models/PromptSkill.swift`).
- `brand-guidelines` reflects **Anthropic's** palette — swap tokens before
  customer-facing use.
- Agentic-awesome entries are included only when the skill frontmatter (or
  source field) cites a permissive license; unknown-license community copies
  are skipped.
- To add a skill: drop `<id>/SKILL.md` here, record source + license, map it in
  `BundledSkillRouter.map` if it should power a prompt button, and rebuild.
- Copyright of each vendored skill remains with its original authors.
