import Foundation
import OrakulCore

/// Cross-meeting decision recall (roadmap F1, RICE 72).
///
/// The highest-prevalence mined pain: "the part that kills me is the
/// relitigating. not the first conversation. the second one two weeks later
/// when someone brings it back up because nobody's sure what we landed on."
/// Every session on disk already holds the answer; this service makes it
/// interrogable: embed the question, score every recallable unit from saved
/// sessions, return the top hits with VERBATIM excerpts — the same evidence
/// discipline as blind spots, because a paraphrased memory of a decision is
/// how relitigation starts.
///
/// Fully on-device, through `RecallEmbedder`: Apple's sentence model for the
/// language it was built for, the language-agnostic lexical embedder for
/// everything else. No network, no credits, no model call — recall must work
/// offline and cost nothing, or nobody asks it twice.
enum DecisionRecallService {

    struct RecallHit: Equatable {
        enum Kind: String { case digest, transcript, exchange }
        let sessionID: UUID
        let sessionTitle: String
        let startedAt: Date
        let kind: Kind
        /// Verbatim slice of the stored record — quotable back to its session.
        let excerpt: String
        let score: Double
    }

    /// Cosine floor below which a hit is noise. With no shared vocabulary the
    /// hashing embedder lands near zero; NLEmbedding near-orthogonal. A wrong
    /// answer relitigates worse than no answer, so the floor errs high.
    private static let minimumScore = 0.18
    /// Transcript windowing: enough context to quote a whole spoken sentence,
    /// small enough that one window holds one thought.
    private static let windowSize = 220
    private static let windowStride = 160
    /// Hard ceiling on one excerpt.
    ///
    /// Excerpts are quoted into the model request by `DecisionRecallContext`,
    /// and a digest paragraph has no natural length — a meeting summary written
    /// without blank lines is ONE paragraph, so an uncapped excerpt could push
    /// tens of kilobytes of somebody's old meeting into every recall question,
    /// silently, on their credits. Truncating keeps the quote verbatim (it is
    /// still a slice of the record) and keeps embedding cheap, since the
    /// sentence model's cost scales with input length.
    static let maxExcerptCharacters = 400
    /// Per-session cap keeps a three-hour recording from drowning the index.
    private static let maxWindowsPerSession = 160
    /// How many sessions survive the cheap first pass and get embedded properly.
    ///
    /// Measured before this existed: scoring every unit of 250 sessions with
    /// the sentence model took 183 SECONDS on the ask path, and 284s for the
    /// pre-call brief. The model serialises its CoreNLP calls behind a lock, so
    /// that cost does not parallelise away — recall was unusable for anyone
    /// with a year of meetings, which is precisely the person it is for.
    private static let maxSessionsScored = 12
    /// Words that appear in every meeting and identify none of them.
    private static let shortlistStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "with", "to", "on", "in",
        "we", "our", "us", "you", "it", "is", "are", "was", "were", "be",
        "what", "when", "why", "who", "did", "do", "does", "about", "that",
        "this", "there", "then", "so", "at", "by", "from", "as", "if",
        "decide", "decided", "decision", "agree", "agreed", "meeting", "call",
    ]
    /// Lexical prescreen reads this much of a session. Long enough to catch a
    /// decision made anywhere in an hour-long call; short enough that 250 of
    /// them are still one cheap pass.
    private static let shortlistCharacters = 4_000

    private struct Unit {
        let kind: RecallHit.Kind
        let text: String
        /// Tokenised once at construction. The same passage is scored by the
        /// unit prescreen and again by the hybrid ranker, and tokenising it per
        /// use put recall back over its interactive budget for no benefit.
        let tokens: Set<String>

        init(kind: RecallHit.Kind, text: String) {
            self.kind = kind
            self.text = text
            self.tokens = DecisionRecallService.tokens(in: text)
        }
    }

    static func recall(query: String,
                       store: SessionStore = .shared,
                       embedder: any SkillTextEmbedder = RecallEmbedder.production,
                       limit: Int = 6) -> [RecallHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let queryVector = embedder.embed(trimmed) else { return [] }
        let queryTokens = tokens(in: trimmed)

        var hits: [RecallHit] = []
        for session in shortlist(for: trimmed, in: store.list()) {
            var best: (unit: Unit, score: Double)?
            for unit in likelyUnits(of: session, matching: trimmed) {
                guard let vector = embedder.embed(unit.text) else { continue }
                // Hybrid, and the lexical half is not a tie-breaker.
                //
                // Measured on 250 sessions: pure cosine could not find a
                // meeting whose digest said "raise the Series B at a 90 million
                // post-money valuation" when asked "what did we decide about
                // the Series B valuation" — a one-line record loses to pages of
                // vaguely-related discussion, because a sentence embedding
                // rewards topical resemblance and a recall question is asking
                // about a NAME. Adding the share of the question's distinctive
                // words that the passage actually contains fixes exactly that,
                // and costs nothing: the tokens are already computed.
                let lexical = lexicalOverlap(queryTokens, unit.tokens)
                let score = VectorMath.cosineSimilarity(queryVector, vector) + lexicalWeight * lexical
                if score > (best?.score ?? minimumScore) {
                    best = (unit, score)
                }
            }
            if let best {
                hits.append(RecallHit(sessionID: session.id,
                                      sessionTitle: session.displayTitle,
                                      startedAt: session.startedAt,
                                      kind: best.unit.kind,
                                      excerpt: best.unit.text,
                                      score: best.score))
            }
        }
        return hits
            .sorted { ($0.score, $0.startedAt.timeIntervalSince1970)
                    > ($1.score, $1.startedAt.timeIntervalSince1970) }
            .prefix(limit)
            .map { $0 }
    }

    /// How many units inside a shortlisted session get the good embedder.
    ///
    /// The same two-stage argument one level down: an hour-long call windows
    /// into ~20 passages, and the sentence model costs ~15 ms each. Ranking
    /// them lexically first and embedding only the plausible few is what turns
    /// recall from a coffee break into an answer.
    private static let maxUnitsPerSession = 4

    /// The passages of one session most likely to answer the question, by the
    /// cheap embedder. Under the cap every unit is returned unchanged.
    private static func likelyUnits(of session: SavedSession, matching query: String) -> [Unit] {
        let all = units(of: session)
        guard all.count > maxUnitsPerSession else { return all }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return Array(all.prefix(maxUnitsPerSession)) }
        return all
            .map { unit -> (unit: Unit, score: Double) in
                return (unit, Double(queryTokens.intersection(unit.tokens).count))
            }
            .sorted { $0.score > $1.score }
            .prefix(maxUnitsPerSession)
            .map(\.unit)
    }

    /// The sessions worth embedding properly, chosen by a cheap lexical pass.
    ///
    /// Two-stage retrieval, for the ordinary reason: the good embedder is far
    /// too slow to run over everything, and a bag-of-tokens score is more than
    /// good enough to rule out the meetings that never mention the subject. A
    /// recall question and its answer share vocabulary — people ask about
    /// "pricing" using the word "pricing" — which is exactly the case lexical
    /// matching handles well.
    ///
    /// Under the cap, every session is returned and the behaviour is identical
    /// to scoring everything.
    private static func shortlist(for query: String, in sessions: [SavedSession]) -> [SavedSession] {
        guard sessions.count > maxSessionsScored else { return sessions }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return Array(sessions.prefix(maxSessionsScored)) }

        return sessions
            .map { session -> (session: SavedSession, score: Double) in
                var blob = "\(session.displayTitle)\n\(session.digest)"
                if blob.count < shortlistCharacters {
                    blob += "\n" + session.entries.map(\.text).joined(separator: " ")
                }
                let sessionTokens = tokens(in: String(blob.prefix(shortlistCharacters)))
                // Share of the QUESTION's distinctive words this meeting
                // contains. Not cosine over a 64-dimension hash: measured on
                // 250 sessions, that lost the right meeting entirely — hash
                // collisions let long filler documents outrank the one session
                // that actually said "Series B post-money". Rare words are the
                // whole signal in a recall question, so count them directly.
                let overlap = queryTokens.intersection(sessionTokens).count
                return (session, Double(overlap) / Double(queryTokens.count))
            }
            .sorted { ($0.score, $0.session.startedAt.timeIntervalSince1970)
                    > ($1.score, $1.session.startedAt.timeIntervalSince1970) }
            .prefix(maxSessionsScored)
            .map(\.session)
    }

    /// How much the exact wording matters against topical resemblance. High
    /// enough that a passage containing the question's rare words beats one
    /// that merely sounds related; low enough that it cannot promote a passage
    /// with no semantic connection at all.
    private static let lexicalWeight = 0.5

    private static func lexicalOverlap(_ queryTokens: Set<String>, _ unitTokens: Set<String>) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        return Double(queryTokens.intersection(unitTokens).count) / Double(queryTokens.count)
    }

    /// Lowercased alphanumeric words, minus the ones every meeting contains.
    static func tokens(in text: String) -> Set<String> {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(String(cleaned).split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !shortlistStopwords.contains($0) }
            // Термин словаря приводится к канону, иначе половины запроса не
            // сходятся: расшифровку канонизируют при сохранении («промпт»), а
            // запрос — нет, и человек, ищущий `prompt` (то самое слово, которое
            // он произнёс, и то, которым его пишет половина движков), не
            // находит ничего.
            //
            // Для русского запроса это и есть весь поиск: вторая половина —
            // эмбеддинг системной модели macOS, а она англоязычная и на русский
            // текст отвечает бессмысленным вектором (см. README, «Почему это
            // устроено именно так»).
            // Один и тот же шаг, что и в командной строке: сначала термин,
            // потом его падеж. Раньше он был написан здесь второй раз, и
            // кросс-алфавитный поиск с падежами чинились в обеих копиях.
            .map { RecallIndex.searchToken(for: $0) })
    }

    /// The recallable units of one session, best-first by information density:
    /// digest paragraphs (the confirmed record), AI exchanges (asked and
    /// answered once already), then transcript windows (the raw floor).
