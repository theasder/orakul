import Foundation

/// Token- and latency-aware policy shared by every connected-app grounding path.
///
/// Retrieval and prompt attachment are separate budgets. A connector result may
/// be cheap to read (or already cached) but expensive to resend to every model
/// call. The policy therefore:
///
/// - ranks sources before network fan-out, using the live call theme and query;
/// - caps the default source count by tariff while respecting explicit one-off
///   budgets (for example transcript enhancement);
/// - removes duplicate/near-duplicate evidence across apps; and
/// - packs complete, source-diverse facts into a bounded model context.
///
/// No LLM is used here. Grounding should save hallucinations, not add a second
/// billable request merely to decide what reaches the first one.
enum GroundingContextPolicy {
    struct SourceSlotPlan: Equatable, Sendable {
        /// First-party ledger entries admitted to the total.
        let ledger: Int
        /// Maximum MCP/team requests that may be created after the ledger.
        let connectors: Int
        /// Google reads still available after actual connector results.
        let google: Int
    }

    struct SourceCandidate: Equatable, Sendable {
        let id: String
        let searchableText: String
        let strongFor: Set<CallTheme>

        init(id: String, searchableText: String, strongFor: Set<CallTheme> = []) {
            self.id = id
            self.searchableText = searchableText
            self.strongFor = strongFor
        }
    }

    /// Default connector fan-out for an ordinary grounded request. Explicit
    /// feature budgets remain authoritative: an intentional six-source
    /// transcript merge may pass six, while Blind Spot passes one.
    static func defaultRetrievalSourceLimit(for tier: Tier) -> Int {
        switch tier {
        case .free: return 2
        case .pro: return 2
        case .premium: return 3
        case .ultra: return 4
        }
    }

    /// Source diversity in the final prompt. This includes cheap first-party
    /// ledger and Google snippets, not only MCP calls.
    static func attachmentSourceLimit(for tier: Tier) -> Int {
        switch tier {
        case .free: return 2
        case .pro: return 3
        case .premium: return 4
        case .ultra: return 5
        }
    }

    /// Evidence characters attached to one provider request. At the usual
    /// four-characters-per-token estimate these are ~500/800/1,125/1,500 input
    /// tokens respectively, below the tariff's fixed input-credit boundary.
    static func attachmentCharacterLimit(for tier: Tier) -> Int {
        switch tier {
        case .free: return 2_000
        case .pro: return 3_200
        case .premium: return 4_500
        case .ultra: return 6_000
        }
    }

    /// One total budget across the three grounding layers. Callers recompute
    /// after connector results arrive; empty MCP searches release their slot to
    /// Google, while successful MCP results prevent Google from exceeding the
    /// cap. This is pure so the cross-layer invariant is regression-testable.
    static func sourceSlotPlan(totalLimit: Int,
                               ledgerResults: Int,
                               connectorResults: Int) -> SourceSlotPlan {
        let total = max(0, totalLimit)
        let ledger = min(total, max(0, ledgerResults))
        let connectorBudget = max(0, total - ledger)
        let connectorsUsed = min(connectorBudget, max(0, connectorResults))
        return SourceSlotPlan(
            ledger: ledger,
            connectors: connectorBudget,
            google: max(0, total - ledger - connectorsUsed))
    }

    /// Empty and content-free requests must not turn connector-specific query
    /// hints into a broad search. A concrete identifier counts on its own;
    /// otherwise at least one non-boilerplate term is required.
    static func retrievalIsWorthwhile(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if containsConcreteIdentifier(trimmed) { return true }
        return !meaningfulTerms(in: trimmed).isEmpty
    }

    /// Free deterministic search query for automatic co-pilot work. The goal
    /// supplies stable intent and the recent tail supplies the live entity or
    /// ticket. Keeping this below connector query limits leaves room for each
    /// app's own `ConnectorProbeStrategy` hint.
    static func backgroundQuery(goal: String,
                                recentTranscript: String,
                                maxChars: Int = 180) -> String {
        guard maxChars > 0 else { return "" }
        let cleanGoal = collapseWhitespace(goal)
        let cleanTail = collapseWhitespace(String(recentTranscript.suffix(600)))
        if cleanGoal.isEmpty { return clippedAtBoundary(cleanTail, cap: maxChars) }
        if cleanTail.isEmpty { return clippedAtBoundary(cleanGoal, cap: maxChars) }

        let separator = " — now: "
        let goalCap = min(110, max(1, maxChars / 2))
        let goalPart = clippedAtBoundary(cleanGoal, cap: goalCap)
        let tailCap = max(0, maxChars - goalPart.count - separator.count)
        guard tailCap > 0 else { return clippedAtBoundary(goalPart, cap: maxChars) }
        var tailPart = String(cleanTail.suffix(tailCap))
        // suffix() can begin halfway through a word. Drop that fragment while
        // keeping the most recent entity/identifier at the end of the query.
        if cleanTail.count > tailCap,
           let firstSpace = tailPart.firstIndex(where: \.isWhitespace) {
            tailPart = String(tailPart[tailPart.index(after: firstSpace)...])
        }
        return goalPart + separator + tailPart
    }

