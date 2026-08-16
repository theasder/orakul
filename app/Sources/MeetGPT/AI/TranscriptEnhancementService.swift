import Foundation

/// Reconciles on-device Whisper captions with a Fireflies cloud transcript
/// (via MCP) into one cleaned, speaker-labeled meeting record.
///
/// Whisper is strong on timing and local wording but chunky and speaker-blind.
/// Fireflies is strong on speakers and full sentences but can lag or mis-hear.
/// Connected-app grounding (Notion, CRM, trackers, …) supplies canonical names,
/// spellings, and project terms. The LLM merges all of that — never inventing
/// decisions that no source supports.
enum TranscriptEnhancementService {
    private static let maxWhisperChars = 14_000
    private static let maxFirefliesChars = 18_000
    private static let maxGroundingChars = 8_000

    struct Result: Equatable {
        let entries: [TranscriptEntry]
        let summary: String
        let firefliesTitle: String
        /// `entries` covers only a bounded part of the meeting: either output
        /// was truncated or one of the inputs was clipped. It must never
        /// replace the full live transcript because content outside that
        /// window would be deleted.
        let isPartial: Bool

        init(entries: [TranscriptEntry], summary: String,
             firefliesTitle: String, isPartial: Bool = false) {
            self.entries = entries
            self.summary = summary
            self.firefliesTitle = firefliesTitle
            self.isPartial = isPartial
        }
    }

    /// Build an enhanced transcript from Whisper + Fireflies + connector context.
    static func enhance(whisper: [TranscriptEntry],
                        fireflies: FirefliesTranscript,
                        sessionStart: Date,
                        goal: String = "",
                        digest: String = "",
                        grounding: [GroundingSnippet] = [],
                        llm: LLMGateway = LLMGatewayFactory.make(),
                        model: LLMModel = LLMCatalog.background(for: Config.selectedModel)
    ) async throws -> Result {
        let whisperText = SystemInstructions.formatEntries(whisper)
        let inputWasClipped = whisperText.count > maxWhisperChars
            || fireflies.text.count > maxFirefliesChars
        // Keep the recent end of both sources. The old code paired the Whisper
        // tail with the Fireflies head, asking the model to reconcile opposite
        // ends of a long meeting. Any clipping also makes replacement unsafe,
        // even when the model returns syntactically complete JSON.
        let clippedWhisper = wholeLineSuffix(
            whisperText, maxCharacters: maxWhisperChars)
        let clippedFireflies = wholeLineSuffix(
            fireflies.text, maxCharacters: maxFirefliesChars)

        guard !clippedFireflies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptEnhancementError.emptyFireflies
        }

        let system = """
        You reconcile transcripts of the SAME meeting into one clean record.

        SOURCE A — Whisper (on-device): short timed chunks, often missing speaker \
        names, may drop/garble words, good wall-clock timing.
        SOURCE B — Fireflies (cloud): speaker-diarized sentences, fuller wording, \
        may lag the live call or mis-hear names/numbers.
        SOURCE C — Connected apps (Notion, CRM, trackers, docs, …): canonical \
        spellings for people, companies, products, ticket IDs, and project terms. \
        Use this to correct ASR garbles when a connector clearly names the entity. \
        Do NOT pull new decisions or commitments from connectors that were not said \
        in A or B.

        Rules:
        1. Prefer Fireflies for speaker identity and fluent sentence boundaries.
        2. Prefer Whisper timing (offsetSec from session start) when both cover \
           the same moment; otherwise estimate offsets from Fireflies order.
        3. When wording conflicts, prefer the reading that matches A+B, else the \
           connector-backed spelling for proper nouns, else ordinary meeting \
           common sense (fix obvious ASR gibberish).
        4. NEVER invent decisions, commitments, or facts absent from A and B.
        5. Mark source as "mic" only for the local user when clear; otherwise "system".
        6. Keep entries chronological. Drop pure silence / filler-only lines.

        Return ONLY minified JSON (no prose, no fences):
        {"summary":"<=25 words on what changed",\
        "entries":[{"offsetSec":0.0,"speaker":"Name or null","source":"system|mic","text":"utterance"}]}
        """

