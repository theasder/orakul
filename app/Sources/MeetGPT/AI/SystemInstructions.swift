import Foundation

enum SystemInstructions {
    static let base = """
    You are an AI assistant analyzing a live recording transcript captured by Cruxwing (a native macOS app). The recording may be a meeting, tutorial, video, lecture, interview, podcast, presentation, or a user-defined type; follow the explicit recording-type context instead of assuming every transcript is a meeting.
    Cloud transcript lines may be labeled [system] (remote participants, captured via \
    ScreenCaptureKit) and [mic] (the local user). Private on-device lines are labeled [audio] \
    because their capture track is not a trustworthy speaker identity.
    Provide concise, actionable insights grounded strictly in the provided transcript and context.
    If the transcript and context do not contain the answer, say so plainly — "Not discussed in this recording" — and state what is missing. Never fill the gap from general knowledge or plausible guesses: an invented specific (a number, a name, a date) is worse than an honest gap.
    """

    /// The base instructions plus any active skill layers, in order. Callers pass
    /// the call's theme skill pack (`CallTheme.guidance`), the per-button
    /// `PromptSkill` guidance, and optionally a capped open-source skill body;
    /// empty/nil layers are dropped. This is how a single action becomes
    /// "base + domain + method + OSS depth" without layers knowing about each other.
    static func system(skills: [String?]) -> String {
        let layers = skills
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ([base] + layers).joined(separator: "\n\n")
    }

    /// When a rolling digest exists and the formatted transcript exceeds this,
    /// the prompt switches to digest + verbatim tail instead of the full text —
    /// long calls keep their early decisions without unbounded prompts (A2).
    static let digestActivationChars = 12_000
    /// How much verbatim tail rides along with the digest.
    static let digestTailChars = 8_000

    /// One line per entry: timestamp, source, diarized speaker, text — the
    /// canonical transcript rendering shared by the prompt builder and the
    /// rolling-digest folder.
    static func formatEntries(_ entries: [TranscriptEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { entry -> String in
            // Diarized (possibly user-renamed) speaker names ride along so
            // the model can reason about who said what.
            let speaker = entry.speaker.map { " \($0):" } ?? ""
            let source = entry.transcriptionEngine == .local ? "audio" : entry.source.rawValue
            return "[\(formatter.string(from: entry.timestamp))][\(source)]\(speaker) \(entry.text)"
        }.joined(separator: "\n")
    }

    /// The message, split where a cache breakpoint belongs.
    ///
    /// `stable` is what does not change between passes of one call — the
    /// recording type and the attached context. `volatile` is the transcript,
    /// which grows every few seconds, and the request. A provider that supports
    /// explicit caching marks the first and not the second; marking the second
    /// would pay a write premium for a cache nothing can ever read.
    static func buildUserMessageParts(transcript: [TranscriptEntry],
                                      additionalContext: String?,
                                      prompt: String,
                                      digest: String? = nil,
                                      recordingContext: String? = nil)
        -> (stable: String, volatile: String) {
        let transcriptBlock: String
        if transcript.isEmpty {
            transcriptBlock = "Transcript: (empty — nothing recorded yet)"
        } else {
            let formatted = formatEntries(transcript)
            let trimmedDigest = digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedDigest.isEmpty, formatted.count > digestActivationChars {
                // Long call: early content survives via the digest; the recent
                // window stays verbatim (quotes/owners must remain checkable).
                var tail = String(formatted.suffix(digestTailChars))
                if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
                transcriptBlock = "Call so far (rolling digest of earlier discussion):\n\(trimmedDigest)"
                    + "\n\nRecent transcript (verbatim):\n" + tail
            } else {
                transcriptBlock = "Transcript so far:\n" + formatted
            }
        }

        let contextBlock: String
        if let ctx = additionalContext?.trimmingCharacters(in: .whitespacesAndNewlines), !ctx.isEmpty {
            contextBlock = "\n\nAdditional context:\n" + ctx
        } else {
            contextBlock = "\n\nAdditional context: (none)"
        }

        let recordingBlock: String
        if let recordingContext = recordingContext?.trimmingCharacters(
            in: .whitespacesAndNewlines),
           !recordingContext.isEmpty {
            recordingBlock = recordingContext + "\n\n"
        } else {
            recordingBlock = ""
        }

        // ORDER IS COST, not style. A cached prefix — Anthropic's explicit
        // breakpoints, OpenAI's automatic prefix match — survives only up to the
        // first byte that differs between two calls. The transcript grows every
        // few seconds; the attached context does not change for the whole call.
        // With context AFTER the transcript, every pass invalidated it and
        // nothing above the request could ever be reused. Stable first.
        let context = contextBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let stable = recordingBlock + context + "\n\n"
        let volatilePart = transcriptBlock + "\n\nRequest:\n" + prompt
        return (stable: stable, volatile: volatilePart)
    }

    /// The message as one string — the two halves, joined.
    static func buildUserMessage(transcript: [TranscriptEntry],
                                 additionalContext: String?,
                                 prompt: String,
                                 digest: String? = nil,
                                 recordingContext: String? = nil) -> String {
        let parts = buildUserMessageParts(
            transcript: transcript, additionalContext: additionalContext,
            prompt: prompt, digest: digest, recordingContext: recordingContext)
        return parts.stable + parts.volatile
    }
}
