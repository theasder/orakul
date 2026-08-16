import Foundation

/// Suppresses transcript lines that repeat speech already captured.
///
/// Two distinct sources of duplication, both reported in the same call:
///
///  1. **The same words on both tracks.** A call captures two streams — the
///     meeting (ScreenCaptureKit, labelled "Them") and the microphone
///     ("You"). When the meeting plays through speakers, the mic hears it too.
///     Echo cancellation is enabled only when the audio route has an echo path
///     and is imperfect regardless, so remote speech reappears as a near-copy
///     under the local label. That is why "Them" lines and non-"Them" lines
///     read the same.
///
///  2. **Whisper repeating itself.** Chunked inference re-emits the tail of the
///     previous window as the head of the next one, and the model is prone to
///     looping on near-silence. Both produce an immediate near-copy on ONE
///     track.
///
/// Pure and time-windowed: only lines close together in time can mask each
/// other, so a genuinely repeated phrase later in the meeting still survives.
enum TranscriptDeduplicator {
    /// How far back a line can mask a new one. Wide enough to cover a chunk
    /// round-trip plus a backlog, short enough that saying the same sentence
    /// twice minutes apart is kept.
    static let window: TimeInterval = 14

    /// Below this token count, only an EXACT repeat is dropped. Short replies
    /// ("yes", "right", "makes sense") legitimately recur from both people
    /// seconds apart, and fuzzy-matching them would delete real dialogue.
    static let fuzzyMinimumTokens = 4

    /// Token overlap at which two lines are treated as the same utterance.
    /// Cross-track echo is never byte-identical — the mic path colours the
    /// audio, so two transcriptions of one sentence differ by a word or two.
    /// Measured against real pairs: "…the pricing change on Friday" vs
    /// "…the pricing changes on Friday" scores 0.78, so 0.8 was too strict to
    /// catch the very case this exists for.
    static let similarityThreshold = 0.72

    /// Cross-track threshold, used only when the two lines came from DIFFERENT
    /// sources within `crossTrackWindow`.
    ///
    /// The asymmetry is physical, not a tuning preference. Mic and system captured
    /// THE SAME SOUND — one utterance through two signal paths — so two moderately
    /// similar lines seconds apart on opposite tracks are almost certainly one
    /// utterance transcribed twice. Reported case: the same sentence recognised
    /// differently enough that token overlap fell under 0.72 and both copies were
    /// kept.
    ///
    /// Same-track repeats keep the stricter bar, because there the competing
    /// explanation — someone actually said something similar again — is real, and
    /// dropping it loses content silently.
    static let crossTrackSimilarityThreshold = 0.55

    /// How close in time two tracks must be for the cross-track rule to apply. One
    /// sound reaching both paths arrives near-simultaneously; several seconds apart
    /// is two people talking, and the strict threshold should govern that.
    static let crossTrackWindow: TimeInterval = 6

    /// Deepgram can keep a microphone hypothesis open while the cleaner system
    /// stream finalizes several utterances. Its eventual mic interim/final is
    /// then one cumulative copy of many system entries, so comparing it to each
    /// entry independently cannot see the echo. Keep a longer, bounded window
    /// solely for that cumulative mic -> system comparison.
    static let cumulativeCrossTrackWindow: TimeInterval = 60
    static let cumulativeEchoMinimumTokens = 8
    static let cumulativeEchoMatchDensity = 0.70
    static let cumulativeEchoMaximumGap = 3
    /// LCS is intentionally bounded: normal one-minute hypotheses are far
    /// smaller, while a corrupt/runaway interim must never allocate a
    /// candidate×history matrix large enough to stall live capture.
    static let cumulativeEchoMaximumCandidateTokens = 1_024
    static let cumulativeEchoMaximumSystemTokens = 2_048

    /// For a clipped re-emission, how much of the LONGER line the shorter one
    /// must cover before they count as the same utterance. Keeps a genuine
    /// elaboration ("the migration is risky" → "the migration is risky because
    /// the backfill has never been tested") — which contains the earlier line
    /// verbatim — out of the duplicate bucket.
    static let containmentCoverage = 0.6

