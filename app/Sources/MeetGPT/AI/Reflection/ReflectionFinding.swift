import Foundation

/// Which produced-output a finding is about. One case per workflow that can be
/// judged from what a session persists — nothing here needs a model call.
enum ReflectionSubject: String, Codable, CaseIterable, Sendable {
    case blindSpot
    case answer
    case digest
    case factClaim
    case actionItem
}

/// A single rule a produced output broke.
///
/// Deliberately not an error: most findings describe output the user already
/// saw and acted on. They are measurements, and the point is the RATE — how
/// often a workflow emits something its own contract says it should not.
struct ReflectionFinding: Equatable, Sendable {
    /// The rule's stable id, e.g. `blindSpot.evidenceMissing`. Rates are
    /// reported per rule, so this string is the unit of comparison across runs.
    let rule: String
    let subject: ReflectionSubject
    /// What was wrong, in one line.
    let detail: String
    /// The offending text, trimmed for a report. Never the whole transcript.
    let excerpt: String

    init(rule: String, subject: ReflectionSubject, detail: String, excerpt: String = "") {
        self.rule = rule
        self.subject = subject
        self.detail = detail
        self.excerpt = ReflectionFinding.clip(excerpt)
    }

    /// Report lines are read in a terminal; a 4,000-character quote is noise.
    static func clip(_ text: String, limit: Int = 120) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)) + "…"
    }
}

/// Everything judged for one session, plus how many items were judged.
///
/// The denominators travel with the findings on purpose: "12 ungrounded blind
/// spots" means nothing without "out of how many", and a report that loses the
/// denominator turns a quiet release into a false alarm.
struct ReflectionTally: Equatable, Sendable {
    var judged: [ReflectionSubject: Int] = [:]
    var findings: [ReflectionFinding] = []

    mutating func judge(_ subject: ReflectionSubject, count: Int = 1) {
        judged[subject, default: 0] += count
    }

    mutating func record(_ finding: ReflectionFinding) {
        findings.append(finding)
    }

    mutating func merge(_ other: ReflectionTally) {
        for (subject, count) in other.judged { judged[subject, default: 0] += count }
        findings.append(contentsOf: other.findings)
    }
}
