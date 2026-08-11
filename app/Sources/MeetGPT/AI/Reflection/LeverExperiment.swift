import Foundation

/// Does a token saving cost anything?
///
/// Cheaper is trivially achievable — send less and the bill falls. The only
/// question worth asking is what the cheaper prompt stopped being able to
/// answer, and the honest form of that answer is a ratio: input saved against
/// quality events broken.
///
/// Two levers are worth replaying. The rest of the caching work sends the model
/// byte-identical input and cannot lose anything, so measuring it would be
/// theatre:
///
///   * `promptOrder` moves the attached context above the transcript. Identical
///     tokens in a different order, which is not nothing — an instruction late
///     in a prompt lands differently from the same instruction early in it.
///   * `transcriptDigest` replaces the early transcript with a summary past
///     `digestActivationChars`. Real compression: the facts it drops are gone,
///     and no cache brings them back.
///
/// Scoring uses the deterministic critics, so a comparison costs no judge and
/// carries no opinion. Silence is counted separately from rule-breaking,
/// because a refusal quotes nothing and therefore violates nothing — counting
/// only violations would score "said nothing" as flawless.
enum LeverExperiment {
    enum Lever {
        case promptOrder
        case transcriptDigest
    }

    /// One replayable moment: what the live path would have sent.
    struct Window: Equatable, Sendable {
        let sessionTitle: String
        let transcript: [TranscriptEntry]
        let attachedContext: String
        let prompt: String
        let recordingContext: String
        /// The rolling summary of earlier discussion, when one exists.
        let digest: String

        init(sessionTitle: String, transcript: [TranscriptEntry],
             attachedContext: String, prompt: String,
             recordingContext: String, digest: String = "") {
            self.sessionTitle = sessionTitle
            self.transcript = transcript
            self.attachedContext = attachedContext
            self.prompt = prompt
            self.recordingContext = recordingContext
            self.digest = digest
        }
    }

    /// Rebuilds the moments a recorded session actually asked about.
    static func windows(for session: SavedSession) -> [Window] {
        (session.aiHistory ?? []).map { exchange in
            Window(sessionTitle: session.displayTitle,
                   transcript: session.entries,
                   attachedContext: session.contextNotes ?? "",
                   prompt: exchange.prompt,
                   recordingContext: "",
                   digest: session.digest)
        }
    }

    /// The message the window produces with the lever on or off.
    static func message(_ window: Window, lever: Lever, applied: Bool) -> String {
        let digest = window.digest.isEmpty ? nil : window.digest
        switch lever {
        case .transcriptDigest:
            // Off means the full transcript — which is exactly what the digest
            // exists to avoid sending.
            let parts = SystemInstructions.buildUserMessageParts(
                transcript: window.transcript,
                additionalContext: window.attachedContext,
                prompt: window.prompt,
                digest: applied ? digest : nil,
                recordingContext: window.recordingContext)
            return parts.stable + parts.volatile

        case .promptOrder:
            let parts = SystemInstructions.buildUserMessageParts(
                transcript: window.transcript,
                additionalContext: window.attachedContext,
                prompt: window.prompt,
                digest: digest,
                recordingContext: window.recordingContext)
            guard !applied else { return parts.stable + parts.volatile }
            return legacyOrdered(parts, window: window)
        }
    }

    /// What a cache could reuse under this layout.
    static func cacheablePrefix(_ window: Window,
                                lever: Lever = .promptOrder,
                                applied: Bool = true) -> String {
        guard applied else { return "" }
        return SystemInstructions.buildUserMessageParts(
            transcript: window.transcript,
            additionalContext: window.attachedContext,
            prompt: window.prompt,
            digest: window.digest.isEmpty ? nil : window.digest,
            recordingContext: window.recordingContext).stable
    }

    static func estimatedTokens(_ message: String) -> Int {
        TokenEstimate.tokens(message.count)
    }

    // MARK: - Scoring

    struct Observation: Sendable {
        let window: String
        /// Whether the lever was on for this run.
        let applied: Bool
        let answer: String
        let transcript: String
        let inputTokens: Int
    }

