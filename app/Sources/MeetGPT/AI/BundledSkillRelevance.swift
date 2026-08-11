import Foundation

/// Relevance ranking for vendored Agent Skills.
///
/// **Primary:** on-device sentence embeddings (`BundledSkillEmbeddingIndex` /
/// Apple `NLEmbedding`) — cosine similarity against the prompt keywords + live
/// meeting text. **Fallback:** token-overlap scoring when embeddings aren't
/// available (tests, missing NL model, empty query encoding).
///
/// Preferred ids from `BundledSkillRouter.map` get a small boost so curated
/// meeting skills still win close calls, but a clearly better catalog match
/// can take the slot.
enum BundledSkillRelevance {
    /// Inputs used to rank skills for a prompt press.
    struct Context: Sendable, Equatable {
        var promptID: String
        /// Free text: call goal, recent transcript, user prompt, etc.
        var query: String = ""
    }

    /// Seed keywords per prompt button — used when the live query is thin and
    /// to bias catalog search toward meeting-relevant methodology.
    static let promptKeywords: [String: [String]] = [
        "agenda":      ["agenda", "meeting", "facilitation", "standup", "board", "scrum", "roadmap"],
        "brainstorm":  ["brainstorm", "ideate", "ideation", "experiment", "discovery", "innovate", "creative"],
        "unresolved":  ["unresolved", "open", "action", "capture", "follow-up", "todo", "parking"],
        "whattoask":   ["question", "ask", "interview", "discovery", "socratic", "probe", "challenge"],
        "factcheck":   ["fact", "verify", "evidence", "research", "source", "claim", "accuracy"],
        "rhetoric":    ["rhetoric", "persuasion", "messaging", "copywriting", "pitch", "negotiate"],
        "answer":      ["answer", "explain", "brief", "executive", "humanizer", "comms"],
        "dispute":     ["dispute", "conflict", "debate", "disagreement", "challenge", "mediate"],
        "risks":       ["risk", "threat", "incident", "postmortem", "competitive", "mitigation"],
        "advice":      ["advice", "coach", "mentor", "strategy", "pricing", "recommend"],
        "tasks":       ["task", "handoff", "plan", "ticket", "backlog", "action", "assign"],
        "summary":     ["summary", "recap", "minutes", "notes", "digest", "synthesize"],
        "logdecision": ["decision", "adr", "log", "record", "commit", "choose"],
        "steelman":    ["steelman", "counterargument", "objection", "rebuttal", "critique",
                        "devil's advocate", "premortem"],
        "commitments": ["commitment", "promise", "outstanding", "overdue", "follow-through",
                        "accountability", "carry-over"],
    ]

    /// Minimum free-text tokens before the token-fallback scans the full catalog.
    static let catalogScanMinQueryTokens = 4
    /// Cap how many catalog hits join the final ranking shortlist.
    static let catalogShortlistLimit = 24

    /// Head start for a curated `BundledSkillRouter.map` seed, decaying down the
    /// seed list so the first-listed seed is the mild favourite.
    ///
    /// This is an ABSOLUTE offset added to a cosine score, so it is only as
    /// meaningful as the spread it competes with — a 2026-07-26 run measured the
    /// median rank-1→rank-5 gap at just 0.024, i.e. this constant is ~6x the whole
    /// ranking signal, and seeds consequently win 73.7% of picks.
    ///
    /// That looks alarming and was TESTED: lowering it to 0.04 let content decide,
    /// raised distinct winners 55→65, and made quality WORSE (routing hit rate
    /// 51.9% → 43.9%) because the freed slots went to plausible-but-wrong catalog
    /// skills. The curated seeds are carrying real signal that cosine over vendor
    /// descriptions cannot reproduce. Left at 0.14 deliberately.
    ///
    /// Re-measure with `SkillRoutingEval` before touching it; `distinct winners`
    /// is NOT the metric — it is maximised by noise.
    static let seedBoost = 0.14
    static let seedBoostDecayPerRank = 0.015

    // MARK: - Public API

