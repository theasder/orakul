import Foundation
@testable import MeetGPT

/// Scoring for the diarization measurement: does the pass put the right words
/// on the right person?
///
/// The existing harness asks only "did it find exactly two voices". That is a
/// necessary question and not a sufficient one — a pass can count two speakers
/// and still swap them halfway through, which reads to a user as the transcript
/// confidently lying about who committed to what. Ground-truth conversations
/// carry per-turn labels, so the answerable question becomes: of all the speech
/// time in this call, how much was attributed to the right person?
///
/// Speaker IDs are arbitrary, so scoring maps hypothesis labels onto reference
/// labels the way that flatters the model most, then measures what is left. A
/// pass that finds both people and simply names them the other way round scores
/// 100%, because that IS a correct diarization. A pass that finds five voices in
/// a two-person call cannot map three of them and eats the loss.
///
/// Pure, and unit-tested in `DiarizationScoringTests` without CoreML.
enum DiarizationScoring {

    struct Interval: Equatable {
        let start: Double
        let end: Double
        let speaker: String

        var duration: Double { max(0, end - start) }

        func overlap(with other: Interval) -> Double {
            max(0, min(end, other.end) - max(start, other.start))
        }
    }

    struct Result {
        /// Share of reference speech time given to the right speaker, 0...1.
        let accuracy: Double
        /// Which hypothesis label was read as which reference label.
        let mapping: [String: String]
        let referenceSpeakers: Int
        let hypothesisSpeakers: Int
        let referenceSeconds: Double
    }

    /// Tab-separated `start<TAB>end<TAB>speaker`, seconds from file start.
    static func parseGroundTruth(_ text: String) -> [Interval] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 3,
                  let start = Double(parts[0]), let end = Double(parts[1]),
                  end > start else { return nil }
            return Interval(start: start, end: end,
                            speaker: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    static func intervals(from segments: [SpeakerSegment]) -> [Interval] {
        segments.map {
            Interval(start: Double($0.startSeconds), end: Double($0.endSeconds),
                     speaker: $0.speakerID)
        }
    }

    /// Time-weighted attribution accuracy under the best label mapping.
    ///
    /// Greedy on the overlap matrix, largest cell first, one-to-one: at the two
    /// to five speakers this is ever pointed at, greedy and optimal agree, and
    /// greedy cannot blow up on a pass that hallucinates twenty voices.
    static func attribution(reference: [Interval], hypothesis: [Interval]) -> Result {
        let referenceSeconds = reference.reduce(0) { $0 + $1.duration }
        let referenceSpeakers = Set(reference.map(\.speaker))
        let hypothesisSpeakers = Set(hypothesis.map(\.speaker))
        guard referenceSeconds > 0 else {
            return Result(accuracy: 0, mapping: [:],
                          referenceSpeakers: referenceSpeakers.count,
                          hypothesisSpeakers: hypothesisSpeakers.count,
                          referenceSeconds: 0)
        }

        var overlaps: [String: [String: Double]] = [:]   // hypothesis -> reference -> seconds
        for hypothesisInterval in hypothesis {
            for referenceInterval in reference {
                let shared = hypothesisInterval.overlap(with: referenceInterval)
                guard shared > 0 else { continue }
                overlaps[hypothesisInterval.speaker, default: [:]][
                    referenceInterval.speaker, default: 0] += shared
            }
        }

        var cells: [(hypothesis: String, reference: String, seconds: Double)] = []
        for (hypothesisSpeaker, byReference) in overlaps {
            for (referenceSpeaker, seconds) in byReference {
                cells.append((hypothesisSpeaker, referenceSpeaker, seconds))
            }
        }
        // Ties broken by name so the same corpus always scores the same.
        cells.sort {
            $0.seconds != $1.seconds
                ? $0.seconds > $1.seconds
                : ($0.hypothesis, $0.reference) < ($1.hypothesis, $1.reference)
        }

        var mapping: [String: String] = [:]
        var claimedReferences = Set<String>()
        var matched = 0.0
        for cell in cells {
            guard mapping[cell.hypothesis] == nil,
                  !claimedReferences.contains(cell.reference) else { continue }
            mapping[cell.hypothesis] = cell.reference
            claimedReferences.insert(cell.reference)
            matched += cell.seconds
        }

        return Result(accuracy: min(1, matched / referenceSeconds),
                      mapping: mapping,
                      referenceSpeakers: referenceSpeakers.count,
                      hypothesisSpeakers: hypothesisSpeakers.count,
                      referenceSeconds: referenceSeconds)
    }

    /// What a reader would see: the share of transcript LINES named correctly.
    ///
    /// The product never shows raw diarizer turns. `SpeakerAssignment.apply`
    /// gives each transcript line the speaker whose turn overlaps it most, so a
    /// half-second spurious voice inside a four-second line is outvoted and
    /// never reaches the screen. Scoring raw turns therefore charges the model
    /// for errors the product already absorbs — the right question for a ship
    /// decision is how many LINES carry the wrong name.
    ///
    /// Lines are a fixed grid of `lineDuration`, matching
    /// `SpeakerAssignment.defaultLineDuration`, and the same max-overlap rule
    /// picks both the true speaker and the predicted one. Lines where the
    /// reference is silent are skipped: nobody spoke, so there is no name to
    /// get wrong.
    static func lineAccuracy(reference: [Interval],
                             hypothesis: [Interval],
                             lineDuration: Double = 4) -> Double {
        guard lineDuration > 0,
              let span = reference.map(\.end).max(), span > 0 else { return 0 }

        // One global mapping, from the same overlap arithmetic as `attribution`:
        // speaker identity has to be consistent across the whole call, not
        // re-chosen per line, or a pass that alternates at random scores 100%.
        let mapping = attribution(reference: reference, hypothesis: hypothesis).mapping

        func dominant(_ intervals: [Interval], from: Double, to: Double) -> String? {
            var best: String?
            var bestOverlap = 0.0
            let line = Interval(start: from, end: to, speaker: "")
            for interval in intervals {
                let overlap = interval.overlap(with: line)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = interval.speaker
                }
            }
            return best
        }

        var lines = 0
        var correct = 0
        var start = 0.0
        while start < span {
            let end = min(start + lineDuration, span)
            defer { start += lineDuration }
            guard let truth = dominant(reference, from: start, to: end) else { continue }
            lines += 1
            if let predicted = dominant(hypothesis, from: start, to: end),
               mapping[predicted] == truth {
                correct += 1
            }
        }
        return lines == 0 ? 0 : Double(correct) / Double(lines)
    }
}
