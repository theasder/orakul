import Foundation
import Testing
@testable import MeetGPT

private actor FinalPassSequenceTranscriber: TranscriptionService {
    private var answers: [String]
    private var sampleCounts: [Int] = []

    init(_ answers: [String]) {
        self.answers = answers
    }

    func transcribe(wav: Data) async throws -> String {
        sampleCounts.append(LocalWhisperTranscription.floatSamples(fromWAV: wav).count)
        return answers.isEmpty ? "" : answers.removeFirst()
    }

    func counts() -> [Int] { sampleCounts }
}

@Suite("Safe local final pass")
struct LocalFinalPassTests {
    private let startedAt = Date(timeIntervalSince1970: 10_000)
    private let liveWords = (0..<20).map { "word\($0)" }

    private func entry(
        _ text: String,
        source: TranscriptSource = .system,
        at offset: TimeInterval = 0,
        engine: TranscriptionEngine? = .local
    ) -> TranscriptEntry {
        TranscriptEntry(
            source: source,
            text: text,
            timestamp: startedAt.addingTimeInterval(offset),
            transcriptionEngine: engine)
    }

    private func live(engine: TranscriptionEngine? = .local) -> [TranscriptEntry] {
        [
            entry(liveWords.joined(separator: " "), engine: engine),
            entry("my response", source: .mic, at: 1),
        ]
    }

    private func refined(_ text: String? = nil) -> [TranscriptEntry] {
        [entry(text ?? liveWords.joined(separator: " "))]
    }

    @Test("external windows stay bounded, timed and overlapping")
    func boundedWindows() {
        let samples = Array(0..<70).map(Int16.init)
        let windows = LocalFinalPass.windows(
            samples: samples,
            sampleRate: 1,
            windowSeconds: 12,
            overlapSeconds: 2)
        #expect(windows.map { $0.samples.count } == [12, 12, 12, 12, 12, 12, 10])
        #expect(windows.map(\.startSample) == [0, 10, 20, 30, 40, 50, 60])
        #expect(windows[0].samples.suffix(2) == windows[1].samples.prefix(2))
    }

