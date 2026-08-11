import Foundation

/// A reviewable vocabulary candidate found in connected work-app context.
/// Nothing in this type writes `Config.transcriptionGlossary`; AppState does
/// that only after the user presses Add beside one suggestion.
struct ConnectedGlossarySuggestion: Identifiable, Equatable, Sendable {
    let term: String
    let reason: String
    let sources: [String]

    /// Stable across a refresh so SwiftUI does not animate the same spelling as
    /// a different row merely because the model changed its explanation.
    var id: String { ConnectedGlossarySuggestionService.canonicalKey(term) }
}

struct ConnectedGlossarySuggestionMetrics: Equatable, Sendable {
    enum Ranking: String, Equatable, Sendable {
        case fastModel
        case localFallback
        case localOnly
    }

    let sourceCount: Int
    let groundingChars: Int
    let promptChars: Int
    let estimatedInputTokens: Int
    let transcriptCharsSent: Int
    let modelID: String
    let estimatedComputeCredits: Int
    let ranking: Ranking
    let cached: Bool
}

enum ConnectedGlossarySuggestionError: LocalizedError, Equatable {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Connected-app lookup timed out. Try again when the app is reachable."
        }
    }
}

/// Turns small, cached read-only connector excerpts into transcription terms.
///
/// Privacy and cost boundaries are deliberately constants rather than caller
/// conventions: at most three sources and 4,800 source characters reach one
/// fast-model request, the live transcript is not an input, and the response is
/// capped at 384 tokens. A failed model pass falls back to local extraction so
/// a provider outage cannot discard connector work the user already paid for.
enum ConnectedGlossarySuggestionService {
    static let maxSources = 3
    static let maxCharsPerSource = 1_600
    static let maxGroundingChars = maxSources * maxCharsPerSource
    static let maxCandidates = 72
    static let maxSuggestions = 24
    static let maxPromptChars = 6_000
    static let maxOutputTokens = 384
    static let sourceDeadline: TimeInterval = 12
    static let modelDeadline: TimeInterval = 20

    struct PreparedRequest: Equatable, Sendable {
        let system: String
        let user: String
        let candidates: [ConnectedGlossarySuggestion]
        let sourceCount: Int
        let groundingChars: Int

        var promptChars: Int { system.count + user.count }
        var estimatedInputTokens: Int { TokenEstimate.tokens(promptChars) }
    }

    struct Generation: Equatable, Sendable {
        let suggestions: [ConnectedGlossarySuggestion]
        let metrics: ConnectedGlossarySuggestionMetrics
        /// Non-nil when the local candidate ranker replaced an unavailable,
        /// timed-out, or malformed fast-model response.
        let fallbackMessage: String?
    }

    typealias Ranker = @Sendable (
        _ system: String, _ user: String, _ maxOutputTokens: Int
    ) async throws -> String

    private struct ModelSuggestion: Decodable {
        let term: String
        let reason: String?
        let source: String?
        let sources: [String]?
    }

    private struct ModelEnvelope: Decodable {
        let suggestions: [ModelSuggestion]
    }

    private struct CandidateAccumulator {
        var spelling: String
        var sources: Set<String>
        var occurrences: Int
        var score: Int
    }

    static let systemPrompt = """
    You clean and rank a transcription glossary using ONLY bounded excerpts from connected work apps.

    Return JSON only: {"suggestions":[{"term":"exact spelling","reason":"why ASR may need it","sources":["app"]}]}
    Keep at most 24 proper names, product/project names, acronyms, APIs, protocols, and technical terms. Never add a term that does not appear in the excerpts. Exclude generic prose, secrets, credentials, URLs, email addresses, and sentences. Preserve the source spelling and capitalization.
    """