#if DEBUG
    /// Куски одного звонка, как их видит поиск. Только для тестов: `units`
    /// приватна намеренно, а проверять надо именно то, что уходит в поиск —
    /// в частности, доходит ли до цитаты имя говорящего.
    static func unitsForTesting(of session: SavedSession) -> [(text: String, isTranscript: Bool)] {
        units(of: session).map { ($0.text, $0.kind == .transcript) }
    }
#endif

    private static func units(of session: SavedSession) -> [Unit] {
        var units: [Unit] = []

        for paragraph in session.digest.components(separatedBy: "\n\n")
        where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            units.append(Unit(kind: .digest, text: String(paragraph.prefix(maxExcerptCharacters))))
        }

        for exchange in session.aiHistory ?? [] {
            let text = "\(exchange.prompt)\n\(exchange.answer)"
            units.append(Unit(kind: .exchange, text: String(text.prefix(maxExcerptCharacters))))
        }

        // Со speaker'ом, а не только текстом. Раньше реплики склеивались через
        // пробел, и цитата приходила без имени — а хуже того, окно могло
        // накрыть двух говорящих сразу, и слова одного читались как слова
        // другого. Продукт обещает ответ цитатой из звонка; цитата, которую
        // нельзя никому приписать, это обещание не выполняет.
        let transcript = session.entries
            .map { entry in
                entry.speaker.map { "\($0): \(entry.text)" } ?? entry.text
            }
            .joined(separator: "\n")
        if !transcript.isEmpty {
            var start = transcript.startIndex
            var produced = 0
            while start < transcript.endIndex, produced < maxWindowsPerSession {
                let end = transcript.index(start, offsetBy: windowSize,
                                           limitedBy: transcript.endIndex) ?? transcript.endIndex
                let window = String(transcript[start..<end])
                if !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(Unit(kind: .transcript, text: window))
                    produced += 1
                }
                guard let next = transcript.index(start, offsetBy: windowStride,
                                                  limitedBy: transcript.endIndex) else { break }
                start = next
            }
        }
        return units
    }
}