    /// Should this line be dropped as a duplicate of something already kept?
    ///
    /// `recent` is the tail of the transcript, newest last; only entries inside
    /// the window are considered.
    // MARK: - Noise artifacts

    /// Whole-line connectives produced when a chunk contains too little speech.
    /// The list is deliberately closed: real one-word replies such as
    /// "Да", "Нет", and "Окей" must survive.
    static let fillerSingletons: Set<String> = [
        "и", "в", "а", "с", "у", "ну", "вот", "э", "мм",
        "the", "so", "and", "o", "uh", "um",
    ]

    /// A custom glossary biases the decoder toward those words. On noise this
    /// can produce a line made entirely from the glossary itself; with no
    /// glossary configured this gate remains inactive.
    static func isNoiseArtifact(_ entry: TranscriptEntry, glossary: [String]) -> Bool {
        let entryTokens = tokens(entry.text)
        if entryTokens.count == 1, fillerSingletons.contains(entryTokens[0]) {
            return true
        }
        guard !entryTokens.isEmpty, !glossary.isEmpty else { return false }
        let glossaryTokens = Set(glossary.flatMap { tokens($0) })
        guard !glossaryTokens.isEmpty else { return false }
        return entryTokens.allSatisfy { glossaryTokens.contains($0) }
    }

    /// A short same-track result may be a garbled re-emission of the previous
    /// line's tail. Suffix anchoring and the short time window distinguish it
    /// from a genuine repeat later in the call.
    static let sameTrackStutterWindow: TimeInterval = 6
    static let sameTrackStutterThreshold = 0.66

    static func isGarbledTailStutter(_ fragment: String, previous: String) -> Bool {
        guard fragment.count >= fragmentMinimumCharacters else { return false }
        guard fragment.count <= previous.count else { return false }
        let tail = String(previous.suffix(fragment.count + 4))
        return characterSimilarity(fragment, tail) >= sameTrackStutterThreshold
    }

    static func isDuplicate(_ candidate: TranscriptEntry,
                            of recent: [TranscriptEntry],
                            window: TimeInterval = window) -> Bool {
        let candidateTokens = tokens(candidate.text)
        guard !candidateTokens.isEmpty else { return true }

        for existing in recent.reversed() {
            let age = candidate.timestamp.timeIntervalSince(existing.timestamp)
            // Entries are ordered, so the first one too old ends the search.
            if age > window { break }
            // A line cannot duplicate one recorded after it.
            if age < -window { continue }

            let existingTokens = tokens(existing.text)
            if existingTokens.isEmpty { continue }
            if existingTokens == candidateTokens { return true }

            // Echo through two acoustic paths changes word boundaries and even
            // scripts, so exact-token rules miss it. Character comparison is
            // cross-track only and tightly time-bounded; same-track dialogue
            // keeps the stricter token rules.
            if existing.source != candidate.source,
               abs(candidate.timestamp.timeIntervalSince(existing.timestamp))
                   <= crossTrackWindow {
                let candidateCharacters = normalizedCharacters(candidate.text)
                let existingCharacters = normalizedCharacters(existing.text)
                if candidateTokens.count >= fuzzyMinimumTokens,
                   candidateCharacters.count >= fullLineMinimumCharacters,
                   characterSimilarity(candidateCharacters, existingCharacters)
                       >= crossTrackCharacterThreshold {
                    return true
                }
                if candidateTokens.count <= fragmentMaximumTokens,
                   fragmentIsEcho(candidateCharacters, host: existingCharacters) {
                    return true
                }
            }

            if existing.source == candidate.source,
               abs(age) <= sameTrackStutterWindow,
               candidateTokens.count <= fragmentMaximumTokens,
               isGarbledTailStutter(normalizedCharacters(candidate.text),
                                    previous: normalizedCharacters(existing.text)) {
                return true
            }

            guard candidateTokens.count >= fuzzyMinimumTokens,
                  existingTokens.count >= fuzzyMinimumTokens else { continue }

            // A clipped re-emission of nearly the same line. Gated on coverage
            // so an elaboration that quotes the earlier line and then adds real
            // content is NOT treated as a repeat.
            if isClippedRepeat(candidateTokens, existingTokens) { return true }
            // A chunk boundary re-emits the tail of the previous window as the
            // head of the next: the candidate STARTS with what the last line
            // ENDED with.
            if overlapsAtChunkBoundary(previous: existingTokens, next: candidateTokens) {
                return true
            }
            // Cross-track pairs use the lower bar; same-track keeps the strict one.
            let crossTrack = existing.source != candidate.source
                && abs(age) <= crossTrackWindow
            let threshold = crossTrack ? crossTrackSimilarityThreshold : similarityThreshold
            if similarity(candidateTokens, existingTokens) >= threshold {
                return true
            }
        }
        return false
    }

