import Foundation

/// The candidate: rhetoric and facilitation in ONE call.
///
/// Both watches read the same 6,000-character tail on the same fast model and
/// return one short sentence or nothing, so asking for both in a single reply
/// is the same work over the same input read once. What it buys is NOT credits
/// — `BackgroundSpendPolicy` already rotates the three 300 s watches so only
/// one fires per period, and merging two of three slots leaves the tick count
/// unchanged. It buys COVERAGE: each of the merged pair is then seen every
/// other period instead of every third, so their effective cadence goes from
/// 15 minutes to 10 at the same cost.
///
/// Whether that trade is free is an empirical question, which is what
/// `WatchABExperiment` exists to answer. Three things could go wrong and none
/// is decidable by argument:
///
///  1. Slot-filling bias — two named fields make "nothing to report" harder to
///     say than it is when a whole call answers `NONE`.
///  2. Theme collapse — both prompts ask for the SINGLE most important issue;
///     asked together the model may put one theme in both slots.
///  3. Shared failure — one malformed reply now loses both notes.
///
/// Agenda is deliberately NOT merged here: different window (8k), a dedup list
/// in the prompt, and a strict-JSON contract whose findings are dropped when
/// the quote is not verbatim. Its degradation would be silent.
enum MergedWatch {
    static let systemPrompt = """
    You watch a live meeting on two separate tracks. Judge each track INDEPENDENTLY \
    — a problem on one track is not evidence of a problem on the other, and most \
    of the time at least one track is fine.

    RHETORIC: the single most important self-contradiction, unsupported claim, or \
    logical gap in what was said.
    FACILITATION: the single most important way the meeting is going off the rails \
    right now — drift from the goal, a circular discussion, a decision left \
    unresolved, an agenda item skipped, or time sunk on a low-value tangent.

    Each verdict is ONE short, specific sentence a participant could act on \
    immediately, or null when that track has nothing worth flagging. Do not fill a \
    track just because it is there, and do not report the same issue on both \
    tracks — if it belongs to one, leave the other null.

    Return ONLY JSON: {"rhetoric":"<sentence>"|null,"facilitation":"<sentence>"|null}
    """

    static func userPrompt(goal: String, transcript: String) -> String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalLine = trimmedGoal.isEmpty ? "(no explicit goal set)" : trimmedGoal
        return "Meeting goal: \(goalLine)\n\nRecent transcript:\n\(transcript)"
    }

    struct Verdicts: Equatable, Sendable {
        var rhetoric: String?
        var facilitation: String?
    }

    private struct Payload: Decodable {
        let rhetoric: String?
        let facilitation: String?
    }

    /// Parse both verdicts, applying the SAME normalization the separate watches
    /// apply — `NONE` sentinel, quote stripping, 240-character cap — so a
    /// comparison measures the merge, not a difference in post-processing.
    static func parse(_ raw: String) -> Verdicts {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Verdicts(rhetoric: nil, facilitation: nil)
        }
        return Verdicts(rhetoric: normalize(payload.rhetoric),
                        facilitation: normalize(payload.facilitation))
    }

    /// Shared with the separate watches by construction: same trimming, same
    /// NONE handling, same cap.
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        return RhetoricWatch.parse(value)
    }

    /// First balanced `{…}` object in the text, so a model that wraps its JSON
    /// in prose or a fence still parses.
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
