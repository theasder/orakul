import Foundation

enum LocalFinalPassError: LocalizedError, Equatable {
    case voicedWindowProducedNoText(index: Int)

    var errorDescription: String? {
        switch self {
        case .voicedWindowProducedNoText(let index):
            return "On-device refinement returned no text for voiced window \(index + 1). The live transcript was kept."
        }
    }
}

/// Conservative post-Stop local refinement.
///
/// A single WhisperKit call over several minutes can return only a short
/// prefix even when it succeeds. This pass decodes one bounded window at a
/// time, keeps each window's capture timestamp, and replaces only the exact
/// PCM-backed interval. A voiced window with no decode fails the whole
/// transaction; a global word count is not enough to prove every window ran.
enum LocalFinalPass {
    static let sampleRate = 16_000
    /// Exact-audio sweep against the Fireflies pseudo-reference: Turbo reached
    /// WER 0.4386 / token recall 0.753 at 12 seconds, versus 0.4812 / 0.732 at
    /// six and 0.4452 / 0.753 at 30. Keep a two-second seam on top.
    static let windowSeconds: TimeInterval = 12
    static let overlapSeconds: TimeInterval = 2
    static let minimumWordCoverage = 0.90
    static let minimumLiveTokenRecall = 0.85
    static let minimumOrderedTokenRecall = 0.80
    static let maximumWordExpansion = 1.35
    static let absoluteCoverageTolerance = 1.0 / Double(sampleRate)

    struct AudioWindow: Equatable {
        let samples: [Int16]
        let startSample: Int

        var endSample: Int { startSample + samples.count }
    }

    enum Trigger: String, Equatable {
        case manual
        case automatic
    }

    enum Reason: String, Equatable {
        case accepted
        case emptyDecode = "empty_decode"
        case invalidRecordingDuration = "invalid_recording_duration"
        case invalidRetainedDuration = "invalid_retained_duration"
        case truncatedRetainedAudio = "truncated_retained_audio"
        case incompleteRetainedAudio = "incomplete_retained_audio"
        case excessRetainedAudio = "excess_retained_audio"
        case missingLiveEvidence = "missing_live_evidence"
        case mixedEngineTranscript = "mixed_engine_transcript"
        case insufficientWordCoverage = "insufficient_word_coverage"
        case excessiveWordExpansion = "excessive_word_expansion"
        case insufficientLiveTokenRecall = "insufficient_live_token_recall"
        case insufficientOrderedTokenRecall = "insufficient_ordered_token_recall"
        case missingRetainedAudio = "missing_retained_audio"
        case staleSession = "stale_session"
        case staleGeneration = "stale_generation"
        case staleTranscript = "stale_transcript"
        case decoderFailed = "decoder_failed"
        case alreadyRunning = "already_running"
        case notEligible = "not_eligible"
    }

    struct Decision: Equatable {
        let replace: Bool
        let reason: Reason
        let liveWordCount: Int
        let refinedWordCount: Int
        let audioCoverage: Double
        let liveTokenRecall: Double
        let orderedTokenRecall: Double
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
    }

    static func systemText(_ entries: [TranscriptEntry]) -> String {
        entries.filter { $0.source == .system }.map(\.text).joined(separator: " ")
    }

    /// Only Local system rows backed by this exact retained interval may be
    /// rebuilt. The upper bound is exclusive, so a live tail beginning at the
    /// first unretained sample remains byte-for-byte unchanged.
    static func localSystemInterval(
        in transcript: [TranscriptEntry],
        retainedAudioStart: Date,
        retainedAudioEnd: Date,
        replaceLocalRowsBefore: Date? = nil
    ) -> [TranscriptEntry] {
        let replacementEnd = min(replaceLocalRowsBefore ?? retainedAudioEnd,
                                 retainedAudioEnd)
        return transcript.filter {
            $0.source == .system
                && $0.transcriptionEngine == .local
                && $0.timestamp >= retainedAudioStart
                && $0.timestamp < replacementEnd
        }
    }

    static func retainedIntervalHasNonLocalSystemRows(
        _ transcript: [TranscriptEntry],
        retainedAudioStart: Date,
        retainedAudioEnd: Date
    ) -> Bool {
        transcript.contains {
            $0.source == .system
                && $0.timestamp >= retainedAudioStart
                && $0.timestamp < retainedAudioEnd
                && $0.transcriptionEngine != .local
        }
    }