    /// Rank before any network task is created. Theme-strength dominates, then
    /// literal goal overlap; ties retain the caller's stable catalog order.
    static func selectSources(_ candidates: [SourceCandidate],
                              query: String,
                              tier: Tier,
                              requestedLimit: Int? = nil) -> [SourceCandidate] {
        let limit = max(0, requestedLimit ?? defaultRetrievalSourceLimit(for: tier))
        guard limit > 0, retrievalIsWorthwhile(query: query) else { return [] }
        let theme = CallTheme.infer(goal: query, transcript: "")
        let queryTerms = meaningfulTerms(in: query)

        return candidates.enumerated()
            .map { index, candidate in
                let candidateTerms = meaningfulTerms(in: candidate.searchableText)
                let overlap = queryTerms.intersection(candidateTerms).count
                let exactID = queryTerms.contains(candidate.id.lowercased()) ? 1 : 0
                let themeStrength = candidate.strongFor.contains(theme) ? 1 : 0
                return (index, candidate, themeStrength, exactID, overlap)
            }
            .sorted {
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                if $0.3 != $1.3 { return $0.3 > $1.3 }
                if $0.4 != $1.4 { return $0.4 > $1.4 }
                return $0.0 < $1.0
            }
            .prefix(limit)
            .map(\.1)
    }

    /// Deduplicate and fairly pack snippets for a model prompt. Returned text is
    /// always copied from connector evidence; nothing is summarized or invented.
    static func optimizedSnippets(_ snippets: [GroundingSnippet],
                                  query: String = "",
                                  tier: Tier,
                                  characterLimit: Int? = nil,
                                  sourceLimit: Int? = nil) -> [GroundingSnippet] {
        let cap = max(0, characterLimit ?? attachmentCharacterLimit(for: tier))
        let maxSources = max(0, sourceLimit ?? attachmentSourceLimit(for: tier))
        guard cap > 0, maxSources > 0 else { return [] }

        let queryTerms = meaningfulTerms(in: query)
        var seenSourcePayloads = Set<String>()
        let ranked = snippets.enumerated().compactMap { index, snippet -> RankedSnippet? in
            let trimmed = collapseWhitespace(snippet.text)
            guard !trimmed.isEmpty else { return nil }
            let sourceKey = snippet.sourceID ?? snippet.serverName.lowercased()
            let payloadKey = sourceKey + "|" + normalizedEvidence(trimmed)
            guard seenSourcePayloads.insert(payloadKey).inserted else { return nil }
            let evidenceTerms = meaningfulTerms(in: trimmed + " " + (snippet.readFor ?? ""))
            let overlap = queryTerms.intersection(evidenceTerms).count
            let freshness = snippet.staleAge == nil ? 1 : 0
            return RankedSnippet(index: index, snippet: snippet, overlap: overlap,
                                 freshness: freshness)
        }.sorted {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.freshness != $1.freshness { return $0.freshness > $1.freshness }
            return $0.index < $1.index
        }

        let selected = Array(ranked.prefix(maxSources))
        guard !selected.isEmpty else { return [] }

        // Split each source into traceable facts, then dedupe the facts across
        // sources. A duplicate CRM note mirrored into Slack should cost tokens
        // once, while both genuinely distinct sources keep a fair slice.
        var seenFacts: [[String]] = []
        var factsBySource: [(GroundingSnippet, [String])] = []
        for item in selected {
            var facts: [String] = []
            for fact in evidenceUnits(item.snippet.text) {
                let tokens = Array(meaningfulTerms(in: fact)).sorted()
                guard !tokens.isEmpty else { continue }
                guard !seenFacts.contains(where: { nearDuplicate(tokens, $0) }) else { continue }
                seenFacts.append(tokens)
                facts.append(fact)
            }
            // Structured payloads occasionally have no sentence boundary. Keep
            // one bounded verbatim unit rather than dropping the source.
            if facts.isEmpty, seenFacts.isEmpty {
                facts = [collapseWhitespace(item.snippet.text)]
            }
            if !facts.isEmpty { factsBySource.append((item.snippet, facts)) }
        }
        guard !factsBySource.isEmpty else { return [] }

        var remaining = cap
        var output: [GroundingSnippet] = []
        for (offset, pair) in factsBySource.enumerated() {
            let slots = factsBySource.count - offset
            let fairShare = slots > 0 ? remaining / slots : remaining
            guard fairShare > 0 else { break }
            let text = packFacts(pair.1, cap: fairShare)
            guard !text.isEmpty else { continue }
            output.append(GroundingSnippet(
                serverName: pair.0.serverName,
                toolName: pair.0.toolName,
                text: text,
                sourceID: pair.0.sourceID,
                readFor: pair.0.readFor,
                staleAge: pair.0.staleAge))
            remaining = max(0, remaining - text.count)
        }
        return output
    }

