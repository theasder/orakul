import Foundation

/// Puts glossary terms back into a FINISHED transcript, as text.
///
/// The decoder-prompt glossary is the wrong tool for the whole-file pass:
/// measured over the corpus it bought term recall by deleting speech — small
/// went from 125 to 356 deletions, and the large build collapsed to WER 0.95
/// with 2757 deletions and zero term recall. So the whole-file pass decodes
/// with no glossary at all, and this pass restores the vocabulary afterwards,
/// where a mistake can only ever touch one token and can never make speech
/// disappear.
///
/// Two operations, gated differently:
///
/// - **Casing restore.** A token identical to a term modulo case and
///   punctuation ("pcep", "yang model") becomes the canonical spelling. No
///   ambiguity exists, so no gate beyond equality.
/// - **Garble repair.** A token within one edit of a term is replaced ONLY
///   when it does not read as ordinary prose — it carries an uppercase
///   letter, a digit, or no vowel ("PSEP", "MPLST", "OEM"). A lowercase
///   English word stays: "piece" IS how the decoder mishears "PCE", and it
///   is also a word people say. A text pass cannot tell those apart, so it
///   must not try — that asymmetry is the whole safety argument.
enum GlossaryRestore {

    /// Fuzzy repair needs enough letters that one edit still identifies the
    /// term; below this, casing restore only.
    static let minimumFuzzyLength = 3

    /// - Parameters:
    ///   - glossary: the user's own terms. Eligible for garble repair —
    ///     measured safe, because a user's glossary covers the acronym space
    ///     of the user's own calls.
    ///   - casingOnlyGlossary: the shipped domain lexicon. Casing and plural
    ///     restoration only, which is WER-invariant by construction. Measured
    ///     at 230 terms: allowing fuzzy repair here rewrote out-of-lexicon
    ///     acronyms into their one-edit lexicon neighbours — "GAC" became
    ///     "CAC", "IDN" became "IDE" — at +0.4 WER on every tier. A generic
    ///     lexicon can never cover a specific call's acronym space, so it
    ///     never earns the fuzzy privilege.
    static func restore(transcript: String,
                        glossary: [String],
                        casingOnlyGlossary: [String] = []) -> String {
        let userTerms = prepared(glossary)
        // User spellings win: a lexicon entry whose norm the user already
        // defines is dropped, not merged.
        let userNorms = Set(userTerms.map(\.norm))
        let lexicon = prepared(casingOnlyGlossary).filter { !userNorms.contains($0.norm) }
        let terms = userTerms + lexicon
        guard !transcript.isEmpty, !terms.isEmpty else { return transcript }

        var text = transcript
        // Multi-word terms first, longest first, so "YANG model" wins before
        // a single-word pass could touch "model".
        for term in terms.filter({ $0.words.count > 1 }).sorted(by: { $0.words.count > $1.words.count }) {
            text = restoreCasing(of: term, in: text)
        }

        let fuzzyNorms = Set(userTerms.map(\.norm))
        let singles = terms.filter { $0.words.count == 1 }
        guard !singles.isEmpty else { return text }
        let allNorms = Set(terms.map(\.norm))
        return repairTokens(in: text, terms: singles,
                            protectedNorms: allNorms, fuzzyNorms: fuzzyNorms)
    }

    // MARK: - Term preparation

    private struct Term {
        let canonical: String
        let norm: String
        let words: [String]
    }

    private static func prepared(_ glossary: [String]) -> [Term] {
        var seen = Set<String>()
        return glossary.compactMap { raw in
            let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let norm = normalise(canonical)
            guard !canonical.isEmpty, !norm.isEmpty, seen.insert(norm).inserted else { return nil }
            return Term(canonical: canonical,
                        norm: norm,
                        words: canonical.split(whereSeparator: \.isWhitespace).map(String.init))
        }
    }

    /// Lowercased alphanumerics only: "MPLS-TE" and "mplste" compare equal.
    private static func normalise(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Multi-word casing

    private static func restoreCasing(of term: Term, in text: String) -> String {
        let pattern = term.words
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        // A dot on either side means this is part of a qualified name, not a
        // standalone word: measured on a real transcript, "adcreative.ai"
        // became "adcreative.AI" — the pass rewriting somebody's product name
        // because its suffix happens to be a lexicon term. Domains, file names
        // and package paths all read the same way to a word-boundary match.
        guard let regex = try? NSRegularExpression(pattern: "(?<![.\\w])\(pattern)\\b(?!\\.\\w)",
                                                   options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term.canonical))
    }

