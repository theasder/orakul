import Foundation

/// Runs the deterministic critics over saved sessions and reports the rates.
///
/// This is the objective signal reflection needs. Without it, adding a critique
/// pass is a guess: you cannot tell whether it improved the output or only cost
/// more. The corpus is free — every call the app has already recorded persists
/// its transcript alongside the blind spots, answer and digest produced from
/// it, so the harness judges real production output at zero model cost.
enum ReflectionEval {

    struct SessionScore: Equatable, Sendable {
        let id: UUID
        let title: String
        let startedAt: Date
        let tally: ReflectionTally
    }

    /// Judge one session's persisted output against its own transcript.
    static func score(_ session: SavedSession) -> SessionScore {
        let transcript = session.entries
            .map { "[\($0.source.rawValue)] \($0.text)" }
            .joined(separator: "\n")

        var tally = ReflectionTally()
        tally.merge(ReflectionCritics.judgeBlindSpots(session.suggestions ?? [], transcript: transcript))
        tally.merge(ReflectionCritics.judgeAnswer(session.aiResponse, transcript: transcript))
        // Earlier turns count too: an ungrounded quote is no less invented for
        // having been replaced by a later answer.
        for exchange in session.aiHistory ?? [] {
            tally.merge(ReflectionCritics.judgeAnswer(exchange.answer, transcript: transcript))
        }
        tally.merge(ReflectionCritics.judgeFactClaims(session.factClaims ?? [], transcript: transcript))
        tally.merge(ReflectionCritics.judgeActionItems(session.followUp))
        tally.merge(ReflectionCritics.judgeDigest(session.digest, transcript: transcript))
        // The rhetoric and facilitation notes are persisted but not judged:
        // they are free prose with no contract, and there is no rule about them
        // decidable without a model. Recording them is what makes a Tier 2
        // critic possible later; inventing a rule now would only add noise.

        return SessionScore(id: session.id, title: session.displayTitle,
                            startedAt: session.startedAt, tally: tally)
    }

    // MARK: - Do the critics agree with the user?

    /// The critics against the only ground truth the app has.
    ///
    /// A hit rate says nothing about whether the rules measure what anyone cares
    /// about: a critic that never fires scores beautifully on a corpus of
    /// useless answers. Cross-tabulating every mechanical verdict against the
    /// user's own thumb turns the rates into an instrument that can be checked —
    /// and the cell where the critics passed something the user rejected is
    /// where the next rule comes from.
    struct Agreement: Equatable, Sendable {
        /// Critics clean, user approved.
        var agreedGood = 0
        /// Critics fired, user rejected.
        var agreedBad = 0
        /// Critics clean, user rejected — the interesting cell.
        var criticsMissed = 0
        /// Critics fired, user approved — the over-strict rule.
        var overStrict = 0

        /// Answers carrying a human verdict. Unlabelled answers are not counted:
        /// treating silence as approval would inflate every rate here.
        var labelled: Int { agreedGood + agreedBad + criticsMissed + overStrict }

        /// Raw agreement, 0…1. Zero — not one — when nothing was labelled.
        var observedAgreement: Double {
            guard labelled > 0 else { return 0 }
            return Double(agreedGood + agreedBad) / Double(labelled)
        }

        /// Cohen's κ: agreement above what the two would reach by chance.
        ///
        /// Raw agreement flatters a critic that always passes when users are
        /// mostly happy — it looks like 90% accuracy and carries no information.
        /// κ is what refuses to call that a result, and returns 0 when every
        /// observation lands in a single row or column.
        var kappa: Double {
            let n = Double(labelled)
            guard n > 0 else { return 0 }
            let po = observedAgreement
            let pClean = Double(agreedGood + criticsMissed) / n
            let pHelpful = Double(agreedGood + overStrict) / n
            let pe = pClean * pHelpful + (1 - pClean) * (1 - pHelpful)
            guard abs(1 - pe) > 1e-9 else { return 0 }
            return (po - pe) / (1 - pe)
        }
    }

