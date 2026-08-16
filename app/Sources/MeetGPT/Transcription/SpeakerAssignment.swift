import Foundation

/// One remote speaker turn, in seconds from the start of retained system audio.
struct SpeakerSegment: Equatable, Sendable {
    let speakerID: String
    let startSeconds: Float
    let endSeconds: Float
}

/// Deterministically maps diarizer turns onto transcript lines.
enum SpeakerAssignment {

    static let defaultLineDuration: TimeInterval = 4
    static let localSpeakerLabel = "Вы"
    static let remoteSpeakerLabelPrefix = "Спикер "

    private static func normalizedID(_ id: String) -> String? {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Model cluster IDs are arbitrary and can change between runs. Number by
    /// first audible appearance so a rerun has predictable Спикер 2/3 labels.
    static func canonicalLabels(
        for segments: [SpeakerSegment],
        startingAt firstSpeakerNumber: Int = 1
    ) -> [String: String] {
        var firstStartByID: [String: Float] = [:]
        for segment in segments {
            guard let id = normalizedID(segment.speakerID),
                  segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds > segment.startSeconds
            else { continue }
            firstStartByID[id] = min(firstStartByID[id] ?? segment.startSeconds,
                                     segment.startSeconds)
        }

        let ordered = firstStartByID.sorted { left, right in
            if left.value == right.value { return left.key < right.key }
            return left.value < right.value
        }
        let first = max(1, firstSpeakerNumber)
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, pair in
            (pair.key, "\(remoteSpeakerLabelPrefix)\(first + index)")
        })
    }

    static func distinctSpeakers(in segments: [SpeakerSegment]) -> Int {
        canonicalLabels(for: segments).count
    }

    /// Labels known local-microphone rows as `localSpeakerLabel`, then labels
    /// remote rows by summed overlap. Named labels are protected; anonymous
    /// numeric labels from an earlier local run may be recomputed on rerun.
    static func apply(
        segments: [SpeakerSegment],
        to entries: [TranscriptEntry],
        sessionStart: Date,
        lineDuration: TimeInterval = defaultLineDuration,
        firstRemoteSpeakerNumber: Int = 1,
        localSpeakerLabel: String? = nil
    ) -> [TranscriptEntry] {
        let labels = canonicalLabels(
            for: segments,
            startingAt: firstRemoteSpeakerNumber
        )

        return entries.map { entry in
            guard canReplaceSpeaker(on: entry) else { return entry }

            if entry.source == .mic {
                guard let localSpeakerLabel else { return entry }
                return replacingSpeaker(in: entry, with: localSpeakerLabel)
            }

            guard !labels.isEmpty else { return entry }
            let from = Float(entry.timestamp.timeIntervalSince(sessionStart))
            let to = from + Float(max(0, lineDuration))
            guard from.isFinite, to.isFinite, from >= 0, to > from else { return entry }

            var intervalsByID: [String: [(start: Float, end: Float)]] = [:]
            for segment in segments {
                guard let id = normalizedID(segment.speakerID), labels[id] != nil,
                      segment.startSeconds.isFinite, segment.endSeconds.isFinite,
                      segment.startSeconds >= 0,
                      segment.endSeconds > segment.startSeconds
                else { continue }
                let overlapStart = max(from, segment.startSeconds)
                let overlapEnd = min(to, segment.endSeconds)
                if overlapEnd > overlapStart {
                    intervalsByID[id, default: []].append(
                        (start: overlapStart, end: overlapEnd))
                }
            }

            // Offline diarizers may emit overlapping windows for one cluster.
            // Count their union, not the raw sum, or duplicated model windows
            // can defeat a different person who actually held more of the line.
            let overlapByID = intervalsByID.mapValues { intervals in
                let ordered = intervals.sorted {
                    $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
                }
                guard var current = ordered.first else { return Float(0) }
                var total: Float = 0
                for interval in ordered.dropFirst() {
                    if interval.start <= current.end {
                        current.end = max(current.end, interval.end)
                    } else {
                        total += current.end - current.start
                        current = interval
                    }
                }
                return total + current.end - current.start
            }

            guard let bestID = overlapByID.max(by: { left, right in
                if left.value == right.value { return left.key > right.key }
                return left.value < right.value
            })?.key,
                  let label = labels[bestID]
            else {
                // A rerun with fewer speakers must not leave a label from the
                // previous local result on a line the new result cannot match.
                // Named/user/cloud labels remain protected by canReplaceSpeaker.
                guard entry.speaker != nil else { return entry }
                return replacingSpeaker(in: entry, with: nil)
            }
            return replacingSpeaker(in: entry, with: label)
        }
    }

    private static func canReplaceSpeaker(on entry: TranscriptEntry) -> Bool {
        guard let current = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else { return true }
        if entry.source == .mic { return current == localSpeakerLabel }
        guard current.hasPrefix(remoteSpeakerLabelPrefix),
              let number = Int(current.dropFirst(remoteSpeakerLabelPrefix.count))
        else { return false }
        return 2...5 ~= number
    }

    private static func replacingSpeaker(
        in entry: TranscriptEntry,
        with speaker: String?
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: entry.id,
            source: entry.source,
            text: entry.text,
            timestamp: entry.timestamp,
            speaker: speaker,
            transcriptionEngine: entry.transcriptionEngine
        )
    }
}