    @Test("bounded decoder returns timed rows and stitches repeated seam words")
    func chunkedDecodeAndStitch() async throws {
        let service = FinalPassSequenceTranscriber([
            "we need legal approval before the launch",
            "before the launch and then notify customers",
        ])
        let rows = try await LocalFinalPass.decode(
            samples: AudioFixtures.voicedInt16(
                count: 13 * LocalFinalPass.sampleRate),
            retainedAudioStart: startedAt,
            using: service)
        #expect(rows.map(\.text) == [
            "we need legal approval before the launch",
            "and then notify customers",
        ])
        #expect(rows.map(\.timestamp) == [
            startedAt,
            startedAt.addingTimeInterval(10),
        ])
        let counts = await service.counts()
        #expect(counts.count == 2)
        #expect(counts.allSatisfy {
            $0 <= Int(LocalFinalPass.windowSeconds) * LocalFinalPass.sampleRate
        })
    }

    @Test("one voiced empty window aborts the interval transaction")
    func voicedWindowCannotDisappear() async {
        let service = FinalPassSequenceTranscriber([""])
        do {
            _ = try await LocalFinalPass.decode(
                samples: AudioFixtures.voicedInt16(
                    count: 2 * LocalFinalPass.sampleRate),
                retainedAudioStart: startedAt,
                using: service)
            Issue.record("expected an incomplete-window refusal")
        } catch {
            #expect(error as? LocalFinalPassError
                == .voicedWindowProducedNoText(index: 0))
        }
    }

    @Test("complete equivalent evidence may replace live system rows")
    func acceptsCompleteEquivalentDecode() {
        let decision = LocalFinalPass.evaluate(
            live: live(),
            refined: refined(),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(decision.replace)
        #expect(decision.reason == .accepted)
    }

    @Test("coverage is absolute to the target interval and truncation is safe")
    func exactIntervalCoverage() {
        let shortAudio = LocalFinalPass.evaluate(
            live: live(),
            refined: refined(),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 60,
            retainedAudioWasTruncated: false)
        #expect(shortAudio.reason == .incompleteRetainedAudio)

        // A 71-minute call may cap at 60 minutes. The target is the complete
        // retained 60-minute interval, not the full call, so this is eligible.
        #expect(LocalFinalPass.audioCoverageRefusal(
            targetDurationSeconds: 60 * 60,
            retainedAudioSeconds: 60 * 60,
            retainedAudioWasTruncated: true) == nil)
    }

    @Test("partial, expanded and reordered text fail closed")
    func refusesUnsafeText() {
        let shortText = LocalFinalPass.evaluate(
            live: live(),
            refined: refined(liveWords.prefix(10).joined(separator: " ")),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(shortText.reason == .insufficientWordCoverage)

        let expanded = liveWords
            + liveWords.prefix(8).map { "extra-\($0)" }
        let expandedDecision = LocalFinalPass.evaluate(
            live: live(),
            refined: refined(expanded.joined(separator: " ")),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(expandedDecision.reason == .excessiveWordExpansion)

        let reorderedDecision = LocalFinalPass.evaluate(
            live: live(),
            refined: refined(liveWords.reversed().joined(separator: " ")),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(reorderedDecision.reason == .insufficientOrderedTokenRecall)
    }

    @Test("mixed provider rows inside the retained interval fail closed")
    func refusesMixedEvidence() {
        let mixed = LocalFinalPass.evaluate(
            live: live(engine: .deepgram),
            refined: refined(),
            targetDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(mixed.reason == .mixedEngineTranscript)
    }

    @Test("timed replacement preserves mic chronology and a 71-minute live tail")
    func replacementPreservesChronologyAndTail() {
        let retainedEnd = startedAt.addingTimeInterval(60 * 60)
        let cloud = entry("cloud prefix", at: -1, engine: .deepgram)
        let rough0 = entry("rough zero", at: 0)
        let mic5 = entry("mic five", source: .mic, at: 5)
        let rough10 = entry("rough ten", at: 10)
        let mic15 = entry("mic fifteen", source: .mic, at: 15)
        let rough20 = entry("rough twenty", at: 20)
        let crossingCap = entry("starts before cap and ends after it", at: 60 * 60 - 3)
        let liveTail = entry("minute sixty-one remains", at: 61 * 60)
        let micTail = entry("minute seventy remains", source: .mic, at: 70 * 60)
        let refined = [
            entry("refined zero", at: 0),
            entry("refined ten", at: 10),
            entry("refined twenty", at: 20),
        ]
        let replaced = LocalFinalPass.replacingLocalSystemInterval(
            live: [cloud, rough0, mic5, rough10, mic15, rough20,
                   crossingCap, liveTail, micTail],
            refined: refined,
            retainedAudioStart: startedAt,
            retainedAudioEnd: retainedEnd,
            replaceLocalRowsBefore: retainedEnd.addingTimeInterval(-6))

        #expect(replaced.map(\.text) == [
            "cloud prefix", "refined zero", "mic five", "refined ten",
            "mic fifteen", "refined twenty", "starts before cap and ends after it",
            "minute sixty-one remains",
            "minute seventy remains",
        ])
        #expect(replaced.contains(crossingCap))
        #expect(replaced.contains(liveTail))
        #expect(replaced.contains(micTail))
        #expect(!replaced.contains(rough0))
    }

    @Test("only the exact retained interval must be Local")
    func intervalPurity() {
        let end = startedAt.addingTimeInterval(60)
        let lateCloud = entry("late cloud final", at: 61, engine: .deepgram)
        #expect(!LocalFinalPass.retainedIntervalHasNonLocalSystemRows(
            [lateCloud], retainedAudioStart: startedAt, retainedAudioEnd: end))
        let insideCloud = entry("inside cloud final", at: 59, engine: .deepgram)
        #expect(LocalFinalPass.retainedIntervalHasNonLocalSystemRows(
            [insideCloud], retainedAudioStart: startedAt, retainedAudioEnd: end))
    }
}

@Suite("Session audio retention")
struct SessionAudioRecorderTests {
    @Test("cap is visible and Stop seals future samples")
    func truncationAndSeal() {
        let recorder = SessionAudioRecorder(maxSamplesForTesting: 3)
        recorder.append([1, 2, 3, 4])
        #expect(recorder.retainedSampleCount == 3)
        #expect(recorder.isTruncated)
        recorder.seal()
        recorder.append([5])
        #expect(recorder.retainedSampleCount == 3)

        recorder.reset()
        recorder.append([6])
        #expect(recorder.retainedSampleCount == 1)
        #expect(!recorder.isTruncated)
    }

    @Test("pause excludes PCM and resume accepts it again")
    func pauseAndResume() {
        let recorder = SessionAudioRecorder(maxSamplesForTesting: 10)
        recorder.append([1, 2])
        recorder.pause()
        recorder.append([3, 4])
        #expect(recorder.sampleSnapshot() == [1, 2])
        recorder.resume()
        recorder.append([5])
        #expect(recorder.sampleSnapshot() == [1, 2, 5])
    }
}