    /// Best skill for this context, or nil when the library is empty.
    static func pick(
        context: Context,
        preferredIDs: [String],
        library: [BundledSkill] = BundledSkillLibrary.rankable
    ) -> BundledSkill? {
        rank(context: context, preferredIDs: preferredIDs, library: library).first?.skill
    }

    /// Ranked shortlist (highest score first).
    static func rank(
        context: Context,
        preferredIDs: [String],
        library: [BundledSkill] = BundledSkillLibrary.rankable
    ) -> [(skill: BundledSkill, score: Double)] {
        guard !library.isEmpty else { return [] }

        BundledSkillEmbeddingIndex.ensureBuilt(library: library)
        let embedQuery = embeddingQueryText(for: context)
        if BundledSkillEmbeddingIndex.isReady, !embedQuery.isEmpty {
            let embedded = rankWithEmbeddings(
                embedQuery: embedQuery,
                preferredIDs: preferredIDs,
                library: library)
            if !embedded.isEmpty { return embedded }
        }
        return rankWithTokens(context: context, preferredIDs: preferredIDs, library: library)
    }

    // MARK: - Embedding path

    /// Prompt keywords + free text — what we embed for cosine ranking.
    static func embeddingQueryText(for context: Context) -> String {
        var parts: [String] = []
        parts.append(context.promptID.replacingOccurrences(of: "-", with: " "))
        if let words = promptKeywords[context.promptID] {
            parts.append(words.joined(separator: " "))
        }
        let q = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { parts.append(q) }
        return parts.joined(separator: ". ")
    }

    private static func rankWithEmbeddings(
        embedQuery: String,
        preferredIDs: [String],
        library: [BundledSkill]
    ) -> [(skill: BundledSkill, score: Double)] {
        var preferredRank: [String: Int] = [:]
        for (index, id) in preferredIDs.enumerated() {
            if preferredRank[id] == nil { preferredRank[id] = index }
        }

        // Catalog shortlist by pure cosine, then always include preferred seeds.
        let catalog = BundledSkillEmbeddingIndex.rank(
            query: embedQuery,
            library: library,
            limit: catalogShortlistLimit)

        var candidates: [BundledSkill] = []
        var seen = Set<String>()
        for id in preferredIDs {
            guard let skill = library.first(where: { $0.id == id }),
                  seen.insert(skill.id).inserted else { continue }
            candidates.append(skill)
        }
        for hit in catalog where seen.insert(hit.skill.id).inserted {
            candidates.append(hit.skill)
        }
        if candidates.isEmpty { return [] }

        let scored: [(BundledSkill, Double)] = candidates.compactMap { skill in
                guard let sim = BundledSkillEmbeddingIndex.similarity(
                    query: embedQuery, skillID: skill.id, library: library) else { return nil }
            var total = sim
            if let rank = preferredRank[skill.id] {
                // Small boost — beatable by a clearly better catalog match.
                total += max(0, seedBoost - Double(rank) * seedBoostDecayPerRank)
            }
            return (skill, total)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let lr = preferredRank[lhs.0.id] ?? Int.max
                let rr = preferredRank[rhs.0.id] ?? Int.max
                if lr != rr { return lr < rr }
                return lhs.0.id < rhs.0.id
            }
            .map { (skill: $0.0, score: $0.1) }
    }

    // MARK: - Token fallback