    static func shouldRunAutomatically(
        enabled: Bool,
        sessionEngine: TranscriptionEngine?,
        hasUnsafeRetainedInterval: Bool
    ) -> Bool {
        enabled && sessionEngine == .local && !hasUnsafeRetainedInterval
    }

    /// Prove sample coverage against the interval being replaced, in seconds.
    /// Truncation is allowed: a 71-minute call with a 60-minute cap refines the
    /// complete first 60 minutes and preserves the remaining live tail.
    static func audioCoverageRefusal(
        targetDurationSeconds: TimeInterval,
        retainedAudioSeconds: TimeInterval,
        retainedAudioWasTruncated _: Bool
    ) -> Reason? {
        guard targetDurationSeconds.isFinite, targetDurationSeconds > 0 else {
            return .invalidRecordingDuration
        }
        guard retainedAudioSeconds.isFinite, retainedAudioSeconds >= 0 else {
            return .invalidRetainedDuration
        }
        let delta = retainedAudioSeconds - targetDurationSeconds
        guard abs(delta) <= absoluteCoverageTolerance else {
            return delta < 0 ? .incompleteRetainedAudio : .excessRetainedAudio
        }
        return nil
    }

    static func tokenRecall(live: [String], refined: [String]) -> Double {
        guard !live.isEmpty else { return 1 }
        var remaining = Dictionary(refined.map { ($0, 1) }, uniquingKeysWith: +)
        var matches = 0
        for token in live where (remaining[token] ?? 0) > 0 {
            matches += 1
            remaining[token, default: 0] -= 1
        }
        return Double(matches) / Double(live.count)
    }

    /// Ordered overlap without an hour-scale LCS matrix.
    static func orderedTokenRecall(live: [String], refined: [String]) -> Double {
        guard !live.isEmpty else { return 0 }
        var positions: [String: [Int]] = [:]
        for (index, token) in refined.enumerated() {
            positions[token, default: []].append(index)
        }
        var cursor = -1
        var matches = 0
        for token in live {
            guard let candidates = positions[token] else { continue }
            var low = 0
            var high = candidates.count
            while low < high {
                let middle = low + (high - low) / 2
                if candidates[middle] <= cursor { low = middle + 1 }
                else { high = middle }
            }
            guard low < candidates.count else { continue }
            cursor = candidates[low]
            matches += 1
        }
        return Double(matches) / Double(live.count)
    }

    static func evaluate(
        live: [TranscriptEntry],
        refined: [TranscriptEntry],
        targetDurationSeconds: TimeInterval,
        retainedAudioSeconds: TimeInterval,
        retainedAudioWasTruncated: Bool
    ) -> Decision {
        let liveTokens = tokens(systemText(live))
        let refinedTokens = tokens(systemText(refined))
        let audioCoverage: Double
        if targetDurationSeconds.isFinite, targetDurationSeconds > 0,
           retainedAudioSeconds.isFinite, retainedAudioSeconds >= 0 {
            audioCoverage = retainedAudioSeconds / targetDurationSeconds
        } else {
            audioCoverage = 0
        }
        let recall = tokenRecall(live: liveTokens, refined: refinedTokens)
        let orderedRecall = orderedTokenRecall(live: liveTokens, refined: refinedTokens)

        func result(_ replace: Bool, _ reason: Reason) -> Decision {
            Decision(
                replace: replace,
                reason: reason,
                liveWordCount: liveTokens.count,
                refinedWordCount: refinedTokens.count,
                audioCoverage: audioCoverage,
                liveTokenRecall: recall,
                orderedTokenRecall: orderedRecall)
        }

        if let reason = audioCoverageRefusal(
            targetDurationSeconds: targetDurationSeconds,
            retainedAudioSeconds: retainedAudioSeconds,
            retainedAudioWasTruncated: retainedAudioWasTruncated) {
            return result(false, reason)
        }
        guard !liveTokens.isEmpty else { return result(false, .missingLiveEvidence) }
        guard live.filter({ $0.source == .system }).allSatisfy({
            $0.transcriptionEngine == .local
        }) else {
            return result(false, .mixedEngineTranscript)
        }
        guard !refinedTokens.isEmpty else { return result(false, .emptyDecode) }
        let wordRatio = Double(refinedTokens.count) / Double(liveTokens.count)
        guard wordRatio >= minimumWordCoverage else {
            return result(false, .insufficientWordCoverage)
        }
        guard wordRatio <= maximumWordExpansion else {
            return result(false, .excessiveWordExpansion)
        }
        guard recall >= minimumLiveTokenRecall else {
            return result(false, .insufficientLiveTokenRecall)
        }
        guard orderedRecall >= minimumOrderedTokenRecall else {
            return result(false, .insufficientOrderedTokenRecall)
        }
        return result(true, .accepted)
    }

