import Foundation

/// Removes the words a chunk repeats from the chunk before it.
///
/// Audio is cut into fixed windows and each window is transcribed alone. With
/// hard cuts, an utterance crossing a boundary is decoded twice with half the
/// context each time, and the halves come back mangled — a measured run showed
/// "The vendor has not confirmed the delivery date for the" followed by the
/// orphans "Agreed. The", "Kubernetes," and "and". Whisper's short-fragment
/// filter then discards those remnants as hallucinations, so the words are gone
/// entirely: 124 spoken words arrived as 53.
///
/// The fix is to overlap the windows so no word sits alone at a seam. That
/// makes the overlap region transcribe TWICE, which this undoes.
///
/// Line-level dedup cannot do this job. The second chunk's line legitimately
/// contains the repeat AND new speech — "delivery date for the hardware, and
/// the vendor…" — so dropping the line would delete the new words, and keeping
/// it duplicates the old ones. The seam has to be cut inside the line.
enum ChunkStitcher {

    /// Longest word-suffix of `previous` that is also a word-prefix of `next`,
    /// capped so a coincidence cannot eat real speech.
    static let maximumOverlapWords = 24

    /// A one-word match is usually a coincidence — "the", "and", "we" end and
    /// begin sentences constantly — so a single shared word is not treated as a
    /// seam unless it is long enough to be distinctive.
    static let minimumOverlapWords = 2

    /// Fuzzy matching needs more evidence than exact matching: an exact 2-word
    /// match is already weak, and a 2-word match with one word wrong is noise.
    static let minimumFuzzyOverlapWords = 4

    /// How much of the seam must agree for a near-match to count.
    ///
    /// Measured on a real call: requiring an EXACT match left 113 insertions in
    /// 696 reference words, and 8 of the 12 largest were overlap regions the
    /// two decodes worded differently — "like using the back" against "like
    /// using the background". One disagreeing word broke the whole match and
    /// the seam was emitted twice.
    ///
    /// Swept on two 5-minute segments of a real call — one used for tuning, one
    /// held out — measured by WER against an AssemblyAI reference:
    ///
    ///     threshold   tuning   holdout   deletions (tune/hold)
    ///     exact only  0.1810   0.1786     7 / 11
    ///     0.75        0.1279   0.1336     8 / 16
    ///     0.65        0.1063   0.1269     8 / 17
    ///     0.55        0.0963   0.1169     9 / 17
    ///     0.45        0.0977   0.1102    14 / 19
    ///
    /// 0.45 has the marginally better mean, but it is where deletions start
    /// accelerating — the seam search begins cutting text that was not a
    /// repeat. WER counts a deletion and an insertion the same; a meeting
    /// assistant should not. A duplicated word is something the reader skims
    /// past, while a deleted one is speech that silently never reaches them.
    ///
    /// 0.55 is statistically tied on mean WER and holds that growth, so it is
    /// the safer side of a flat optimum.
    static let fuzzyAgreementThreshold = 0.55

    /// `next` with its repeated opening removed.
    ///
    /// Comparison is on normalised words (case and punctuation folded) because
    /// the two decodes of the same audio rarely agree on either: "Postgres
    /// cluster." and "postgres cluster" are the same words.
    static func stitch(previous: String, next: String) -> String {
        let previousWords = words(in: previous)
        let nextWords = words(in: next)
        guard !previousWords.isEmpty, !nextWords.isEmpty else { return next }

        let limit = min(maximumOverlapWords, previousWords.count, nextWords.count)
        guard limit >= minimumOverlapWords else { return next }

        // Longest first: a 6-word seam must win over the 2-word one inside it,
        // or the leftover 4 words are emitted twice.
        var length = limit
        while length >= minimumOverlapWords {
            let tail = previousWords.suffix(length).map(\.normalized)
            let head = nextWords.prefix(length).map(\.normalized)
            if tail == head {
                return remainder(of: next, afterWords: length, using: nextWords)
            }
            length -= 1
        }

        // No exact seam. The overlap was still transcribed twice, so look again
        // allowing the two decodes to disagree on some words.
        //
        // Unlike the exact pass this takes the BEST-agreeing length, not the
        // longest one above the bar. A window longer than the true seam still
        // clears the bar — its score is carried by the real seam inside it —
        // and cutting at that length eats real speech past the seam. Measured:
        // taking longest-above-bar trimmed one word too many every time.
        var best: (length: Int, agreement: Double)?
        length = limit
        while length >= minimumFuzzyOverlapWords {
            let tail = previousWords.suffix(length).map(\.normalized)
            let head = nextWords.prefix(length).map(\.normalized)
            let score = agreement(tail, head)
            // Ties go to the longer window: inside a true seam every sub-window
            // also scores 1.0, and the longest is the whole repeat.
            if score >= fuzzyAgreementThreshold, score > (best?.agreement ?? 0) {
                best = (length, score)
            }
            length -= 1
        }
        if let best {
            return remainder(of: next, afterWords: best.length, using: nextWords)
        }
        return next
    }

    /// Longest common subsequence over the longer side: 1.0 when the two
    /// decodes agree completely, 0 when they share nothing.
    ///
    /// A subsequence rather than position-by-position comparison, because one
    /// decode routinely has a word the other does not ("going to" against
    /// "gonna"). Comparing by position would shift everything after the extra
    /// word and score a true seam near zero.
    static func agreement(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var previousDiagonal = 0
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previousDiagonal + 1
                                              : max(row[j], row[j - 1])
                previousDiagonal = current
            }
        }
        return Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// Whether `next` says nothing `previous` did not already say. A window
    /// that lands entirely inside the overlap decodes to a pure repeat, and
    /// emitting it would duplicate a line rather than extend one.
    static func isPureRepeat(previous: String, next: String) -> Bool {
        let trimmed = stitch(previous: previous, next: next)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    // MARK: - Internals

    /// Clause separators that belong to the words removed at the seam, never
    /// to the fragment that follows.
    static let strandedMarks: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    struct Word {
        let normalized: String
        /// Index just past this word in the ORIGINAL string, so the surviving
        /// text keeps its own punctuation and spacing rather than being
        /// rebuilt from normalised tokens.
        let endOffset: String.Index
    }

    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        var index = text.startIndex
        var wordEnd = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                current.append(Character(character.lowercased()))
                wordEnd = text.index(after: index)
            } else if !current.isEmpty {
                result.append(Word(normalized: current, endOffset: wordEnd))
                current = ""
            }
            index = text.index(after: index)
        }
        if !current.isEmpty {
            result.append(Word(normalized: current, endOffset: wordEnd))
        }
        return result
    }

    private static func remainder(of text: String,
                                  afterWords count: Int,
                                  using words: [Word]) -> String {
        guard count > 0, count <= words.count else { return text }
        let cut = words[count - 1].endOffset
        // Also drop punctuation left stranded at the cut. The seam usually
        // falls mid-sentence, so the remainder would otherwise open with the
        // comma or full stop that belonged to the words just removed — the
        // ". , yes." artifacts visible in real transcripts.
        //
        // Only marks that SEPARATE clauses are debris. A dash or an opening
        // quote can legitimately begin a continuation and is left alone.
        return String(text[cut...])
            .drop { $0.isWhitespace || Self.strandedMarks.contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
