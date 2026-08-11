import Foundation

/// Deterministic critics — the free tier of reflection.
///
/// Andrew Ng's reflection pattern is a model criticising its own output and
/// revising it. The expensive half is the criticism, and for most of what this
/// app emits the criticism does not need a model at all: a blind spot either
/// quotes something that was said or it does not, and a quote either appears in
/// the transcript or it does not. Those checks are decidable in code, cost
/// nothing, and are the only kind that may run inside the 90–120 s background
/// loops — one Pro hour already burns 204 of a 250-credit monthly allowance
/// (see `BackgroundSpendPolicy`), so a critic that spends a call there would
/// halve the plan's usable minutes.
///
/// Every rule here judges output the app ALREADY produced and persisted, which
/// is what makes the eval harness free to run: the corpus is the user's own
/// session history.
enum ReflectionCritics {

    // MARK: - Blind spots

    /// Titles this similar are the same card said twice.
    ///
    /// Production dedupes on an exact lowercased title (`AppState`), so
    /// "Budget owner is unnamed" and "No owner named for the budget" both ship.
    /// This measures what that gate lets through.
    static let duplicateTitleOverlap = 0.6

    /// A hunch claims something the call has NOT said, so — alone among the
    /// kinds — it cannot be required to quote the transcript.
    static func requiresEvidence(_ kind: SuggestionKind) -> Bool {
        kind != .hypothesis
    }