    /// Small-input test helper. Production decode below advances by index and
    /// holds only one copied window at a time; it never materializes an hour of
    /// overlapping PCM windows on the MainActor.
    static func windows(
        samples: [Int16],
        sampleRate: Int = sampleRate,
        windowSeconds: TimeInterval = windowSeconds,
        overlapSeconds: TimeInterval = overlapSeconds
    ) -> [AudioWindow] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let sizes = windowSizes(
            sampleRate: sampleRate,
            windowSeconds: windowSeconds,
            overlapSeconds: overlapSeconds)
        var result: [AudioWindow] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + sizes.window)
            result.append(AudioWindow(
                samples: Array(samples[start..<end]), startSample: start))
            if end == samples.count { break }
            start += sizes.advance
        }
        return result
    }

    private static func windowSizes(
        sampleRate: Int,
        windowSeconds: TimeInterval,
        overlapSeconds: TimeInterval
    ) -> (window: Int, advance: Int) {
        let window = max(1, Int(windowSeconds * Double(sampleRate)))
        let overlap = max(
            0, min(Int(overlapSeconds * Double(sampleRate)), window - 1))
        return (window, max(1, window - overlap))
    }

    static func decode(
        samples: [Int16],
        retainedAudioStart: Date,
        using service: TranscriptionService
    ) async throws -> [TranscriptEntry] {
        guard !samples.isEmpty else { return [] }
        let sizes = windowSizes(
            sampleRate: sampleRate,
            windowSeconds: windowSeconds,
            overlapSeconds: overlapSeconds)
        var entries: [TranscriptEntry] = []
        var previous: String?
        var start = 0
        var index = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, start + sizes.window)
            let window = Array(samples[start..<end])
            if VoiceActivity.isVoiced(
                window, threshold: VoiceActivity.systemAudioThreshold) {
                let wav = WAVEncoder.encode(samples: window, sampleRate: sampleRate)
                let raw = try await service.transcribe(wav: wav)
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    throw LocalFinalPassError.voicedWindowProducedNoText(index: index)
                }
                let novel = previous.map {
                    ChunkStitcher.stitch(previous: $0, next: clean)
                } ?? clean
                if !novel.isEmpty {
                    entries.append(TranscriptEntry(
                        source: .system,
                        text: novel,
                        timestamp: retainedAudioStart.addingTimeInterval(
                            Double(start) / Double(sampleRate)),
                        transcriptionEngine: .local))
                }
                previous = clean
            } else {
                // Do not bridge a lexical seam across real silence.
                previous = nil
            }
            if end == samples.count { break }
            start += sizes.advance
            index += 1
        }
        return entries
    }

    static func replacingLocalSystemInterval(
        live: [TranscriptEntry],
        refined: [TranscriptEntry],
        retainedAudioStart: Date,
        retainedAudioEnd: Date,
        replaceLocalRowsBefore: Date? = nil
    ) -> [TranscriptEntry] {
        let replacementEnd = min(replaceLocalRowsBefore ?? retainedAudioEnd,
                                 retainedAudioEnd)
        let preserved = live.filter {
            !($0.source == .system
                && $0.transcriptionEngine == .local
                && $0.timestamp >= retainedAudioStart
                && $0.timestamp < replacementEnd)
        }
        // Sort stably. Refined system rows win an exact timestamp tie so a mic
        // response captured at the same instant follows the remote window that
        // prompted it; all preserved equal-time rows keep their original order.
        let tagged = refined.enumerated().map {
            (entry: $0.element, priority: 0, order: $0.offset)
        } + preserved.enumerated().map {
            (entry: $0.element, priority: 1, order: $0.offset)
        }
        return tagged.sorted { left, right in
            if left.entry.timestamp != right.entry.timestamp {
                return left.entry.timestamp < right.entry.timestamp
            }
            if left.priority != right.priority { return left.priority < right.priority }
            return left.order < right.order
        }.map(\.entry)
    }
}
