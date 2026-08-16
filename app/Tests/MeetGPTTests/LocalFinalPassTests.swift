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

    private func live(engine: TranscriptionEngine? = .local) -> [TranscriptEntry] {
        [
            TranscriptEntry(
                source: .system,
                text: liveWords.joined(separator: " "),
                timestamp: startedAt,
                transcriptionEngine: engine),
            TranscriptEntry(
                source: .mic,
                text: "my response",
                timestamp: startedAt.addingTimeInterval(1),
                transcriptionEngine: .local),
        ]
    }

    @Test("external windows stay bounded and overlap")
    func boundedWindows() {
        let samples = Array(0..<70).map(Int16.init)
        let windows = LocalFinalPass.windows(
            samples: samples,
            sampleRate: 1,
            windowSeconds: 12,
            overlapSeconds: 2)
        #expect(windows.map(\.count) == [12, 12, 12, 12, 12, 12, 10])
        #expect(windows[0].suffix(2) == windows[1].prefix(2))
        #expect(windows[1].suffix(2) == windows[2].prefix(2))
    }

    @Test("bounded decoder stitches repeated seam words")
    func chunkedDecodeAndStitch() async throws {
        let service = FinalPassSequenceTranscriber([
            "we need legal approval before the launch",
            "before the launch and then notify customers",
        ])
        let text = try await LocalFinalPass.decode(
            samples: [Int16](repeating: 1, count: 13 * LocalFinalPass.sampleRate),
            using: service)
        #expect(text == "we need legal approval before the launch and then notify customers")
        let counts = await service.counts()
        #expect(counts.count == 2)
        #expect(counts.allSatisfy {
            $0 <= Int(LocalFinalPass.windowSeconds) * LocalFinalPass.sampleRate
        })
    }

    @Test("complete equivalent evidence may replace live system rows")
    func acceptsCompleteEquivalentDecode() {
        let decision = LocalFinalPass.evaluate(
            live: live(),
            refinedText: liveWords.joined(separator: " "),
            recordingDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(decision.replace)
        #expect(decision.reason == .accepted)
    }

    @Test("partial audio and partial text fail closed")
    func refusesPartialEvidence() {
        let shortAudio = LocalFinalPass.evaluate(
            live: live(),
            refinedText: liveWords.joined(separator: " "),
            recordingDurationSeconds: 100,
            retainedAudioSeconds: 60,
            retainedAudioWasTruncated: false)
        #expect(shortAudio.reason == .incompleteRetainedAudio)

        let shortText = LocalFinalPass.evaluate(
            live: live(),
            refinedText: liveWords.prefix(10).joined(separator: " "),
            recordingDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(shortText.reason == .insufficientWordCoverage)
    }

    @Test("mixed providers and recorder truncation fail closed")
    func refusesMixedOrTruncatedEvidence() {
        let mixed = LocalFinalPass.evaluate(
            live: live(engine: .deepgram),
            refinedText: liveWords.joined(separator: " "),
            recordingDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: false)
        #expect(mixed.reason == .mixedEngineTranscript)

        #expect(LocalFinalPass.audioCoverageRefusal(
            recordingDurationSeconds: 100,
            retainedAudioSeconds: 100,
            retainedAudioWasTruncated: true) == .truncatedRetainedAudio)
    }

    @Test("replacement preserves the mic row and local provenance")
    func replacementPreservesMic() {
        let original = live()
        let replacement = LocalFinalPass.replacingSystemLines(
            live: original,
            refinedText: "refined remote speech",
            timestamp: startedAt)
        #expect(replacement.filter { $0.source == .mic } == original.filter { $0.source == .mic })
        #expect(replacement.first { $0.source == .system }?.transcriptionEngine == .local)
    }

    @Test("mixed call refinement preserves cloud prefix and replaces only retained Local suffix")
    func replacementPreservesCloudPrefix() {
        let boundary = startedAt.addingTimeInterval(30)
        let cloud = TranscriptEntry(
            source: .system,
            text: "cloud prefix",
            timestamp: startedAt,
            transcriptionEngine: .deepgram)
        let local = TranscriptEntry(
            source: .system,
            text: "rough local suffix",
            timestamp: boundary,
            transcriptionEngine: .local)
        let mic = TranscriptEntry(
            source: .mic,
            text: "my response",
            timestamp: boundary.addingTimeInterval(1),
            transcriptionEngine: .local)
        let live = [cloud, local, mic]

        #expect(!LocalFinalPass.retainedSuffixHasNonLocalSystemRows(
            live, retainedAudioStart: boundary))
        #expect(LocalFinalPass.localSystemSuffix(
            in: live, retainedAudioStart: boundary) == [local])

        let replaced = LocalFinalPass.replacingLocalSystemSuffix(
            live: live,
            refinedText: "refined local suffix",
            retainedAudioStart: boundary)
        #expect(replaced.contains(cloud))
        #expect(replaced.contains(mic))
        #expect(!replaced.contains(local))
        #expect(replaced.contains { $0.text == "refined local suffix" })
    }

    @Test("a cloud row inside retained audio makes suffix refinement unsafe")
    func retainedSuffixMustBePureLocal() {
        let boundary = startedAt.addingTimeInterval(30)
        let lateCloud = TranscriptEntry(
            source: .system,
            text: "late cloud final",
            timestamp: boundary.addingTimeInterval(1),
            transcriptionEngine: .deepgram)
        #expect(LocalFinalPass.retainedSuffixHasNonLocalSystemRows(
            [lateCloud], retainedAudioStart: boundary))
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
}