    static func judgeBlindSpots(_ suggestions: [Suggestion], transcript: String) -> ReflectionTally {
        var tally = ReflectionTally()
        var kept: [Suggestion] = []

        for suggestion in suggestions {
            tally.judge(.blindSpot)

            let evidence = suggestion.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if requiresEvidence(suggestion.kind) {
                if evidence.isEmpty {
                    tally.record(ReflectionFinding(
                        rule: "blindSpot.evidenceMissing",
                        subject: .blindSpot,
                        detail: "\(suggestion.kind.rawValue) card carries no supporting quote",
                        excerpt: suggestion.title))
                } else if !SuggestionGrounding.contains(evidence: evidence, in: transcript) {
                    // The same rule the live parser applies. A hit here means a
                    // card shipped whose quote is not in the transcript it was
                    // supposedly read from.
                    tally.record(ReflectionFinding(
                        rule: "blindSpot.evidenceUngrounded",
                        subject: .blindSpot,
                        detail: "quote does not appear in the transcript",
                        excerpt: evidence))
                }
            }

            if let twin = kept.first(where: { nearDuplicate($0.title, suggestion.title) }) {
                tally.record(ReflectionFinding(
                    rule: "blindSpot.nearDuplicate",
                    subject: .blindSpot,
                    detail: "repeats an earlier card — “\(ReflectionFinding.clip(twin.title, limit: 60))”",
                    excerpt: suggestion.title))
            }

            if suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tally.record(ReflectionFinding(
                    rule: "blindSpot.titleEmpty",
                    subject: .blindSpot,
                    detail: "card has no title",
                    excerpt: suggestion.detail))
            }

            kept.append(suggestion)
        }
        return tally
    }

    /// Word-overlap similarity (Jaccard) on normalized titles, 0…1. Cheap, no
    /// embeddings, and stable enough for a rate: a measure this blunt will miss
    /// paraphrases that share no vocabulary, so rates built on it are a FLOOR,
    /// never an overcount.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = significantWords(lhs)
        let right = significantWords(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(left.intersection(right).count) / Double(union)
    }

    static func nearDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        similarity(lhs, rhs) >= duplicateTitleOverlap
    }

    /// Words that carry the meaning of a card title. Stop words are dropped
    /// because "the" and "is" would inflate overlap between unrelated cards.
    static func significantWords(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "to", "of",
            "for", "on", "in", "at", "by", "with", "and", "or", "but", "no", "not",
            "has", "have", "had", "it", "its", "this", "that", "there", "their"
        ]
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        // Crude plural stemming. Without it "number" and "numbers" are two
        // different words, and two phrasings of the same claim score as
        // unrelated — which reads as disagreement when it is rewording.
        return Set(words
            .filter { $0.count > 2 && !stop.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    // MARK: - Assistant answers

    /// Quoted spans in an answer must be things somebody actually said.
    ///
    /// This is the one hallucination a meeting assistant cannot be allowed:
    /// inventing a sentence and attributing it to the call. `ArtifactValidator`
    /// already enforces it for structured buttons; every other prompt ships
    /// unchecked, and this measures that gap.
    /// Did the answer honour the output shape its prompt asked for?
    ///
    /// Grounding rules cannot see this failure: an answer can quote perfectly
    /// and still ignore the register it was given, which is the difference
    /// between a usable list and three paragraphs about the same facts.
    ///
    /// Returns findings rather than a tally so the live path can hand them
    /// straight to `RevisionPolicy` — one rule that both measures and repairs.
    static func judgeAnswerContract(answer: String, promptText: String) -> [ReflectionFinding] {
        guard PromptContract.ignoresContract(answer: answer, promptText: promptText) else {
            return []
        }
        let declared = PromptContract.declaredFields(in: promptText)
        let missing = PromptContract.missingFields(in: answer, declared: declared)
        return [ReflectionFinding(
            rule: "answer.contractIncomplete",
            subject: .answer,
            detail: "answer omits most of the requested register: "
                + missing.joined(separator: ", "),
            excerpt: answer)]
    }

    static func judgeAnswer(_ answer: String, transcript: String) -> ReflectionTally {
        var tally = ReflectionTally()
        let quotes = quotedSpans(in: answer)
        guard !quotes.isEmpty else { return tally }

        for quote in quotes {
            tally.judge(.answer)
            if !ArtifactValidator.quoteAppears(quote, in: transcript) {
                tally.record(ReflectionFinding(
                    rule: "answer.quoteUngrounded",
                    subject: .answer,
                    detail: "answer attributes a quote the transcript does not contain",
                    excerpt: quote))
            }
        }
        return tally
    }

    /// Words that mark the sentence as putting words in someone's mouth.
    ///
    /// The rule is about ATTRIBUTION, not about quotation marks. Answers quote
    /// plenty of things that were never spoken — an API error, a doc heading, a
    /// link label — and flagging those as hallucinations buries the one case
    /// that matters. Measured, not assumed: the first run of this harness
    /// reported 4/8 "ungrounded quotes" on real history, and all four were
    /// quoted fragments of a Gemini quota error.
    static let attributionCues = [
        "said", "says", "saying", "asked", "asks", "told", "tells", "agreed",
        "agrees", "mentioned", "mentions", "noted", "notes", "put it",
        "according to", "quoted", "quotes", "confirmed", "confirms",
        "raised", "argued", "claimed", "claims", "stated", "states"
    ]

    /// How far back from a quote an attribution cue still counts as governing it.
    static let attributionWindow = 80

    /// Quoted spans that the surrounding sentence attributes to the call.
    ///
    /// Recall is deliberately traded for precision: a hallucinated quote written
    /// without a cue word goes unmeasured, so the reported rate is a FLOOR. A
    /// floor that is trustworthy beats a headline number nobody believes.
    static func quotedSpans(in text: String, minimumLength: Int = 25) -> [String] {
        let pattern = "[\"“]([^\"“”]{\(minimumLength),400})[\"”]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: text) else { return nil }
            let span = String(text[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
            // A "quote" spanning several sentences is usually the model
            // formatting a heading, not attributing speech.
            guard !span.isEmpty, span.filter({ $0 == "." }).count <= 3 else { return nil }
            guard looksLikeSpeech(span) else { return nil }
            guard let whole = Range(match.range, in: text),
                  isAttributed(at: whole.lowerBound, in: text) else { return nil }
            return span
        }
    }

    /// Rejects things a person does not say out loud: URLs, file paths, API
    /// identifiers, single tokens.
    static func looksLikeSpeech(_ span: String) -> Bool {
        let lowered = span.lowercased()
        if lowered.contains("://") || lowered.contains("www.") { return false }
        if span.contains("_") || span.contains("/") { return false }
        let words = span.split(whereSeparator: \.isWhitespace)
        if words.count < 4 { return false }
        // camelCase / PascalCase runs are identifiers, not speech.
        let camel = words.filter { word in
            let inner = word.dropFirst()
            return inner.contains(where: { $0.isUppercase })
        }
        return camel.count * 2 < words.count
    }

    /// Whether an attribution cue appears close enough before the quote to be
    /// claiming the call said it.
    static func isAttributed(at quoteStart: String.Index, in text: String) -> Bool {
        let start = text.index(quoteStart, offsetBy: -attributionWindow,
                               limitedBy: text.startIndex) ?? text.startIndex
        let lead = text[start..<quoteStart].lowercased()
        return attributionCues.contains { lead.contains($0) }
    }

    // MARK: - Fact-check verdicts

    /// A verdict is only worth the word "verified" if it can say what verified
    /// it. The backend enforces a context-grounded source for verified and
    /// contradicted; this measures what actually reached the user, including
    /// verdicts produced by an older backend that did not.
    static func judgeFactClaims(_ claims: [FactClaim], transcript: String) -> ReflectionTally {
        var tally = ReflectionTally()
        for claim in claims {
            tally.judge(.factClaim)
            let source = claim.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch claim.status {
            case .verified, .contradicted:
                if source.isEmpty {
                    tally.record(ReflectionFinding(
                        rule: "factClaim.verdictWithoutSource",
                        subject: .factClaim,
                        detail: "\(claim.status.rawValue) with nothing cited to support it",
                        excerpt: claim.text))
                }
            case .inconsistent:
                // This verdict quotes the CALL rather than a document, so the
                // quote is checkable — and a self-contradiction the transcript
                // does not contain is the worst kind of false alarm.
                if !source.isEmpty, !SuggestionGrounding.contains(evidence: source, in: transcript) {
                    tally.record(ReflectionFinding(
                        rule: "factClaim.inconsistentSourceUngrounded",
                        subject: .factClaim,
                        detail: "cites a line of the call that is not in the transcript",
                        excerpt: source))
                }
            case .needsContext, .unverifiable:
                break   // both mean "no source exists", which is the honest answer
            }

            if claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tally.record(ReflectionFinding(
                    rule: "factClaim.empty",
                    subject: .factClaim,
                    detail: "verdict with no claim attached",
                    excerpt: claim.explanation))
            }
        }
        return tally
    }

    // MARK: - Efficiency Engine action items

    /// Below this an item is not actionable — the score already says so.
    static let weakActionItemScore = 0.5

    /// The Efficiency Engine scores every action item on owner, date and one
    /// clear ask. That scoring IS a rubric critic; it just had nowhere to go.
    /// These rules measure what it found, so "circle back scores badly" becomes
    /// a number per release instead of a claim on the landing page.
    static func judgeActionItems(_ followUp: SavedFollowUp?) -> ReflectionTally {
        var tally = ReflectionTally()
        guard let followUp else { return tally }

        for item in followUp.actionItems {
            tally.judge(.actionItem)
            if (item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
                tally.record(ReflectionFinding(
                    rule: "actionItem.noOwner",
                    subject: .actionItem,
                    detail: "nobody is named to do it",
                    excerpt: item.title))
            }
            if (item.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
                tally.record(ReflectionFinding(
                    rule: "actionItem.noDue",
                    subject: .actionItem,
                    detail: "no date, so nobody can say when it is late",
                    excerpt: item.title))
            }
            if item.score < weakActionItemScore, item.missing.isEmpty {
                // A low score with no stated reason cannot be fixed by the
                // person reading it, which is the only thing scoring is for.
                tally.record(ReflectionFinding(
                    rule: "actionItem.scoreWithoutReason",
                    subject: .actionItem,
                    detail: String(format: "scored %.2f but named nothing missing", item.score),
                    excerpt: item.title))
            }
        }
        return tally
    }

    // MARK: - Digest

    /// The digest is a running summary of the call. It has no quote contract,
    /// so the only thing decidable without a model is whether it says anything
    /// at all for a call with real material — an empty digest on a long call is
    /// a silent failure of the loop that produces it.
    static func judgeDigest(_ digest: String, transcript: String,
                            minimumTranscript: Int = 2_000) -> ReflectionTally {
        var tally = ReflectionTally()
        guard transcript.count >= minimumTranscript else { return tally }
        tally.judge(.digest)
        if digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tally.record(ReflectionFinding(
                rule: "digest.emptyOnLongCall",
                subject: .digest,
                detail: "no digest for a call with \(transcript.count) transcript characters",
                excerpt: ""))
        }
        return tally
    }
}
