import Foundation

/// Does one merged call answer as well as two separate ones?
///
/// Not decidable by argument, so this decides it by replay: take recorded
/// sessions, rebuild the exact windows the live loop would have judged, and run
/// both variants over each one. Same model, same transcript, same
/// post-processing — the only difference is one call or two.
///
/// What it measures, in the order the risks matter:
///
///  - SILENCE. Each watch says nothing most of the time, and a false note in a
///    live call is worse than no note. If merged fills a slot where separate
///    stayed quiet, the merge costs precision no matter what else it buys.
///  - AGREEMENT. When both speak, do they flag the same thing? Disagreement is
///    not automatically wrong, but it means the merge changed the answer.
///  - COLLAPSE. Both prompts ask for the single most important issue; a merged
///    reply that puts one theme in both slots has silently become one watch.
///  - FAILURE. One malformed reply loses both notes; two calls lose one.
struct WatchABExperiment {

    /// How much two free-text verdicts must overlap to count as the same
    /// finding. Looser than card dedup: these are sentences from two separate
    /// runs, not two cards competing for one slot in a list.
    static let agreementOverlap = 0.45

    /// One replayed moment: what the live loop would have sent.
    struct Window: Equatable, Sendable {
        let sessionTitle: String
        let goal: String
        let transcript: String
        /// Seconds into the call, so a report can point at when it happened.
        let offset: TimeInterval
    }

    struct Observation: Equatable, Sendable {
        let window: Window
        let separateRhetoric: String?
        let separateFacilitation: String?
        let merged: MergedWatch.Verdicts
        /// True when the merged reply could not be parsed at all — the failure
        /// mode that costs both notes instead of one.
        let mergedUnparsable: Bool
    }

    // MARK: - Replay

    /// Rebuild the windows the live loop would have judged.
    ///
    /// Faithful to the running system rather than to a round number: the 300 s
    /// cadence, the `minimumNewCharacters` coalescing gate that skips a tick
    /// when too little was said, and `promptTranscript`'s tail cap. Windows
    /// invented on any other rule would measure a product that does not exist.
    static func windows(for session: SavedSession,
                        cadence: TimeInterval = Double(CopilotCadence.facilitationSeconds),
                        cap: Int = 6_000,
                        minimumNew: Int = BackgroundSpendPolicy.minimumNewCharacters,
                        limit: Int = 12) -> [Window] {
        let entries = session.entries.sorted { $0.timestamp < $1.timestamp }
        guard let first = entries.first?.timestamp, entries.count >= 4 else { return [] }

        var result: [Window] = []
        var charactersAtLastRun: Int?
        var tick = 1

        while result.count < limit {
            let mark = first.addingTimeInterval(cadence * Double(tick))
            let upTo = entries.filter { $0.timestamp <= mark }
            guard upTo.count >= 4 else {
                if mark > (entries.last?.timestamp ?? first) { break }
                tick += 1
                continue
            }
            let text = upTo.map { "[\($0.source.rawValue)] \($0.text)" }.joined(separator: "\n")
            if BackgroundSpendPolicy.shouldRun(totalCharacters: text.count,
                                               charactersAtLastRun: charactersAtLastRun,
                                               minimumNew: minimumNew) {
                charactersAtLastRun = text.count
                result.append(Window(sessionTitle: session.displayTitle,
                                     goal: session.goal,
                                     transcript: String(text.suffix(cap)),
                                     offset: cadence * Double(tick)))
            }
            if mark > (entries.last?.timestamp ?? first) { break }
            tick += 1
        }
        return result
    }

    // MARK: - Run

    /// Run both variants over one window. Separate first, merged second, so a
    /// rate-limited run degrades to "separate only" rather than to nothing.
    static func observe(_ window: Window,
                        gateway: LLMGateway,
                        model: LLMModel) async -> Observation {
        let rhetoricRaw = try? await gateway.streamChat(
            system: RhetoricWatch.systemPrompt,
            user: "Recent transcript:\n\(window.transcript)",
            model: model) { _ in }
        let facilitationRaw = try? await gateway.streamChat(
            system: FacilitationWatch.systemPrompt,
            user: FacilitationWatch.userPrompt(goal: window.goal, transcript: window.transcript),
            model: model) { _ in }
        let mergedRaw = try? await gateway.streamChat(
            system: MergedWatch.systemPrompt,
            user: MergedWatch.userPrompt(goal: window.goal, transcript: window.transcript),
            model: model) { _ in }

        let merged = MergedWatch.parse(mergedRaw ?? "")
        let unparsable = (mergedRaw.map { MergedWatch.extractJSONObject($0) == nil } ?? true)

        return Observation(
            window: window,
            separateRhetoric: RhetoricWatch.parse(rhetoricRaw ?? ""),
            separateFacilitation: FacilitationWatch.parse(facilitationRaw ?? ""),
            merged: merged,
            mergedUnparsable: unparsable)
    }