    /// Build the only model input this feature can emit. There is intentionally
    /// no transcript parameter. Callers cannot accidentally attach a call.
    static func prepare(snippets: [GroundingSnippet], existingGlossary: String,
                        rejectedKeys: Set<String> = []) -> PreparedRequest? {
        let bounded = boundedSources(snippets)
        guard !bounded.isEmpty else { return nil }
        let existing = Set(Glossary.terms(from: existingGlossary).map(canonicalKey))
        let candidates = extractCandidates(
            from: bounded,
            excluding: existing.union(rejectedKeys))
        guard !candidates.isEmpty else { return nil }

        let sourceBlock = bounded.map { source in
            "### \(source.name)\n\(source.text)"
        }.joined(separator: "\n\n")
        let candidateBlock = candidates.map(\.term).joined(separator: " | ")
        let user = String("""
        Connected-app excerpts (not a call transcript):
        \(sourceBlock)

        Locally extracted candidates to verify and rank:
        \(candidateBlock)
        """.prefix(max(0, maxPromptChars - systemPrompt.count)))
        return PreparedRequest(
            system: systemPrompt,
            user: user,
            candidates: candidates,
            sourceCount: bounded.count,
            groundingChars: bounded.reduce(0) { $0 + $1.text.count })
    }

    static func generate(snippets: [GroundingSnippet],
                         existingGlossary: String,
                         rejectedKeys: Set<String> = [],
                         model: LLMModel,
                         useFastModel: Bool = true,
                         ranker: Ranker? = nil,
                         onPrepared: (@Sendable (PreparedRequest) -> Void)? = nil,
                         modelDeadline: TimeInterval = ConnectedGlossarySuggestionService.modelDeadline) async -> Generation? {
        guard let request = prepare(
            snippets: snippets,
            existingGlossary: existingGlossary,
            rejectedKeys: rejectedKeys) else { return nil }
        onPrepared?(request)

        let estimatedCredits = CreditCostEstimate.credits(
            model: model.id, inputTokens: request.estimatedInputTokens)
        guard useFastModel, let ranker else {
            return Generation(
                suggestions: Array(request.candidates.prefix(maxSuggestions)),
                metrics: metrics(
                    request: request, model: model,
                    credits: estimatedCredits, ranking: .localOnly),
                fallbackMessage: nil)
        }

        do {
            let raw = try await withDeadline(seconds: modelDeadline) {
                try await ranker(request.system, request.user, maxOutputTokens)
            }
            let parsed = parseModelSuggestions(
                raw,
                snippets: snippets,
                candidates: request.candidates,
                existingGlossary: existingGlossary,
                rejectedKeys: rejectedKeys)
            guard !parsed.isEmpty else {
                return Generation(
                    suggestions: Array(request.candidates.prefix(maxSuggestions)),
                    metrics: metrics(
                        request: request, model: model,
                        credits: estimatedCredits, ranking: .localFallback),
                    fallbackMessage: "Fast AI cleanup returned no supported terms; showing locally extracted suggestions.")
            }
            return Generation(
                suggestions: parsed,
                metrics: metrics(
                    request: request, model: model,
                    credits: estimatedCredits, ranking: .fastModel),
                fallbackMessage: nil)
        } catch ConnectedGlossarySuggestionError.timeout {
            return Generation(
                suggestions: Array(request.candidates.prefix(maxSuggestions)),
                metrics: metrics(
                    request: request, model: model,
                    credits: estimatedCredits, ranking: .localFallback),
                fallbackMessage: "Fast AI cleanup timed out; showing locally extracted suggestions.")
        } catch is CancellationError {
            if Task.isCancelled { return nil }
            return Generation(
                suggestions: Array(request.candidates.prefix(maxSuggestions)),
                metrics: metrics(
                    request: request, model: model,
                    credits: estimatedCredits, ranking: .localFallback),
                fallbackMessage: "Fast AI cleanup timed out; showing locally extracted suggestions.")
        } catch {
            return Generation(
                suggestions: Array(request.candidates.prefix(maxSuggestions)),
                metrics: metrics(
                    request: request, model: model,
                    credits: estimatedCredits, ranking: .localFallback),
                fallbackMessage: "Fast AI cleanup was unavailable; showing locally extracted suggestions.")
        }
    }