        var userParts: [String] = []
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty { userParts.append("Meeting goal: \(trimmedGoal)") }
        let trimmedDigest = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDigest.isEmpty {
            userParts.append("Rolling digest (earlier part of a long call):\n\(String(trimmedDigest.prefix(4_000)))")
        }
        if let grounded = renderGrounding(grounding), !grounded.isEmpty {
            userParts.append("SOURCE C — Connected apps:\n\(grounded)")
        } else {
            userParts.append("SOURCE C — Connected apps: (none connected or no hits)")
        }
        userParts.append("SOURCE A — Whisper:\n\(clippedWhisper.isEmpty ? "(empty — use Fireflies only)" : clippedWhisper)")
        userParts.append("SOURCE B — Fireflies (\(fireflies.title)):\n\(clippedFireflies)")
        let user = userParts.joined(separator: "\n\n")

        // This is the longest output the app ever requests — a whole
        // reconciled transcript — so it needs a budget far above the 1200-token
        // default that every other call uses. Under that default the JSON was
        // cut off mid-object and the feature could not succeed at all.
        let text = try await llm.streamChat(
            system: system, user: user, model: model,
            maxOutputTokens: OutputTokenBudget.maximum) { _ in }

        let parsed = TranscriptMergeParser.parse(text)
        let summaryText = parsed.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !parsed.items.isEmpty else {
            // The summary often survives when the entries do not — it is
            // written first. Hand it back instead of failing outright, so the
            // user gets what the model actually produced.
            if !summaryText.isEmpty {
                throw TranscriptEnhancementError.summaryOnly(summaryText)
            }
            throw TranscriptEnhancementError.unparseable(String(text.prefix(240)))
        }

        let entries = parsed.items.compactMap { item -> TranscriptEntry? in
            guard let raw = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            let source: TranscriptSource = (item.source?.lowercased() == "mic") ? .mic : .system
            let speaker = item.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let offset = max(0, item.offsetSec ?? 0)
            return TranscriptEntry(
                source: source,
                text: raw,
                timestamp: sessionStart.addingTimeInterval(offset),
                speaker: (speaker?.isEmpty ?? true) ? nil : speaker
            )
        }
        guard !entries.isEmpty else {
            if !summaryText.isEmpty { throw TranscriptEnhancementError.summaryOnly(summaryText) }
            throw TranscriptEnhancementError.unparseable("empty entries after decode")
        }

        return Result(
            entries: entries.sorted { $0.timestamp < $1.timestamp },
            summary: summaryText.isEmpty ? "Enhanced with Fireflies" : summaryText,
            firefliesTitle: fireflies.title,
            isPartial: parsed.isTruncated || inputWasClipped
        )
    }

    static func wholeLineSuffix(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else { return text }
        let suffix = String(text.suffix(maxCharacters))
        guard let newline = suffix.firstIndex(of: "\n") else { return suffix }
        return String(suffix[suffix.index(after: newline)...])
    }

    /// Compact connector background for the enhance prompt (budgeted).
    static func renderGrounding(_ snippets: [GroundingSnippet]) -> String? {
        let snippets = GroundingContextPolicy.optimizedSnippets(
            snippets,
            tier: Config.currentTier,
            characterLimit: maxGroundingChars,
            sourceLimit: 6)
        guard !snippets.isEmpty else { return nil }
        var budget = maxGroundingChars
        var lines: [String] = []
        for snippet in snippets where budget > 0 {
            let chunk = String(snippet.text.prefix(budget))
            budget -= chunk.count
            lines.append("[\(snippet.serverName)/\(snippet.toolName)] \(chunk)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

enum TranscriptEnhancementError: LocalizedError, Equatable {
    case emptyFireflies
    case emptyWhisper
    case unparseable(String)
    /// The model produced a usable summary but no usable entries. Reported as
    /// its own case so the caller can SHOW the summary rather than raise an
    /// error containing a wall of broken JSON.
    case summaryOnly(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .emptyFireflies:
            return "Fireflies returned an empty transcript."
        case .emptyWhisper:
            return "There's no on-device transcript to enhance yet."
        case .unparseable(let detail):
            return "Couldn't merge the transcripts (\(detail))."
        case .summaryOnly(let summary):
            return summary
        case .busy:
            return "Transcript enhancement is already running."
        }
    }
}