    struct Score: Equatable, Sendable {
        var pairedWindows = 0
        var ungroundedWithout = 0
        var ungroundedWithLever = 0
        var silentWithout = 0
        var silentWithLever = 0
        var tokensWithout = 0
        var tokensWithLever = 0

        /// Share of input the lever removed, 0…1.
        var tokensSavedShare: Double {
            guard tokensWithout > 0 else { return 0 }
            return max(0, Double(tokensWithout - tokensWithLever) / Double(tokensWithout))
        }

        /// Any quality event the lever made worse. Deliberately not a net score:
        /// one new ungrounded answer is not cancelled by one fewer silence
        /// somewhere else.
        var regressed: Bool {
            ungroundedWithLever > ungroundedWithout || silentWithLever > silentWithout
        }
    }

    /// Fewer paired windows than this cannot separate an effect from noise.
    static let minimumWindowsForVerdict = 10

    static func score(_ observations: [Observation]) -> Score {
        var score = Score()
        let byWindow = Dictionary(grouping: observations, by: \.window)

        for (_, runs) in byWindow {
            guard let without = runs.first(where: { !$0.applied }),
                  let with = runs.first(where: { $0.applied }) else { continue }
            score.pairedWindows += 1
            score.tokensWithout += without.inputTokens
            score.tokensWithLever += with.inputTokens

            for run in [without, with] {
                let silent = run.answer
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let ungrounded = !ReflectionCritics
                    .judgeAnswer(run.answer, transcript: run.transcript)
                    .findings.isEmpty

                if run.applied {
                    if silent { score.silentWithLever += 1 }
                    if ungrounded { score.ungroundedWithLever += 1 }
                } else {
                    if silent { score.silentWithout += 1 }
                    if ungrounded { score.ungroundedWithout += 1 }
                }
            }
        }
        return score
    }

    static func render(_ score: Score) -> String {
        let saved = Int((score.tokensSavedShare * 100).rounded())
        return """
        lever: \(score.pairedWindows) paired windows · input −\(saved)%
        ungrounded  off \(score.ungroundedWithout) → on \(score.ungroundedWithLever)
        silent      off \(score.silentWithout) → on \(score.silentWithLever)
        """
    }

    /// The saving and its price in one line, or a refusal to conclude.
    static func verdict(_ score: Score) -> String {
        guard score.pairedWindows >= minimumWindowsForVerdict else {
            return "too few paired windows (\(score.pairedWindows) of "
                + "\(minimumWindowsForVerdict)) — no verdict"
        }
        let saved = Int((score.tokensSavedShare * 100).rounded())
        guard !score.regressed else {
            return "saves \(saved)% of input and BREAKS answers "
                + "(ungrounded \(score.ungroundedWithout)→\(score.ungroundedWithLever), "
                + "silent \(score.silentWithout)→\(score.silentWithLever)) — not worth it"
        }
        return saved > 0
            ? "saves \(saved)% of input with no measurable quality loss"
            : "no measurable saving and no measurable loss"
    }

    // MARK: - Internals

    /// The pre-reorder layout: context BELOW the transcript, where a growing
    /// transcript invalidated it on every pass.
    ///
    /// Assembled from the same four pieces with the same two separators, so the
    /// two layouts differ by ORDER and nothing else. If they differed by even a
    /// newline this would stop being a reorder experiment and any quality
    /// difference would be uninterpretable.
    private static func legacyOrdered(_ parts: (stable: String, volatile: String),
                                      window: Window) -> String {
        let separator = "\n\n"
        let requestMarker = separator + "Request:\n"

        let recordingLine = window.recordingContext.isEmpty
            ? "" : window.recordingContext + separator
        // stable == recordingLine + context + separator
        let context = String(parts.stable
            .dropFirst(recordingLine.count)
            .dropLast(separator.count))
        // volatile == transcriptBlock + requestMarker + prompt
        guard let split = parts.volatile.range(of: requestMarker) else {
            return parts.stable + parts.volatile
        }
        let transcriptBlock = String(parts.volatile[..<split.lowerBound])
        let prompt = String(parts.volatile[split.upperBound...])

        return recordingLine + transcriptBlock + separator
            + context + requestMarker + prompt
    }
}