    private static func rankWithTokens(
        context: Context,
        preferredIDs: [String],
        library: [BundledSkill]
    ) -> [(skill: BundledSkill, score: Double)] {
        let queryTokens = queryTokenSet(for: context)
        guard !queryTokens.isEmpty else {
            for id in preferredIDs {
                if let skill = library.first(where: { $0.id == id }) {
                    return [(skill, 1)]
                }
            }
            return []
        }

        var preferredRank: [String: Int] = [:]
        for (index, id) in preferredIDs.enumerated() {
            if preferredRank[id] == nil { preferredRank[id] = index }
        }

        var candidates: [BundledSkill] = []
        var seen = Set<String>()
        for id in preferredIDs {
            guard let skill = library.first(where: { $0.id == id }),
                  seen.insert(skill.id).inserted else { continue }
            candidates.append(skill)
        }

        let freeTextTokens = tokens(in: context.query)
        if freeTextTokens.count >= catalogScanMinQueryTokens || preferredIDs.isEmpty {
            let catalogHits = catalogShortlist(
                queryTokens: queryTokens,
                library: library,
                excluding: seen,
                limit: catalogShortlistLimit)
            candidates.append(contentsOf: catalogHits)
        }

        if candidates.isEmpty {
            candidates = Array(library.prefix(catalogShortlistLimit))
        }

        let scored: [(BundledSkill, Double)] = candidates.map { skill in
            (skill, score(skill: skill, queryTokens: queryTokens, preferredRank: preferredRank[skill.id]))
        }
        return scored
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let lr = preferredRank[lhs.0.id] ?? Int.max
                let rr = preferredRank[rhs.0.id] ?? Int.max
                if lr != rr { return lr < rr }
                return lhs.0.id < rhs.0.id
            }
            .map { (skill: $0.0, score: $0.1) }
    }

    /// Score one skill (token path). `preferredRank` nil = not in the curated map.
    static func score(
        skill: BundledSkill,
        queryTokens: Set<String>,
        preferredRank: Int?
    ) -> Double {
        guard !queryTokens.isEmpty else { return preferredRank == nil ? 0 : 1 }
        let idTokens = tokens(in: skill.id.replacingOccurrences(of: "-", with: " "))
        let nameTokens = tokens(in: skill.name)
        let descTokens = tokens(in: skill.description)
        let bodyHead = tokens(in: String(skill.body.prefix(500)))

        let idHits = Double(idTokens.intersection(queryTokens).count)
        let nameHits = Double(nameTokens.intersection(queryTokens).count)
        let descHits = Double(descTokens.intersection(queryTokens).count)
        let bodyHits = Double(bodyHead.intersection(queryTokens).count)

        var total =
            idHits * 6.0
            + nameHits * 5.0
            + descHits * 3.0
            + min(bodyHits, 8) * 0.5

        let skillCore = idTokens.union(nameTokens)
        if !skillCore.isEmpty {
            let coverage = Double(skillCore.intersection(queryTokens).count) / Double(skillCore.count)
            total += coverage * 4.0
        }

        if let preferredRank {
            total += 8.0
            total += max(0, 6.0 - Double(preferredRank)) * 0.35
        }

        return total
    }

    // MARK: - Tokenization

    static func queryTokenSet(for context: Context) -> Set<String> {
        var set = tokens(in: context.promptID.replacingOccurrences(of: "-", with: " "))
        for word in promptKeywords[context.promptID] ?? [] {
            set.formUnion(tokens(in: word))
        }
        set.formUnion(tokens(in: context.query))
        return set
    }

    static func tokens(in text: String) -> Set<String> {
        var result = Set<String>()
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if current.count >= 3 { result.insert(current) }
                current = ""
            }
        }
        if current.count >= 3 { result.insert(current) }
        return result
    }

    private static func catalogShortlist(
        queryTokens: Set<String>,
        library: [BundledSkill],
        excluding: Set<String>,
        limit: Int
    ) -> [BundledSkill] {
        var scored: [(BundledSkill, Double)] = []
        scored.reserveCapacity(min(library.count, 256))
        for skill in library {
            if excluding.contains(skill.id) { continue }
            let idTokens = tokens(in: skill.id.replacingOccurrences(of: "-", with: " "))
            let nameTokens = tokens(in: skill.name)
            let descTokens = tokens(in: skill.description)
            let hits =
                Double(idTokens.intersection(queryTokens).count) * 6
                + Double(nameTokens.intersection(queryTokens).count) * 5
                + Double(descTokens.intersection(queryTokens).count) * 3
            guard hits >= 6 else { continue }
            scored.append((skill, hits))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }
}