    /// When the microphone echo finalizes before the cleaner system stream, a
    /// first-arrival-wins duplicate policy assigns remote speech to the local
    /// user and then throws away the labeled system final. Return only the
    /// recent mic entry that is itself a whole-utterance echo of this system
    /// candidate; unrelated/local speech is never selected.
    static func preferredMicEchoIndex(
        forSystem candidate: TranscriptEntry,
        in recent: [TranscriptEntry]
    ) -> Int? {
        guard candidate.source == .system else { return nil }
        for index in recent.indices.reversed() {
            let existing = recent[index]
            guard existing.source == .mic else { continue }
            let age = candidate.timestamp.timeIntervalSince(existing.timestamp)
            // Arrival order is already known: `existing` is in the transcript
            // and `candidate` is being admitted now. Capture timestamps can be
            // reversed when the system decode was slower, so compare absolute
            // acoustic proximity rather than completion order.
            guard abs(age) <= crossTrackWindow else { continue }
            if isDuplicate(candidate, of: [existing], window: crossTrackWindow) {
                return index
            }
        }
        return nil
    }

    // MARK: - Character-level echo detection

    /// Full-line cross-track threshold measured on a Russian call where the
    /// microphone captured a garbled copy of the system track. Token overlap
    /// missed the copies; transliterated character runs survived them.
    static let crossTrackCharacterThreshold = 0.62

    /// Short echo fragments must both start like a contiguous part of the host
    /// and be mostly contained in it. Head anchoring keeps a genuine reply that
    /// merely quotes the question's verb.
    static let fragmentHeadCharacters = 6
    static let fragmentHeadThreshold = 0.8
    static let fragmentContainmentThreshold = 0.75
    static let fragmentMinimumCharacters = 5
    static let fullLineMinimumCharacters = 8
    static let fragmentMaximumTokens = 3

