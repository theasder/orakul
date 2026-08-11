import Foundation

/// Why a prompt is being offered on THIS call — backlog item 19.
///
/// The Fireflies skill panel recommends per meeting, and the recommendation
/// reads the content. We already choose WHICH prompts to show
/// (`QuickPromptResolver`); this supplies the REASON.
///
/// The acceptance is strict about quality: the reason must name something
/// specific from this call ("you mentioned a vendor deadline"), never a
/// category ("for planning meetings"), and a prompt with no specific reason is
/// offered WITHOUT one rather than given a generic sentence. So this is
/// deliberately **nil-biased and high-precision**: it fires only on concrete,
/// regex-verifiable hooks — a date, a deadline, a money figure, a percentage —
/// and stays silent otherwise. A weak "you mentioned risk" on every chip would
/// train people to ignore the line, which is the failure it exists to avoid.
///
/// No model call. The reason has to appear the instant the chips render and
/// must cost nothing — an LLM to explain a button is the wrong trade.
enum PromptReason {

    /// The concrete hook found in the transcript, and its rendered phrase.
    private struct Hook {
        let phrase: String        // "Friday", "$40k", "the deadline"
        let position: Int         // where it last appeared, for recency
    }

    /// Prompt intents that ACT on the substance of the call — for which a
    /// concrete deadline/figure is a genuine reason to run them now. A
    /// brainstorm or a rhetoric check is not made more relevant by a date, so
    /// those get no reason rather than a forced one.
    ///
    /// Matched against the prompt id, which is stable, lowercased.
    private static let actOnSubstance: Set<String> = [
        "logdecision", "risks", "unresolved", "factcheck", "summary",
        "tasks", "commitments", "agenda", "whattoask", "dispute",
    ]

    /// The one-line reason, or nil. `recentTranscript` is the tail the chips see;
    /// `goal` is the call goal, used only as a weak fallback signal.
    static func reason(promptID: String,
                       recentTranscript: String,
                       goal: String) -> String? {
        let id = promptID.lowercased()
        guard actOnSubstance.contains(id) else { return nil }

        let tail = String(recentTranscript.suffix(1_500))
        guard let hook = strongestHook(in: tail) else { return nil }
        return "You mentioned \(hook.phrase)"
    }

    // MARK: - Hook detection (high precision by construction)

    /// The most RECENT concrete hook, so the reason tracks what was just said.
    private static func strongestHook(in text: String) -> Hook? {
        let hooks = moneyHooks(in: text)
            + dateHooks(in: text)
            + deadlineHooks(in: text)
            + percentHooks(in: text)
        return hooks.max { $0.position < $1.position }
    }

    /// `$40k`, `$1.2M`, `40 thousand dollars` — a figure is specific by nature.
    private static func moneyHooks(in text: String) -> [Hook] {
        matches(text, #"\$[0-9][0-9,\.]*\s?[kmbKMB]?"#).map {
            Hook(phrase: $0.text.trimmingCharacters(in: .whitespaces), position: $0.at)
        }
    }

    /// Named weekdays and months, plus "tomorrow" / "tonight" / "next week" —
    /// the everyday deadlines a call turns on. Word-bounded so "Sunday" matches
    /// but "understand" does not.
    private static func dateHooks(in text: String) -> [Hook] {
        let days = "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday"
        let months = "January|February|March|April|May|June|July|August|September|October|November|December"
        let relative = "tomorrow|tonight|next week|this week|end of (the )?week|end of (the )?month|end of (the )?quarter"
        return matches(text, "\\b(\(days)|\(months)|\(relative))\\b", caseInsensitive: true).map {
            Hook(phrase: normalisedPhrase($0.text), position: $0.at)
        }
    }

    /// The word "deadline" / "due" / "by then" carries a commitment even without
    /// a date attached.
    private static func deadlineHooks(in text: String) -> [Hook] {
        matches(text, #"\b(deadline|due date|due by|overdue)\b"#, caseInsensitive: true).map {
            Hook(phrase: "a deadline", position: $0.at)
        }
    }

    /// A percentage is a concrete figure a fact-check or risk prompt bites on.
    private static func percentHooks(in text: String) -> [Hook] {
        matches(text, #"\b[0-9][0-9\.]*\s?(percent|%)"#, caseInsensitive: true).map {
            Hook(phrase: $0.text.trimmingCharacters(in: .whitespaces), position: $0.at)
        }
    }

    // MARK: - Regex plumbing

    private struct Match { let text: String; let at: Int }

    private static func matches(_ text: String, _ pattern: String,
                                caseInsensitive: Bool = false) -> [Match] {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard let r = Range(result.range, in: text) else { return nil }
            return Match(text: String(text[r]), at: result.range.location)
        }
    }

    /// Lowercase a relative phrase ("Tomorrow" → "tomorrow") but keep a weekday
    /// or month capitalised, since that is how they are written.
    private static func normalisedPhrase(_ raw: String) -> String {
        let lower = raw.lowercased()
        let relatives = ["tomorrow", "tonight", "next week", "this week",
                         "end of week", "end of the week", "end of month",
                         "end of the month", "end of quarter", "end of the quarter"]
        if relatives.contains(lower) { return lower }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
    }
}