    static func parseModelSuggestions(_ raw: String,
                                      snippets: [GroundingSnippet],
                                      candidates: [ConnectedGlossarySuggestion],
                                      existingGlossary: String,
                                      rejectedKeys: Set<String> = [])
        -> [ConnectedGlossarySuggestion] {
        guard let json = extractJSONObjectOrArray(raw),
              let data = json.data(using: .utf8) else { return [] }
        let decoded: [ModelSuggestion]
        if json.first == "[" {
            decoded = (try? JSONDecoder().decode([ModelSuggestion].self, from: data)) ?? []
        } else {
            decoded = (try? JSONDecoder().decode(ModelEnvelope.self, from: data).suggestions) ?? []
        }

        let bounded = boundedSources(snippets)
        let existing = Set(Glossary.terms(from: existingGlossary).map(canonicalKey))
            .union(rejectedKeys)
        let candidateByKey = Dictionary(
            candidates.map { (canonicalKey($0.term), $0) },
            uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var output: [ConnectedGlossarySuggestion] = []

        for item in decoded {
            let term = sanitizedTerm(item.term)
            let key = canonicalKey(term)
            guard !term.isEmpty, !existing.contains(key), seen.insert(key).inserted,
                  isSupported(term: term, by: bounded, candidates: candidateByKey) else { continue }
            let inferredSources = bounded.compactMap { source in
                containsSupported(term: term, in: source.text) ? source.name : nil
            }
            let requestedSources = (item.sources ?? item.source.map { [$0] } ?? [])
                .filter { requested in bounded.contains { $0.name == requested } }
            let sources = requestedSources.isEmpty ? inferredSources : requestedSources
            let fallback = candidateByKey[key]?.reason ?? "Canonical spelling found in connected apps"
            let reason = sanitizedReason(item.reason ?? fallback)
            output.append(ConnectedGlossarySuggestion(
                term: term,
                reason: reason.isEmpty ? fallback : reason,
                sources: Array(Set(sources)).sorted()))
            if output.count >= maxSuggestions { break }
        }
        return output
    }

    /// Local extraction is both the pre-model allow-list and the outage path.
    /// It favours tokens ASR commonly damages: acronyms, mixed-case names,
    /// digits/separators, and multi-word proper nouns.
    /// `minimumOccurrences` raises the bar for sources that are themselves ASR
    /// output. A written document can say a term once and mean it; a machine
    /// transcript saying something once may simply have misheard it, and a
    /// corruption promoted into the glossary teaches the next recording to
    /// repeat it. Repetition is the cheapest available evidence that a term is
    /// real rather than a one-off error.
    static func extractCandidates(
        from snippets: [(name: String, text: String)],
        excluding excluded: Set<String> = [],
        minimumOccurrences: Int = 1
    ) -> [ConnectedGlossarySuggestion] {
        let patterns: [(String, Int)] = [
            // Acronyms and version/SLO-shaped tokens: ARR, RAG, SLO-99.95.
            (#"(?<![\p{L}\p{N}])(?:[\p{Lu}]{2,}[\p{Lu}\p{N}]*(?:[-./][\p{Lu}\p{N}]+)*(?:\.\d+)?)(?![\p{L}\p{N}])"#, 7),
            // Camel/mixed-case and connector-shaped identifiers: OpenTelemetry,
            // GPT-5.4, pg_vector, Q3-Falcon.
            (#"(?<![\p{L}\p{N}])(?:[\p{L}]*[\p{Lu}][\p{Ll}]+[\p{Lu}][\p{L}\p{N}-]*|[\p{L}\p{N}]+[-_./][\p{L}\p{N}._/-]+)(?![\p{L}\p{N}])"#, 6),
            // Two-to-four-word proper names: Project Falcon, Ada Lovelace.
            (#"(?<![\p{L}\p{N}])(?:[\p{Lu}][\p{Ll}\p{M}]{2,})(?:\s+[\p{Lu}][\p{L}\p{M}\p{N}-]{1,}){1,3}(?![\p{L}\p{N}])"#, 5),
            // Single capitalized technical/product names. A stop-list removes
            // sentence scaffolding; the model can then rank the remaining set.
            (#"(?<![\p{L}\p{N}])[\p{Lu}][\p{Ll}\p{M}]{3,}(?![\p{L}\p{N}])"#, 2),
        ]
        var accumulated: [String: CandidateAccumulator] = [:]
        for source in snippets {
            for (pattern, baseScore) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let ns = source.text as NSString
                let range = NSRange(location: 0, length: ns.length)
                for match in regex.matches(in: source.text, range: range) {
                    let raw = ns.substring(with: match.range)
                    let term = sanitizedTerm(raw)
                    let key = canonicalKey(term)
                    guard isPlausible(term), !excluded.contains(key) else { continue }
                    let bonus = technicalBonus(term)
                    if var current = accumulated[key] {
                        current.sources.insert(source.name)
                        current.occurrences += 1
                        current.score = max(current.score, baseScore + bonus)
                        accumulated[key] = current
                    } else {
                        accumulated[key] = CandidateAccumulator(
                            spelling: term,
                            sources: [source.name],
                            occurrences: 1,
                            score: baseScore + bonus)
                    }
                }
            }
        }
        return accumulated.values
            .filter { $0.occurrences >= minimumOccurrences }
            .sorted {
                let lhs = $0.score + min(3, $0.occurrences - 1)
                let rhs = $1.score + min(3, $1.occurrences - 1)
                if lhs != rhs { return lhs > rhs }
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                return $0.spelling.localizedCaseInsensitiveCompare($1.spelling) == .orderedAscending
            }
            .prefix(maxCandidates)
            .map { item in
                let reason: String
                if item.spelling.contains(where: \.isNumber) {
                    reason = "Technical term with digits or a version"
                } else if item.spelling.contains(" ") {
                    reason = "Multi-word name whose spelling may be split by ASR"
                } else if item.spelling.uppercased() == item.spelling {
                    reason = "Acronym whose capitalization may be lost"
                } else {
                    reason = "Canonical name found in connected apps"
                }
                return ConnectedGlossarySuggestion(
                    term: item.spelling, reason: reason,
                    sources: item.sources.sorted())
            }
    }

    static func boundedSources(_ snippets: [GroundingSnippet]) -> [(name: String, text: String)] {
        var seen = Set<String>()
        var remaining = maxGroundingChars
        var output: [(String, String)] = []
        for snippet in snippets where output.count < maxSources && remaining > 0 {
            let name = String(promptSafeSourceText(snippet.serverName)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            let cap = min(maxCharsPerSource, remaining)
            // Connector payloads can contain message bodies but also echoed
            // request metadata. Strip credentials, identities, and links BEFORE
            // clipping so a secret beyond the cap cannot be cut into a shape
            // that evades the redactor.
            let safe = promptSafeSourceText(snippet.text)
            let text = String(safe.prefix(cap))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output.append((name, text))
            remaining -= text.count
        }
        return output
    }

    /// Prompt-specific privacy pass. Diagnostic redaction already covers known
    /// credential families; connected-app vocabulary discovery additionally
    /// has no need for email addresses or URLs, so those are removed too.
    static func promptSafeSourceText(_ raw: String) -> String {
        var value = DevCallDiagnostics.sanitizeString(
            raw, maximumBytes: max(16_384, raw.utf8.count))
        let patterns: [(String, String)] = [
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[REDACTED EMAIL]"),
            (#"(?i)\bhttps?://[^\s<>\]\[\)\(\"']+"#, "[REDACTED URL]"),
            // Opaque high-entropy values not bearing a familiar prefix. Keep
            // normal hyphenated product names; require a long uninterrupted
            // token with both letters and digits.
            (#"\b(?=[A-Za-z0-9_-]{40,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#, "[REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(
                in: value, range: range, withTemplate: replacement)
        }
        return value
    }

    /// Shared bounded deadline for connected-app reads. The live MCP layer has
    /// per-source deadlines; this outer deadline also covers a wedged injected
    /// provider and the aggregate Google/MCP fan-out.
    static func loadSources(
        deadline: TimeInterval = sourceDeadline,
        provider: @escaping @Sendable () async throws -> [GroundingSnippet]
    ) async throws -> [GroundingSnippet] {
        try await withDeadline(seconds: deadline, operation: provider)
    }

    static func canonicalKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func metrics(request: PreparedRequest,
                                model: LLMModel,
                                credits: Int,
                                ranking: ConnectedGlossarySuggestionMetrics.Ranking)
        -> ConnectedGlossarySuggestionMetrics {
        ConnectedGlossarySuggestionMetrics(
            sourceCount: request.sourceCount,
            groundingChars: request.groundingChars,
            promptChars: request.promptChars,
            estimatedInputTokens: request.estimatedInputTokens,
            transcriptCharsSent: 0,
            modelID: model.id,
            estimatedComputeCredits: credits,
            ranking: ranking,
            cached: false)
    }

    private static func extractJSONObjectOrArray(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("{", "}"), ("[", "]")] {
            guard let start = trimmed.firstIndex(of: Character(open)),
                  let end = trimmed.lastIndex(of: Character(close)), start <= end else { continue }
            let candidate = String(trimmed[start...end])
            if JSONSerialization.isValidJSONObject(
                (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as Any) {
                return candidate
            }
        }
        return nil
    }

    private static func sanitizedTerm(_ raw: String) -> String {
        let compact = raw.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"'`•,;:()[]{}")))
        guard compact.count <= Glossary.maxCharsPerTerm,
              !compact.contains("@"), !compact.contains("://"),
              !compact.contains("\n"), !compact.contains("\r") else { return "" }
        return compact
    }

    private static func sanitizedReason(_ raw: String) -> String {
        String(raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private static func isSupported(
        term: String,
        by sources: [(name: String, text: String)],
        candidates: [String: ConnectedGlossarySuggestion]
    ) -> Bool {
        candidates[canonicalKey(term)] != nil
            || sources.contains { containsSupported(term: term, in: $0.text) }
    }

    private static func containsSupported(term: String, in text: String) -> Bool {
        let foldedTerm = canonicalKey(term)
        let foldedText = canonicalKey(text)
        guard !foldedTerm.isEmpty else { return false }
        return foldedText.contains(foldedTerm)
    }

    private static func technicalBonus(_ term: String) -> Int {
        var score = 0
        if term.contains(where: \.isNumber) { score += 2 }
        if term.contains(where: { "-_./+#".contains($0) }) { score += 2 }
        if term.uppercased() == term { score += 2 }
        if term.contains(" ") { score += 1 }
        return score
    }

    private static func isPlausible(_ term: String) -> Bool {
        guard (2...Glossary.maxCharsPerTerm).contains(term.count),
              term.rangeOfCharacter(from: .letters) != nil else { return false }
        let key = canonicalKey(term)
        guard !genericWords.contains(key), !term.contains("@"), !term.contains("://") else {
            return false
        }
        // Whole sentences and JSON field names are context, not vocabulary.
        return term.split(separator: " ").count <= 4
    }

    private static let genericWords: Set<String> = [
        "about", "after", "also", "before", "connected", "context", "customer",
        "data", "document", "during", "find", "from", "issue", "meeting", "name",
        "notes", "project", "product", "result", "search", "source", "status", "team",
        "technical", "term", "that", "their", "there", "these", "this", "title",
        "user", "using", "what", "when", "where", "which", "with", "would",
        "redacted", "redacted email", "redacted url", "email", "url", "authorization",
        "bearer", "api key", "client secret", "private key",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    private static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(0.001, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ConnectedGlossarySuggestionError.timeout
            }
            guard let first = try await group.next() else {
                throw ConnectedGlossarySuggestionError.timeout
            }
            group.cancelAll()
            return first
        }
    }
}