    /// Lowercase, fixed Cyrillic-to-Latin transliteration, ASCII alphanumerics,
    /// and no spaces. Removing spaces is intentional because acoustic garble
    /// often fuses words; the fixed table keeps tuned thresholds deterministic.
    static func normalizedCharacters(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if let mapped = cyrillicToLatin[scalar] {
                output.append(contentsOf: mapped.unicodeScalars)
            } else if scalar.isASCII,
                      scalar.properties.isAlphabetic
                        || ("0"..."9").contains(Character(scalar)) {
                output.append(scalar)
            }
            if output.count >= 400 { break }
        }
        return String(output)
    }

    private static let cyrillicToLatin: [Unicode.Scalar: String] = {
        let pairs: [(String, String)] = [
            ("а", "a"), ("б", "b"), ("в", "v"), ("г", "g"), ("д", "d"),
            ("е", "e"), ("ё", "e"), ("ж", "zh"), ("з", "z"), ("и", "i"),
            ("й", "i"), ("к", "k"), ("л", "l"), ("м", "m"), ("н", "n"),
            ("о", "o"), ("п", "p"), ("р", "r"), ("с", "s"), ("т", "t"),
            ("у", "u"), ("ф", "f"), ("х", "kh"), ("ц", "ts"), ("ч", "ch"),
            ("ш", "sh"), ("щ", "shch"), ("ъ", ""), ("ы", "y"), ("ь", ""),
            ("э", "e"), ("ю", "iu"), ("я", "ia"),
        ]
        var table: [Unicode.Scalar: String] = [:]
        for (cyrillic, latin) in pairs {
            table[cyrillic.unicodeScalars.first!] = latin
        }
        return table
    }()

    /// Symmetric LCS ratio: 2·LCS / (|a| + |b|).
    static func characterSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let lcs = longestCommonSubsequence(Array(a.utf8), Array(b.utf8))
        return Double(2 * lcs) / Double(a.utf8.count + b.utf8.count)
    }

    /// Share of the fragment that appears in the host in the same order.
    static func characterContainment(fragment: String, in host: String) -> Double {
        guard !fragment.isEmpty, !host.isEmpty else { return 0 }
        return Double(longestCommonSubsequence(Array(fragment.utf8), Array(host.utf8)))
            / Double(fragment.utf8.count)
    }

    /// Best similarity against a contiguous host window. Free subsequence
    /// matching across a long host would make almost any short fragment match.
    static func bestWindowSimilarity(of needle: String, in host: String) -> Double {
        let needleBytes = Array(needle.utf8)
        let hostBytes = Array(host.utf8)
        guard !needleBytes.isEmpty, !hostBytes.isEmpty else { return 0 }
        var best = 0.0
        for width in max(1, needleBytes.count - 2)...(needleBytes.count + 2) {
            guard width <= hostBytes.count else { break }
            for start in 0...(hostBytes.count - width) {
                let window = Array(hostBytes[start..<(start + width)])
                let lcs = longestCommonSubsequence(needleBytes, window)
                best = max(
                    best,
                    Double(2 * lcs) / Double(needleBytes.count + width))
            }
        }
        return best
    }

    static func fragmentIsEcho(_ fragment: String, host: String) -> Bool {
        guard fragment.utf8.count >= fragmentMinimumCharacters else { return false }
        let head = String(fragment.prefix(fragmentHeadCharacters))
        return bestWindowSimilarity(of: head, in: host) >= fragmentHeadThreshold
            && characterContainment(fragment: fragment, in: host)
                >= fragmentContainmentThreshold
    }

    private static func longestCommonSubsequence(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 0..<a.count {
            for j in 0..<b.count {
                current[j + 1] = a[i] == b[j]
                    ? previous[j] + 1
                    : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
            current[0] = 0
        }
        return previous[b.count]
    }

    /// Words, lowercased, stripped of punctuation. Comparing on tokens rather
    /// than raw text makes the check immune to the punctuation and casing that
    /// differ between two transcriptions of the same audio.
    ///
    /// Apostrophes are removed rather than kept, so "let's" and "lets" — which
    /// two transcriptions of one word routinely disagree about — collapse to
    /// the same token instead of counting as a difference.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// One line is the other with the edges clipped, and covers enough of it to
    /// be the same utterance rather than an elaboration of it.
    static func isClippedRepeat(_ a: [String], _ b: [String]) -> Bool {
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard !longer.isEmpty, containsRun(longer, shorter) else { return false }
        return Double(shorter.count) / Double(longer.count) >= containmentCoverage
    }

    /// Does `next` begin with the words `previous` ended with? That is the
    /// signature of chunked inference re-emitting its own tail.
    static func overlapsAtChunkBoundary(previous: [String], next: [String],
                                        minimumRun: Int = fuzzyMinimumTokens) -> Bool {
        let maximum = min(previous.count, next.count)
        guard maximum >= minimumRun else { return false }
        for length in stride(from: maximum, through: minimumRun, by: -1) {
            guard Array(previous.suffix(length)) == Array(next.prefix(length)) else { continue }
            // The repeated run has to be most of the new line; a few shared
            // words at a genuine handover are not a duplicate.
            return Double(length) / Double(next.count) >= containmentCoverage
        }
        return false
    }

    /// Does `haystack` contain `needle` as a contiguous run?
    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for start in 0...limit where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// The best similarity score against anything in the window, and the line it
    /// scored against. Diagnostics only — `isDuplicate` never calls this.
    ///
    /// Exists because a MISS was previously invisible. Drops were logged; lines the
    /// thresholds let through left no trace, so "sometimes it still duplicates"
    /// could only be answered by guessing at numbers. A near-miss log turns the
    /// next occurrence into a measurement.
    static func closestScore(_ candidate: TranscriptEntry,
                             of recent: [TranscriptEntry],
                             window: TimeInterval = window) -> (score: Double, text: String)? {
        let candidateTokens = tokens(candidate.text)
        guard candidateTokens.count >= fuzzyMinimumTokens else { return nil }

        var best: (score: Double, text: String)?
        for existing in recent.reversed() {
            let age = candidate.timestamp.timeIntervalSince(existing.timestamp)
            if age > window { break }
            if age < -window { continue }
            let existingTokens = tokens(existing.text)
            guard existingTokens.count >= fuzzyMinimumTokens else { continue }
            let score = similarity(candidateTokens, existingTokens)
            if best == nil || score > best!.score { best = (score, existing.text) }
        }
        return best
    }

    /// Drop a mic provisional that echoes the system provisional. Both tracks
    /// transcribe the same sound while someone remote is talking (speakers →
    /// mic), so the SAME in-progress sentence rendered twice — once dimmed per
    /// track — until the finals arrived and the entry-level dedup caught it.
    /// The system copy wins: it heard the cleaner signal. Both lines are
    /// PARTIAL hypotheses of different lengths, so containment counts as an
    /// echo, not just whole-line similarity.
    static func withoutEchoedProvisionals(_ lines: [ProvisionalLine]) -> [ProvisionalLine] {
        guard let system = lines.first(where: { $0.source == .system }),
              let mic = lines.firstIndex(where: { $0.source == .mic }) else { return lines }
        let systemTokens = tokens(system.text)
        let micTokens = tokens(lines[mic].text)
        guard micTokens.count >= fuzzyMinimumTokens, systemTokens.count >= fuzzyMinimumTokens else {
            return lines
        }
        let echoed = similarity(micTokens, systemTokens) >= crossTrackSimilarityThreshold
            || isClippedRepeat(micTokens, systemTokens)
            || characterSimilarity(normalizedCharacters(lines[mic].text),
                                   normalizedCharacters(system.text))
                >= crossTrackCharacterThreshold
        guard echoed else { return lines }
        var kept = lines
        kept.remove(at: mic)
        return kept
    }

    /// Remove a cumulative acoustic echo from the start of a microphone
    /// hypothesis/final. The comparison target is the concatenated recent
    /// system transcript, not one entry at a time.
    ///
    /// Returning the unmodified input means no strong echo prefix was found;
    /// returning `""` means the whole candidate was echo. If the user starts
    /// speaking after the echoed playback, only that genuinely novel suffix is
    /// returned. The match is token/sequence based, so Cyrillic and other
    /// Unicode-letter scripts work without an English-only tokenizer.
    static func removingCumulativeCrossTrackEcho(
        from text: String,
        source: TranscriptSource,
        recent: [TranscriptEntry],
        at timestamp: Date = Date()
    ) -> String {
        // Speaker output leaks into the physical microphone. Applying this in
        // the reverse direction could erase a real remote response that quotes
        // the local user, so the rule is intentionally asymmetric.
        guard source == .mic else { return text }

        let systemWindow = recent
            .filter {
                $0.source == .system
                    && timestamp.timeIntervalSince($0.timestamp) >= 0
                    && timestamp.timeIntervalSince($0.timestamp) <= cumulativeCrossTrackWindow
            }
            .suffix(32)
        // One existing entry is already handled by `isDuplicate`, whose
        // whole-utterance similarity is safer. Prefix-trimming is reserved for
        // the observed cumulative shape spanning several finalized turns; on
        // one imperfectly recognized sentence it could otherwise leave two
        // stray ASR words behind as a false novel suffix.
        guard systemWindow.count >= 2 else { return text }
        let systemTokens = systemWindow.flatMap { tokens($0.text) }
        let candidate = indexedTokens(text)
        guard systemTokens.count >= cumulativeEchoMinimumTokens,
              candidate.count >= cumulativeEchoMinimumTokens,
              systemTokens.count <= cumulativeEchoMaximumSystemTokens,
              candidate.count <= cumulativeEchoMaximumCandidateTokens else { return text }

        let matchedCandidateIndices = lcsMatchedCandidateIndices(
            systemTokens, candidate.map(\.normalized))
        guard let firstMatch = matchedCandidateIndices.first,
              firstMatch <= 2 else { return text }

        let matchedSet = Set(matchedCandidateIndices)
        var matches = 0
        var lastMatch: Int?
        var echoBoundary: Int?
        for index in candidate.indices {
            if matchedSet.contains(index) {
                if let lastMatch,
                   index - lastMatch - 1 > cumulativeEchoMaximumGap,
                   echoBoundary != nil {
                    break
                }
                matches += 1
                lastMatch = index
            } else if let lastMatch,
                      index - lastMatch > cumulativeEchoMaximumGap,
                      echoBoundary != nil {
                break
            }

            let density = Double(matches) / Double(index + 1)
            if matches >= cumulativeEchoMinimumTokens,
               density >= cumulativeEchoMatchDensity,
               matchedSet.contains(index) {
                echoBoundary = index
            }
        }
        guard let echoBoundary else { return text }

        let remainder = text[candidate[echoBoundary].end...]
        return trimmingLeadingSeparators(String(remainder))
    }

    private struct IndexedToken {
        let normalized: String
        /// End of this token in the original string, used to preserve the
        /// exact spelling/punctuation of a novel suffix.
        let end: String.Index
    }

    private static func indexedTokens(_ text: String) -> [IndexedToken] {
        var result: [IndexedToken] = []
        var token = ""
        var tokenEnd = text.startIndex

        func finish() {
            guard !token.isEmpty else { return }
            result.append(IndexedToken(normalized: token.lowercased(), end: tokenEnd))
            token = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isLetter || character.isNumber {
                token.append(character)
                tokenEnd = next
            } else if character == "'" || character == "\u{2019}" {
                // Match `tokens(_:)`: apostrophes do not split a word and do
                // not contribute to its normalized spelling.
                tokenEnd = next
            } else {
                finish()
            }
            index = next
        }
        finish()
        return result
    }

    /// Recover the candidate-token side of one longest common subsequence.
    /// LCS tolerates a few acoustic-path insertions/substitutions while still
    /// requiring word order; a bag-of-words score could mistake a related but
    /// genuinely new reply for echo.
    private static func lcsMatchedCandidateIndices(
        _ system: [String], _ candidate: [String]
    ) -> [Int] {
        let columns = candidate.count + 1
        var lengths = Array(
            repeating: UInt16(0),
            count: (system.count + 1) * columns)
        for systemIndex in 1...system.count {
            for candidateIndex in 1...candidate.count {
                let offset = systemIndex * columns + candidateIndex
                if system[systemIndex - 1] == candidate[candidateIndex - 1] {
                    lengths[offset] = lengths[(systemIndex - 1) * columns + candidateIndex - 1] + 1
                } else {
                    lengths[offset] = max(
                        lengths[(systemIndex - 1) * columns + candidateIndex],
                        lengths[systemIndex * columns + candidateIndex - 1])
                }
            }
        }

        var systemIndex = system.count
        var candidateIndex = candidate.count
        var matched: [Int] = []
        while systemIndex > 0, candidateIndex > 0 {
            if system[systemIndex - 1] == candidate[candidateIndex - 1] {
                matched.append(candidateIndex - 1)
                systemIndex -= 1
                candidateIndex -= 1
            } else if lengths[(systemIndex - 1) * columns + candidateIndex]
                        >= lengths[systemIndex * columns + candidateIndex - 1] {
                systemIndex -= 1
            } else {
                candidateIndex -= 1
            }
        }
        return matched.reversed()
    }

    private static func trimmingLeadingSeparators(_ text: String) -> String {
        let firstContent = text.firstIndex { character in
            character.unicodeScalars.contains { scalar in
                CharacterSet.alphanumerics.contains(scalar)
            }
        }
        guard let firstContent else { return "" }
        return String(text[firstContent...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Jaccard overlap of the two token sets — order-insensitive, so it still
    /// matches when one transcription drops or reorders a filler word.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        let left = Set(a)
        let right = Set(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }
}
