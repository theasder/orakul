import Foundation

/// Word error rate, plus the breakdown that says which failure mode caused it.
///
/// A single WER number hides the thing worth knowing. 0.30 made of deletions
/// means words were dropped — the chunk-boundary failure that turned 124 spoken
/// words into 53. The same 0.30 made of insertions means the decoder invented
/// speech, which is a different bug with a different fix. Reporting only the
/// total made both look like "accuracy got worse".
enum TranscriptAccuracy {

    struct Score {
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let referenceWords: Int
        let hypothesisWords: Int

        /// (S + D + I) / N. Can exceed 1.0 when the hypothesis invents more
        /// than it gets right, which is why it is not clamped.
        var wer: Double {
            referenceWords == 0 ? (hypothesisWords == 0 ? 0 : 1)
                                : Double(substitutions + deletions + insertions) / Double(referenceWords)
        }

        /// Share of reference words reproduced. Falls when speech is lost and
        /// is unaffected by hallucination, so it separates the two.
        var recall: Double {
            referenceWords == 0 ? 1 : Double(referenceWords - deletions - substitutions) / Double(referenceWords)
        }

        var summary: String {
            String(format: "WER %.4f  (S %d  D %d  I %d)  ref %d  hyp %d  recall %.3f",
                   wer, substitutions, deletions, insertions,
                   referenceWords, hypothesisWords, recall)
        }
    }

    // MARK: - Normalisation

    /// Spelled-out forms the two engines disagree on constantly. AssemblyAI
    /// writes "3 different levels", Whisper writes "three different levels";
    /// scoring that as an error measures formatting, not hearing.
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
    ]

    /// Casual spellings that differ by transcription style rather than by what
    /// was said. Some expand to SEVERAL words: "gonna" and "going to" are the
    /// same utterance, so a one-to-one map could never align them — the short
    /// form is one token and the long form is two.
    ///
    /// Only formatting variants belong here. Synonyms must not: "okay" and
    /// "alright" mean the same thing but are different words, and equating them
    /// would hide a genuine substitution.
    private static let expansions: [String: [String]] = [
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "kinda": ["kind", "of"], "sorta": ["sort", "of"], "lemme": ["let", "me"],
        "gimme": ["give", "me"], "dunno": ["do", "not", "know"],
        "cuz": ["because"], "cos": ["because"], "ok": ["okay"],
        "yeah": ["yes"], "yep": ["yes"], "yup": ["yes"], "nope": ["no"], "nah": ["no"],
    ]

    /// Lowercased, punctuation-stripped words with the equivalences above
    /// applied to BOTH sides. Any normalisation that is not symmetric would
    /// flatter one engine.
    static func normalise(_ text: String) -> [String] {
        // Apostrophes are removed rather than split on: splitting turns "I'm"
        // into "i" and "m", inflating the reference length and misaligning
        // everything after it.
        let flattened = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        return flattened
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .flatMap { word -> [String] in
                if let expanded = expansions[word] { return expanded }
                if let digits = numberWords[word] { return [digits] }
                return [word]
            }
    }

    // MARK: - Scoring

    static func score(reference: String, hypothesis: String) -> Score {
        align(reference: normalise(reference), hypothesis: normalise(hypothesis))
    }

    /// Levenshtein over words, keeping the backtrace so each edit is
    /// attributed to substitution, deletion or insertion.
    static func align(reference: [String], hypothesis: [String]) -> Score {
        let n = reference.count, m = hypothesis.count
        guard n > 0 else {
            return Score(substitutions: 0, deletions: 0, insertions: m,
                         referenceWords: 0, hypothesisWords: m)
        }
        guard m > 0 else {
            return Score(substitutions: 0, deletions: n, insertions: 0,
                         referenceWords: n, hypothesisWords: 0)
        }

        // cost[i][j] = edits to turn reference[0..<i] into hypothesis[0..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    cost[i][j] = 1 + min(cost[i - 1][j - 1],  // substitute
                                         cost[i - 1][j],      // delete
                                         cost[i][j - 1])      // insert
                }
            }
        }

        var substitutions = 0, deletions = 0, insertions = 0
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                substitutions += 1; i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1; i -= 1
            } else {
                insertions += 1; j -= 1
            }
        }

        return Score(substitutions: substitutions, deletions: deletions,
                     insertions: insertions, referenceWords: n, hypothesisWords: m)
    }

    /// Emitted lines that exactly repeat an earlier line, and lines that open
    /// with a conjunction.
    ///
    /// Both are seam symptoms. A live run showed six lines of which two were
    /// "and Kubernetes." and three began with "and" — the shape produced when a
    /// cut lands just before a conjunction, leaving a fragment that starts
    /// there. Aggressive seam trimming can cause it, so the change that trims
    /// harder has to be measured against it rather than assumed innocent.
    static func lineHygiene(_ lines: [String]) -> (duplicateRate: Double, conjunctionOpenRate: Double) {
        let meaningful = lines.filter { !normalise($0).isEmpty }
        guard !meaningful.isEmpty else { return (0, 0) }

        var seen = Set<[String]>()
        var duplicates = 0
        var conjunctionOpens = 0
        let openers: Set<String> = ["and", "but", "or", "so", "because", "then", "which", "that"]

        for line in meaningful {
            let words = normalise(line)
            if seen.contains(words) { duplicates += 1 }
            seen.insert(words)
            if let first = words.first, openers.contains(first) { conjunctionOpens += 1 }
        }
        return (Double(duplicates) / Double(meaningful.count),
                Double(conjunctionOpens) / Double(meaningful.count))
    }

    /// Share of `terms` present in the hypothesis. Product nouns and names
    /// carry the meaning of a meeting; losing "Kubernetes" costs more than
    /// losing "the", and WER weights them identically.
    static func termRecall(terms: [String], in hypothesis: String) -> (found: [String], missing: [String]) {
        let words = Set(normalise(hypothesis))
        var found: [String] = [], missing: [String] = []
        for term in terms {
            let parts = normalise(term)
            guard !parts.isEmpty else { continue }
            // A multi-word term counts only if every part survived.
            if parts.allSatisfy(words.contains) { found.append(term) } else { missing.append(term) }
        }
        return (found, missing)
    }
}
