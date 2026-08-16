import Foundation

/// Conservative post-Stop local refinement.
///
/// A single WhisperKit call over several minutes can return only a short
/// prefix even when it succeeds. The final pass therefore decodes bounded,
/// overlapping windows and joins their text with the same seam recovery used
/// by live captions. The live transcript is replaced only after the retained
/// PCM and decoded text both pass fail-closed coverage checks.
enum LocalFinalPass {
    static let sampleRate = 16_000
    /// Exact-audio sweep against the Fireflies pseudo-reference: Turbo reached
    /// WER 0.4386 / token recall 0.753 at 12 seconds, versus 0.4812 / 0.732 at
    /// six and 0.4452 / 0.753 at 30. Keep a two-second seam on top.
    static let windowSeconds: TimeInterval = 12
    static let overlapSeconds: TimeInterval = 2
    static let minimumWordCoverage = 0.90
    static let minimumAudioCoverage = 0.98
    static let maximumAudioCoverage = 1.02
    static let minimumLiveTokenRecall = 0.85
    static let minimumOrderedTokenRecall = 0.75
    static let maximumWordExpansion = 1.50

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

    static func liveSystemText(_ transcript: [TranscriptEntry]) -> String {
        transcript.filter { $0.source == .system }.map(\.text).joined(separator: " ")
    }

    /// Only Local system rows backed by the retained suffix may be rebuilt.
    /// Earlier cloud rows and every mic row stay byte-for-byte unchanged.
    static func localSystemSuffix(
        in transcript: [TranscriptEntry],
        retainedAudioStart: Date
    ) -> [TranscriptEntry] {
        transcript.filter {
            $0.source == .system
                && $0.transcriptionEngine == .local
                && $0.timestamp >= retainedAudioStart
        }
    }

    static func retainedSuffixHasNonLocalSystemRows(
        _ transcript: [TranscriptEntry],
        retainedAudioStart: Date
    ) -> Bool {
        transcript.contains {
            $0.source == .system
                && $0.timestamp >= retainedAudioStart
                && $0.transcriptionEngine != .local
        }
    }

    static func shouldRunAutomatically(
        enabled: Bool,
        sessionEngine: TranscriptionEngine?,
        hasEngineTransitions: Bool
    ) -> Bool {
        enabled && sessionEngine == .local && !hasEngineTransitions
    }

    static func audioCoverageRefusal(
        recordingDurationSeconds: TimeInterval,
        retainedAudioSeconds: TimeInterval,
        retainedAudioWasTruncated: Bool
    ) -> Reason? {
        if retainedAudioWasTruncated { return .truncatedRetainedAudio }
        guard recordingDurationSeconds.isFinite, recordingDurationSeconds > 0 else {
            return .invalidRecordingDuration
        }
        guard retainedAudioSeconds.isFinite, retainedAudioSeconds >= 0 else {
            return .invalidRetainedDuration
        }
        let coverage = retainedAudioSeconds / recordingDurationSeconds
        guard coverage >= minimumAudioCoverage else { return .incompleteRetainedAudio }
        guard coverage <= maximumAudioCoverage else { return .excessRetainedAudio }
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
        refinedText: String,
        recordingDurationSeconds: TimeInterval,
        retainedAudioSeconds: TimeInterval,
        retainedAudioWasTruncated: Bool
    ) -> Decision {
        let liveTokens = tokens(liveSystemText(live))
        let refinedTokens = tokens(refinedText)
        let audioCoverage: Double
        if recordingDurationSeconds.isFinite, recordingDurationSeconds > 0,
           retainedAudioSeconds.isFinite, retainedAudioSeconds >= 0 {
            audioCoverage = retainedAudioSeconds / recordingDurationSeconds
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
            recordingDurationSeconds: recordingDurationSeconds,
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

    /// Measured 12-second windows stay below Whisper's 30-second context and a
    /// two-second overlap protects words cut at each boundary.
    static func windows(
        samples: [Int16],
        sampleRate: Int = sampleRate,
        windowSeconds: TimeInterval = windowSeconds,
        overlapSeconds: TimeInterval = overlapSeconds
    ) -> [[Int16]] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let window = max(1, Int(windowSeconds * Double(sampleRate)))
        let overlap = max(0, min(Int(overlapSeconds * Double(sampleRate)), window - 1))
        let advance = max(1, window - overlap)
        var result: [[Int16]] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            result.append(Array(samples[start..<end]))
            if end == samples.count { break }
            start += advance
        }
        return result
    }

    static func stitchedText(_ chunkTexts: [String]) -> String {
        var parts: [String] = []
        var previous: String?
        for raw in chunkTexts {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                previous = nil
                continue
            }
            let novel = previous.map { ChunkStitcher.stitch(previous: $0, next: clean) }
                ?? clean
            if !novel.isEmpty { parts.append(novel) }
            previous = clean
        }
        return parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(
        samples: [Int16],
        using service: TranscriptionService
    ) async throws -> String {
        var texts: [String] = []
        for window in windows(samples: samples) {
            try Task.checkCancellation()
            let wav = WAVEncoder.encode(samples: window, sampleRate: sampleRate)
            texts.append(try await service.transcribe(wav: wav))
        }
        return stitchedText(texts)
    }

    static func replacingSystemLines(
        live: [TranscriptEntry],
        refinedText: String,
        timestamp: Date
    ) -> [TranscriptEntry] {
        let mic = live.filter { $0.source == .mic }
        let rebuilt = TranscriptEntry(
            source: .system,
            text: refinedText,
            timestamp: timestamp,
            speaker: nil,
            transcriptionEngine: .local)
        return ([rebuilt] + mic).sorted { $0.timestamp < $1.timestamp }
    }

    static func replacingLocalSystemSuffix(
        live: [TranscriptEntry],
        refinedText: String,
        retainedAudioStart: Date
    ) -> [TranscriptEntry] {
        let preserved = live.filter {
            !($0.source == .system
                && $0.transcriptionEngine == .local
                && $0.timestamp >= retainedAudioStart)
        }
        let rebuilt = TranscriptEntry(
            source: .system,
            text: refinedText,
            timestamp: retainedAudioStart,
            speaker: nil,
            transcriptionEngine: .local)
        return (preserved + [rebuilt]).sorted { $0.timestamp < $1.timestamp }
    }
}