    /// Judges every labelled answer in the corpus and tabulates the result.
    static func agreement(for sessions: [SavedSession]) -> Agreement {
        var agreement = Agreement()
        for session in sessions {
            let transcript = session.entries
                .map { "[\($0.source.rawValue)] \($0.text)" }
                .joined(separator: "\n")

            for exchange in session.aiHistory ?? [] {
                guard let feedback = exchange.feedback else { continue }

                var tally = ReflectionCritics.judgeAnswer(
                    exchange.answer, transcript: transcript)
                for finding in ReflectionCritics.judgeAnswerContract(
                    answer: exchange.answer, promptText: exchange.prompt) {
                    tally.record(finding)
                }
                let criticsFired = !tally.findings.isEmpty

                switch (criticsFired, feedback.isHelpful) {
                case (false, true):  agreement.agreedGood += 1
                case (true, false):  agreement.agreedBad += 1
                case (false, false): agreement.criticsMissed += 1
                case (true, true):   agreement.overStrict += 1
                }
            }
        }
        return agreement
    }

    // MARK: - Aggregation

    struct RuleRate: Equatable, Sendable {
        let rule: String
        let subject: ReflectionSubject
        let hits: Int
        let judged: Int

        /// Share of judged items that broke this rule, 0…1. Zero when nothing
        /// of that kind was judged — a rate over an empty denominator is not
        /// "perfect", it is unmeasured, and the report says so.
        var rate: Double { judged == 0 ? 0 : Double(hits) / Double(judged) }
    }

    struct Summary: Equatable, Sendable {
        let sessions: Int
        let judged: [ReflectionSubject: Int]
        let rules: [RuleRate]
        let worst: [ReflectionFinding]

        var totalFindings: Int { rules.reduce(0) { $0 + $1.hits } }
    }

    static func summarize(_ scores: [SessionScore], worstLimit: Int = 10) -> Summary {
        var judged: [ReflectionSubject: Int] = [:]
        var hits: [String: (subject: ReflectionSubject, count: Int)] = [:]
        var findings: [ReflectionFinding] = []

        for score in scores {
            for (subject, count) in score.tally.judged { judged[subject, default: 0] += count }
            for finding in score.tally.findings {
                hits[finding.rule, default: (finding.subject, 0)].count += 1
                findings.append(finding)
            }
        }

        let rules = hits
            .map { RuleRate(rule: $0.key, subject: $0.value.subject,
                            hits: $0.value.count, judged: judged[$0.value.subject] ?? 0) }
            .sorted { ($0.hits, $1.rule) > ($1.hits, $0.rule) }

        return Summary(sessions: scores.count, judged: judged, rules: rules,
                       worst: Array(findings.prefix(worstLimit)))
    }

    // MARK: - Rendering

    static func render(_ summary: Summary) -> String {
        guard summary.sessions > 0 else {
            return "No sessions in the corpus — nothing judged."
        }
        var lines: [String] = []
        lines.append("Reflection eval — \(summary.sessions) session(s)")
        lines.append("")

        lines.append("Judged:")
        for subject in ReflectionSubject.allCases {
            let count = summary.judged[subject] ?? 0
            lines.append("  \(subject.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(count)")
        }
        lines.append("")

        if summary.rules.isEmpty {
            lines.append("No rule violations. Every judged item passed its own contract.")
            return lines.joined(separator: "\n")
        }

        lines.append("Violations by rule:")
        for rule in summary.rules {
            let percent = String(format: "%.1f%%", rule.rate * 100)
            lines.append("  \(rule.rule.padding(toLength: 32, withPad: " ", startingAt: 0)) "
                         + "\(rule.hits)/\(rule.judged)  \(percent)")
        }
        lines.append("")

        lines.append("Examples:")
        for finding in summary.worst {
            lines.append("  [\(finding.rule)] \(finding.detail)")
            if !finding.excerpt.isEmpty { lines.append("      \(finding.excerpt)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Judge a whole store. Returns the summary and the per-session scores, so a
    /// caller can point at the worst meeting rather than only the aggregate.
    static func run(store: SessionStore) -> (summary: Summary, scores: [SessionScore]) {
        let scores = store.list().map(score)
        return (summarize(scores), scores)
    }
}
