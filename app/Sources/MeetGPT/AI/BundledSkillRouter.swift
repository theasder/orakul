import Foundation

/// Maps each quick-prompt button onto vendored open-source Agent Skills and
/// picks the most relevant one for the live meeting context.
///
/// Distilled `PromptSkill` guidance stays the primary short layer; a capped
/// SKILL.md body adds methodology depth. Selection is **relevance-ranked**:
/// curated ids in `map` are preferred seeds, but a better catalog match for the
/// transcript / goal / user prompt can win (`BundledSkillRelevance`).
enum BundledSkillRouter {
    /// Soft cap so a single button can't flood the system prompt with a 16 KB skill.
    static let maxBodyChars = 3_500

    /// Prompt id → preferred skill folder ids (seeds for relevance ranking).
    /// Prefer meeting / product / exec skills; fall back to high-star OSS packs
    /// (Matt Pocock, marketing, humanizer, planning-with-files, scientific).
    static let map: [String: [String]] = [
        "agenda":      ["board-meeting", "scrum-master", "meeting-analyzer", "roadmap-communicator",
                        "board-prep", "sprint-plan"],
        "brainstorm":  ["brainstorm", "experiment-designer", "scientific-brainstorming",
                        "product-discovery", "product-strategist", "founder-coach"],
        "unresolved":  ["capture", "challenge", "brief", "reflect", "to-tickets"],
        "whattoask":   ["grill-with-docs", "hard-call", "ux-researcher-designer", "challenge",
                        "stress-test", "product-discovery"],
        "factcheck":   ["research", "research-summarizer", "research-lookup", "dossier",
                        "risk-management-specialist", "stress-test"],
        "rhetoric":    ["copywriting", "marketing-psychology", "stress-test", "challenge",
                        "sales-engineer", "meeting-analyzer"],
        "answer":      ["humanizer", "brief", "executive-mentor", "research-summarizer",
                        "team-communications"],
        "dispute":     ["hard-call", "challenge", "founder-coach", "crossframe-debate", "reflect"],
        "risks":       ["risk-management-specialist", "competitive-intel", "competitive-teardown",
                        "postmortem", "incident-response", "stress-test"],
        "advice":      ["executive-mentor", "founder-coach", "hard-call", "senior-pm",
                        "pricing-strategist", "pricing-strategy", "launch-strategy",
                        "customer-success-manager"],
        "tasks":       ["planning-with-files", "handoff", "capture", "to-tickets",
                        "scrum-master", "incident-commander", "senior-pm"],
        "summary":     ["humanizer", "meeting-analyzer", "brief", "team-communications",
                        "doc-coauthoring", "postmortem", "reflect"],
        "logdecision": ["decision-logger", "product-decision-agent", "doc-coauthoring",
                        "hard-call", "board-prep", "capture"],
        "steelman":    ["crossframe-debate", "challenge", "stress-test", "adversarial-reviewer",
                        "hard-call", "anti-sycophancy"],
        "commitments": ["accint-commitments", "handoff", "capture", "to-tickets",
                        "scrum-master", "decision-logger"],
    ]

    /// Compact guidance for a prompt button: relevance-picked skill, truncated
    /// and wrapped so the model treats it as methodology depth — not authority.
    static func guidance(for promptID: String?, query: String? = nil) -> String? {
        guard let skill = pick(for: promptID, query: query) else { return nil }
        return format(skill)
    }

    /// Relevance-ranked skill for this button + optional live meeting text.
    static func pick(for promptID: String?, query: String? = nil) -> BundledSkill? {
        // Custom prompts intentionally use only their user-authored text and
        // the base safety instructions. Treating an unknown id as an empty
        // seed list used to scan and inject an arbitrary catalog skill, in
        // addition to paying the full 1,188-skill cold-ranking cost.
        guard let promptID, let preferred = map[promptID], !preferred.isEmpty else {
            return nil
        }
        return BundledSkillRelevance.pick(
            context: .init(promptID: promptID, query: query ?? ""),
            preferredIDs: preferred)
    }

    /// Ranked shortlist (for tests / debug UI). Preferred map seeds + catalog.
    static func ranked(for promptID: String, query: String? = nil) -> [(skill: BundledSkill, score: Double)] {
        BundledSkillRelevance.rank(
            context: .init(promptID: promptID, query: query ?? ""),
            preferredIDs: map[promptID] ?? [])
    }

    /// Preferred map ids that currently resolve from the bundle (for tests/UI).
    static func resolvedIDs(for promptID: String) -> [String] {
        (map[promptID] ?? []).filter { BundledSkillLibrary.skill(id: $0) != nil }
    }

    static func format(_ skill: BundledSkill) -> String {
        // Never surface quarantined skills even if somehow resolved.
        if BundledSkillSanitizer.quarantineIDs.contains(skill.id) { return "" }
        var body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop sections that only make sense with upstream scripts/binaries we
        // deliberately do not vendor (keep methodology + output contracts).
        body = stripScriptHeavySections(body)
        // Prompt-injection / steganography defenses (unicode, role markers, overrides).
        body = BundledSkillSanitizer.sanitize(body)
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars))
            if let lastBreak = body.lastIndex(where: { $0 == "\n" }) {
                body = String(body[..<lastBreak])
            }
            body += "\n…"
        }
        let title = skill.name.isEmpty ? skill.id : skill.name
        return BundledSkillSanitizer.wrapForPrompt(id: skill.id, title: title, body: body)
    }

    /// Remove fenced code / "run this script" heavy blocks that would waste tokens.
    private static func stripScriptHeavySections(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            // Skip obvious script-invocation lines.
            if trimmed.hasPrefix("python ") || trimmed.hasPrefix("python3 ")
                || trimmed.contains(".py ") || trimmed.hasSuffix(".py")
                || trimmed.hasPrefix("./") && trimmed.contains(".py") {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
