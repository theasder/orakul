import Foundation

/// Post-retrieve compaction for Blind Spot connector evidence.
///
/// This deliberately does not call an LLM. The result is immediately sent to
/// `/api/brainstorm`, whose managed generator already reasons over and bills for
/// that context. A preliminary `/api/llm/chat` compression used to reserve a
/// generic-chat charge and then the brainstorm route reserved again. Stable,
/// source-aware extraction preserves the connector evidence while the separate
/// grounded-cycle allowance and the one brainstorm charge remain truthful.
enum BlindSpotContextCompressor {
    static let maxOutputChars = 1_800
    static let maxBullets = 8
    static let maxInputChars = 10_000

    /// Build the compression prompt. Pure — unit-tested without an LLM.
    static func systemPrompt(goal: String, probe: String?) -> String {
        let lens = (probe?.isEmpty == false)
            ? " Active workflow probe: \(probe!)."
            : ""
        return """
        You compress connected-app search hits for a live meeting co-pilot.\(lens)
        The call goal is: "\(goal)".
        From the sources below, extract at most \(maxBullets) concrete facts that \
        help spot blind spots vs the live conversation (prior decisions, open tickets, \
        CRM state, doc claims, contradictions).
        Rules:
        - One bullet per fact; start each line with "- ".
        - Keep each bullet ≤25 words; include the source tag in brackets when present.
        - Prefer goal-relevant, recent, actionable items; drop boilerplate and duplicates.
        - Do NOT invent facts. If nothing useful, return an empty response.
        - Output ONLY the bullet list — no preamble.
        """
    }

    static func userPayload(rawContext: String, recentTranscript: String) -> String {
        let context = String(rawContext.prefix(maxInputChars))
        let transcript = String(recentTranscript.suffix(1_500))
        var parts = ["Sources:\n\(context)"]
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Recent transcript (for relevance only — do not quote as a source fact):\n\(transcript)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Parse "- bullet" lines from a model reply; falls back to non-empty lines.
    static func parseBullets(_ raw: String, limit: Int = maxBullets) -> [String] {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let bullets = lines.compactMap { line -> String? in
            var s = line
            var marked = false
            if s.hasPrefix("-") || s.hasPrefix("•") || s.hasPrefix("*") {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
                marked = true
            } else if let dot = s.firstIndex(of: "."),
                      s[..<dot].allSatisfy(\.isNumber) {
                s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                marked = true
            }
            // Only explicitly bulleted/numbered lines count here — unmarked
            // prose is LLM preamble ("Here you go:"), not a fact. Replies with
            // no markers at all are handled by the fallback below.
            guard marked, s.count >= 8 else { return nil }
            return "- \(s)"
        }
        if !bullets.isEmpty { return Array(bullets.prefix(limit)) }
        return Array(lines.prefix(limit)).map { "- \($0)" }
    }

    static func pack(_ bullets: [String], cap: Int = maxOutputChars) -> String {
        var out = ""
        for bullet in bullets {
            let next = out.isEmpty ? bullet : out + "\n" + bullet
            if next.count > cap { break }
            out = next
        }
        return out
    }

    /// Truncate-only fallback when the compress model fails or returns nothing.
    static func fallbackPack(_ rawContext: String, cap: Int = maxOutputChars) -> String {
        String(rawContext.prefix(cap))
    }

    /// Rank source blocks by literal overlap with the user's goal, active probe,
    /// and recent speech. Ties retain connector retrieval order. No word is
    /// generated or paraphrased, which makes every packed claim traceable to the
    /// connector payload supplied to this function.
    static func rankedSourceBlocks(goal: String,
                                   probe: String?,
                                   rawContext: String,
                                   recentTranscript: String) -> [String] {
        let bounded = String(rawContext.prefix(maxInputChars))
        let collapsed = bounded
            .components(separatedBy: "\n\n")
            .map {
                $0.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        var uniqueBodies: [String] = []
        let blocks = collapsed.filter { block in
            let body = block.replacingOccurrences(
                of: "^\\[workflow:[^]]+\\]\\s*", with: "",
                options: .regularExpression)
            guard !uniqueBodies.contains(where: {
                GroundingContextPolicy.evidenceIsNearDuplicate(body, $0)
            }) else { return false }
            uniqueBodies.append(body)
            return true
        }

        let query = [goal, probe ?? "", String(recentTranscript.suffix(1_500))]
            .joined(separator: " ")
            .lowercased()
        let terms = Set(query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })

        return blocks.enumerated()
            .map { index, block in
                let haystack = block.lowercased()
                let score = terms.reduce(into: 0) { total, term in
                    if haystack.contains(term) { total += 1 }
                }
                let fresh = haystack.contains("cached ") ? 0 : 1
                return (index: index, score: score, fresh: fresh, block: block)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.fresh != $1.fresh { return $0.fresh > $1.fresh }
                return $0.index < $1.index
            }
            .prefix(maxBullets)
            .map { $0.block }
    }

    /// Give every selected connector a fair slice of the fixed output budget,
    /// instead of letting one long first response truncate every later source.
    static func sourceAwarePack(goal: String,
                                probe: String?,
                                rawContext: String,
                                recentTranscript: String,
                                cap: Int = maxOutputChars) -> String {
        guard cap > 0 else { return "" }
        let blocks = rankedSourceBlocks(
            goal: goal,
            probe: probe,
            rawContext: rawContext,
            recentTranscript: recentTranscript)
        guard !blocks.isEmpty else { return "" }

        var output = ""
        var remaining = cap
        for (offset, block) in blocks.enumerated() {
            let separator = output.isEmpty ? "" : "\n"
            let slots = blocks.count - offset
            let available = max(0, remaining - separator.count)
            let fairShare = slots > 0 ? available / slots : available
            guard fairShare > 0 else { break }
            let rendered = "- \(block)"
            let piece = GroundingContextPolicy.clippedAtBoundary(
                rendered, cap: fairShare)
            guard !piece.isEmpty else { continue }
            output += separator + piece
            remaining = max(0, cap - output.count)
        }
        return output
    }

    /// Compact retrieved connector context without a provider request. `llm` and
    /// `model` remain in the signature to avoid a broad AppState migration; they
    /// are intentionally unused and a regression test asserts they are never
    /// invoked.
    static func compress(goal: String,
                         probe: String?,
                         rawContext: String,
                         recentTranscript: String,
                         llm _: LLMGateway,
                         model _: LLMModel) async -> String? {
        let trimmed = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sourceAwarePack(
            goal: goal,
            probe: probe,
            rawContext: trimmed,
            recentTranscript: recentTranscript)
    }
}