    static func canonicalQuery(_ query: String) -> String {
        let folded = query
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "[\\s\\n\\r\\t]+", with: " ",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }

    /// Character-safe, word-boundary clipping shared with Blind Spot packing.
    static func clippedAtBoundary(_ text: String, cap: Int) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        guard cap > 1 else { return "…" }
        let prefix = String(text.prefix(cap - 1))
        if let boundary = prefix.lastIndex(where: { $0.isWhitespace }) {
            let clipped = String(prefix[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clipped.isEmpty { return clipped + "…" }
        }
        return prefix + "…"
    }

    static func normalizedEvidence(_ text: String) -> String {
        canonicalQuery(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func evidenceIsNearDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        nearDuplicate(
            Array(meaningfulTerms(in: lhs)).sorted(),
            Array(meaningfulTerms(in: rhs)).sorted())
    }

    // MARK: - Private helpers

    private struct RankedSnippet {
        let index: Int
        let snippet: GroundingSnippet
        let overlap: Int
        let freshness: Int
    }

    private static let boilerplateTerms: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "brainstorm", "by",
        "call", "can", "for", "from", "help", "how", "in", "is", "it",
        "meeting", "of", "on", "or", "please", "summary", "that", "the",
        "this", "to", "we", "what", "with", "you", "your"
    ]

    private static func meaningfulTerms(in text: String) -> Set<String> {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return Set(normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { canonicalTerm(String($0)) }
            .filter {
                ($0.count >= 2 || $0.allSatisfy(\.isNumber))
                    && !boilerplateTerms.contains($0)
            })
    }

    /// Connector catalogs often say "tickets" while the live room says
    /// "ticket". A tiny deterministic singularization is enough for ranking;
    /// this is deliberately not a language model or a broad stemming pass.
    private static func canonicalTerm(_ term: String) -> String {
        if boilerplateTerms.contains(term) { return term }
        if term.count > 4, term.hasSuffix("ies") {
            return String(term.dropLast(3)) + "y"
        }
        if term.count > 3, term.hasSuffix("s"),
           !term.hasSuffix("ss"), !term.hasSuffix("is"), !term.hasSuffix("us") {
            return String(term.dropLast())
        }
        return term
    }

    private static func containsConcreteIdentifier(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains { raw in
            let token = raw.trimmingCharacters(in: .punctuationCharacters)
            let hasLetter = token.contains(where: \.isLetter)
            let hasNumber = token.contains(where: \.isNumber)
            return (hasLetter && hasNumber) || token.count >= 3 && token.allSatisfy {
                !$0.isLetter || $0.isUppercase
            }
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func evidenceUnits(_ text: String) -> [String] {
        let normalizedLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var units: [String] = []
        for line in normalizedLines {
            let cleaned = line
                .replacingOccurrences(of: "^[\\-•*]+\\s*", with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let sentences = cleaned.components(
                separatedBy: try! NSRegularExpression(pattern: "(?<=[.!?])\\s+"))
            if sentences.isEmpty { units.append(cleaned) }
            else { units.append(contentsOf: sentences.filter { !$0.isEmpty }) }
        }
        return units
    }

    private static func nearDuplicate(_ lhs: [String], _ rhs: [String]) -> Bool {
        let left = Set(lhs), right = Set(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftIdentifiers = left.filter { $0.contains(where: \.isNumber) }
        let rightIdentifiers = right.filter { $0.contains(where: \.isNumber) }
        if leftIdentifiers != rightIdentifiers,
           !leftIdentifiers.isEmpty || !rightIdentifiers.isEmpty {
            return false
        }
        guard min(left.count, right.count) >= 4 else { return false }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union > 0 && Double(intersection) / Double(union) >= 0.78
    }

    private static func packFacts(_ facts: [String], cap: Int) -> String {
        guard cap > 0 else { return "" }
        var output = ""
        for fact in facts {
            let separator = output.isEmpty ? "" : "\n"
            let candidate = output + separator + fact
            if candidate.count <= cap {
                output = candidate
                continue
            }
            if output.isEmpty { output = clippedAtBoundary(fact, cap: cap) }
            break
        }
        return output
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..<endIndex, in: self)
        var pieces: [String] = []
        var cursor = startIndex
        for match in regex.matches(in: self, range: range) {
            guard let matchRange = Range(match.range, in: self) else { continue }
            pieces.append(String(self[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        pieces.append(String(self[cursor...]))
        return pieces
    }
}