    // MARK: - Single tokens

    private static let tokenPattern = try? NSRegularExpression(
        pattern: "[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9'’-]*")

    private static func repairTokens(in text: String,
                                     terms: [Term],
                                     protectedNorms: Set<String>,
                                     fuzzyNorms: Set<String>) -> String {
        guard let tokenPattern else { return text }
        let matches = tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            // A token glued to a dot on either side is part of a qualified
            // name, not a word: the tokenizer splits "adcreative.ai" into
            // "adcreative" and "ai", and measured on a real transcript the
            // second half became "AI" — the pass rewriting somebody's product
            // name. Domains, file names and package paths all split this way.
            if isPartOfQualifiedName(range, in: result) { continue }
            let token = String(result[range])
            guard let replacement = replacement(for: token,
                                                terms: terms,
                                                protectedNorms: protectedNorms,
                                                fuzzyNorms: fuzzyNorms),
                  replacement != token else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Whether a matched token sits immediately beside a dot that joins it to
    /// more word characters — the shape of a domain, path or file name.
    private static func isPartOfQualifiedName(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before == "." { return true }
        }
        if range.upperBound < text.endIndex, text[range.upperBound] == "." {
            let afterDot = text.index(after: range.upperBound)
            if afterDot < text.endIndex, text[afterDot].isLetter || text[afterDot].isNumber {
                return true
            }
        }
        return false
    }

    private static func replacement(for token: String,
                                    terms: [Term],
                                    protectedNorms: Set<String>,
                                    fuzzyNorms: Set<String>) -> String? {
        let norm = normalise(token)
        guard !norm.isEmpty else { return nil }

        // Exact modulo case and punctuation — casing restore, always safe.
        if let exact = terms.first(where: { $0.norm == norm }) {
            return exact.canonical
        }

        // An inflection of a term is CORRECT English, not a garble: "RSPs" is
        // the plural of RSP and "ICANN's" its possessive. The first measured
        // corpus run treated both as one-edit garbles and stripped them —
        // nine fresh substitutions on one fixture. A plain plural still gets
        // its casing restored ("rsps" → "RSPs"); an apostrophe form is left
        // exactly as written.
        if let stem = terms.first(where: { norm == $0.norm + "s" }) {
            guard !token.contains("'"), !token.contains("\u{2019}") else { return nil }
            return stem.canonical + "s"
        }

        // Fuzzy repair — user-glossary terms only. The token must LOOK like a
        // garble rather than prose, must not itself be some other glossary
        // term, and must be long enough that one edit still identifies it.
        guard norm.count >= minimumFuzzyLength,
              looksLikeGarble(token), !protectedNorms.contains(norm) else { return nil }
        for term in terms where term.norm.count >= minimumFuzzyLength
                                && fuzzyNorms.contains(term.norm) {
            let budget = max(1, term.norm.count / 5)
            if editDistance(norm, term.norm) <= budget {
                return term.canonical
            }
        }
        return nil
    }

    /// Ordinary prose is lowercase and voweled; a recogniser garble of an
    /// acronym or product name almost never is.
    ///
    /// The first character's case is deliberately ignored: every sentence
    /// starts with a capital, so "Can" must stay prose even when the glossary
    /// holds a term one edit away. An uppercase letter AFTER the first, a
    /// digit, or a missing vowel is what marks a token as not-a-word.
    private static func looksLikeGarble(_ token: String) -> Bool {
        // "y" counts as the vowel it usually is — "why" and "try" are words,
        // not garbles, and "why" sits one edit from PHY. The vowel set covers
        // Cyrillic too: without it every Russian word reads as "vowelless"
        // and the whole transcript becomes fair game for fuzzy repair.
        token.dropFirst().contains(where: \.isUppercase)
            || token.contains(where: \.isNumber)
            || !token.lowercased().contains(where: { "aeiouyаеёиоуыэюя".contains($0) })
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let left = Array(a), right = Array(b)
        if abs(left.count - right.count) > 2 { return .max }
        var previous = Array(0...right.count)
        for (i, char) in left.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(right.count + 1)
            for (j, other) in right.enumerated() {
                current.append(min(previous[j] + (char == other ? 0 : 1),
                                   previous[j + 1] + 1,
                                   current[j] + 1))
            }
            previous = current
        }
        return previous[right.count]
    }
}