    // MARK: - Score

    struct Score: Equatable, Sendable {
        var windows = 0
        /// Times the variant produced a note, per track.
        var separateSpoke = 0
        var mergedSpoke = 0
        /// Merged spoke where separate stayed silent — the precision risk.
        var mergedSpokeAlone = 0
        /// Separate spoke where merged stayed silent — coverage lost.
        var separateSpokeAlone = 0
        /// Both spoke and flagged the same thing.
        var agreed = 0
        /// Both spoke about different things.
        var disagreed = 0
        /// Merged put one theme in both slots.
        var collapsed = 0
        /// Merged reply could not be parsed — both notes lost at once.
        var unparsable = 0

        /// Share of judged tracks where merged invented a note. The number that
        /// should decide the merge: a live call tolerates silence, not noise.
        var falseSpeechRate: Double {
            windows == 0 ? 0 : Double(mergedSpokeAlone) / Double(windows * 2)
        }

        var agreementRate: Double {
            let spokeTogether = agreed + disagreed
            return spokeTogether == 0 ? 0 : Double(agreed) / Double(spokeTogether)
        }
    }

    static func score(_ observations: [Observation]) -> Score {
        var score = Score()
        for observation in observations {
            score.windows += 1
            if observation.mergedUnparsable { score.unparsable += 1 }

            let pairs = [
                (observation.separateRhetoric, observation.merged.rhetoric),
                (observation.separateFacilitation, observation.merged.facilitation)
            ]
            for (separate, merged) in pairs {
                if separate != nil { score.separateSpoke += 1 }
                if merged != nil { score.mergedSpoke += 1 }
                switch (separate, merged) {
                case (nil, .some):
                    score.mergedSpokeAlone += 1
                case (.some, nil):
                    score.separateSpokeAlone += 1
                case let (.some(a), .some(b)):
                    // Same claim, reworded, counts as agreement — two variants
                    // are not expected to produce identical strings. A looser
                    // bar than card dedup on purpose: there the question is
                    // "did the user already see this?", here it is "did the two
                    // runs find the same problem?", and free-text sentences
                    // share less vocabulary than eight-word titles.
                    if ReflectionCritics.similarity(a, b) >= agreementOverlap { score.agreed += 1 }
                    else { score.disagreed += 1 }
                default:
                    break
                }
            }

            if let rhetoric = observation.merged.rhetoric,
               let facilitation = observation.merged.facilitation,
               ReflectionCritics.nearDuplicate(rhetoric, facilitation) {
                score.collapsed += 1
            }
        }
        return score
    }

    // MARK: - Report

    static func render(_ score: Score) -> String {
        guard score.windows > 0 else { return "No windows replayed — nothing to compare." }
        var lines: [String] = []
        lines.append("Watch A/B — \(score.windows) window(s), 2 tracks each")
        lines.append("")
        lines.append("  separate spoke        \(score.separateSpoke)/\(score.windows * 2)")
        lines.append("  merged spoke          \(score.mergedSpoke)/\(score.windows * 2)")
        lines.append("  merged spoke ALONE    \(score.mergedSpokeAlone)   "
                     + String(format: "(%.1f%% of tracks — invented notes)", score.falseSpeechRate * 100))
        lines.append("  separate spoke ALONE  \(score.separateSpokeAlone)   (coverage merged lost)")
        lines.append("  agreed                \(score.agreed)")
        lines.append("  disagreed             \(score.disagreed)   "
                     + String(format: "(agreement %.1f%%)", score.agreementRate * 100))
        lines.append("  theme collapse        \(score.collapsed)   (one issue in both slots)")
        lines.append("  unparsable merged     \(score.unparsable)   (both notes lost)")
        lines.append("")
        lines.append(verdict(score))
        return lines.joined(separator: "\n")
    }

    /// A stated bar, set before the numbers are known so the result cannot be
    /// read to taste. Merging is a coverage trade, not a cost one — under
    /// rotation it saves no credits — so it has to be close to free on quality.
    static func verdict(_ score: Score) -> String {
        if score.windows < 8 {
            return "VERDICT: not enough windows to decide (want 8+)."
        }
        if score.unparsable > 0 {
            return "VERDICT: reject — a merged reply failed to parse, which costs both notes."
        }
        if score.falseSpeechRate > 0.10 {
            return String(format:
                "VERDICT: reject — merged invented notes on %.1f%% of tracks (bar: 10%%).",
                score.falseSpeechRate * 100)
        }
        if score.collapsed * 4 > score.windows {
            return "VERDICT: reject — merged collapsed both tracks onto one theme too often."
        }
        if score.agreementRate < 0.6 {
            return String(format:
                "VERDICT: reject — merged agreed with separate only %.1f%% of the time (bar: 60%%).",
                score.agreementRate * 100)
        }
        return "VERDICT: accept — merged holds quality; take the coverage (15 min -> 10 min per track)."
    }
}
