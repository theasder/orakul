import Foundation

/// Deterministic audit of figures in a generated artifact (roadmap F10).
///
/// Mined pains: models "paraphrase" numbers, and "issues with number
/// transcriptions can be a significant concern for those working with data or
/// finance". FactCheckService judges CLAIMS with a model; this guard does the
/// opposite kind of work — a dumb, complete comparison of every number the
/// artifact states against every number the transcript contains. A figure the
/// room never said is either the model inventing precision or mangling a real
/// one; both belong in front of the user, not silently in the export.
enum NumbersGuard {

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"[$€£]?\d[\d,]*(?:\.\d+)?\s?(?:%|k\b|m\b|mm\b|bn\b)?"#,
        options: [.caseInsensitive])

    /// Canonical form for comparison: currency and thousands separators are
    /// display choices, "2.5k" and "2500" are the same spoken quantity, and a
    /// trailing percent is part of the value. "$2,500" == "2500" == "2.5k".
    static func canonical(_ raw: String) -> String {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let isPercent = text.hasSuffix("%")
        text = text.replacingOccurrences(of: #"[$€£,%\s]"#, with: "", options: .regularExpression)
        var multiplier = 1.0
        for (suffix, factor) in [("bn", 1e9), ("mm", 1e6), ("m", 1e6), ("k", 1e3)] {
            if text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                multiplier = factor
                break
            }
        }
        guard let value = Double(text) else { return raw.lowercased() }
        let scaled = value * multiplier
        let formatted = scaled == scaled.rounded() && abs(scaled) < 1e15
            ? String(Int(scaled))
            : String(scaled)
        return isPercent ? formatted + "%" : formatted
    }

    /// Spoken forms, because a transcript writes what the room SAID. Without
    /// these, "twenty five hundred dollars" in the transcript and "$2,500" in
    /// the minutes look like an invented figure — measured: a four-sentence
    /// passage where every number was spoken aloud produced four false alarms.
    /// A warning that is usually wrong is one people switch off, and it takes
    /// the real catches with it.
    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let numberScales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Every quantity a spoken passage expresses in words, as canonical values.
    ///
    /// Deliberately generous rather than exact: it emits the running total at
    /// each step ("twenty five hundred" yields 20, 25, and 2500), because the
    /// job is to avoid accusing the model of inventing a figure the room said —
    /// a spurious extra value costs nothing, while a missed one costs a false
    /// alarm. It does NOT weaken the real catch: a number nobody uttered in any
    /// form still has no match.
    static func spokenNumbers(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = 0
        var sawWord = false
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(raw)
            if let unit = numberWords[word] {
                current = current + unit
                sawWord = true
                found.insert(String(current))
            } else if let scale = numberScales[word], sawWord {
                current = max(current, 1) * scale
                found.insert(String(current))
            } else if word == "percent", sawWord {
                // "forty percent" and "40%" are the same statement; canonical()
                // keeps the percent suffix distinct from a bare count, so the
                // spoken side has to carry it too or every percentage in a
                // transcript reads as invented.
                found.insert(String(current) + "%")
                found.insert(String(current))
                current = 0
                sawWord = false
            } else if sawWord {
                found.insert(String(current))
                current = 0
                sawWord = false
            }
        }
        if sawWord { found.insert(String(current)) }
        return found
    }

    static func numbers(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        numberPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            found.insert(canonical(String(text[r])))
        }
        return found
    }

    /// Figures the artifact states that the transcript never does, in the
    /// artifact's own display form (that is what the user must go verify).
    static func unverifiedFigures(artifact: String, transcript: String) -> [String] {
        let spoken = numbers(in: transcript).union(spokenNumbers(in: transcript))
        let range = NSRange(artifact.startIndex..., in: artifact)
        var flagged: [String] = []
        var seen: Set<String> = []
        numberPattern.enumerateMatches(in: artifact, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: artifact) else { return }
            let display = String(artifact[r]).trimmingCharacters(in: .whitespaces)
            let key = canonical(display)
            guard !spoken.contains(key), !seen.contains(key) else { return }
            seen.insert(key)
            flagged.append(display)
        }
        return flagged
    }
}
