import Foundation
import Testing
@testable import MeetGPT

@Suite("Local speaker labels", .serialized)
struct LocalSpeakerLabelsTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ text: String, at offset: TimeInterval,
                       source: TranscriptSource = .system,
                       speaker: String? = nil) -> TranscriptEntry {
        TranscriptEntry(id: UUID(), source: source, text: text,
                        timestamp: start.addingTimeInterval(offset), speaker: speaker)
    }

    private func segment(_ id: String, _ from: Float, _ to: Float) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, startSeconds: from, endSeconds: to)
    }

    @Test("a line takes the label of the speaker talking at that moment")
    func basicAssignment() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 10), segment("B", 10, 20)],
            to: [entry("first", at: 2), entry("second", at: 12)],
            sessionStart: start)
        #expect(out.map(\.speaker) == ["Спикер 1", "Спикер 2"])
    }

    @Test("overlapping speech follows whoever holds the line longest")
    func overlapWins() {
        let out = SpeakerAssignment.apply(
            segments: [segment("B", 9, 10.4), segment("A", 10.4, 16)],
            to: [entry("long sentence", at: 10)],
            sessionStart: start, lineDuration: 5)
        #expect(out.first?.speaker == "Спикер 2")
    }

    @Test("the microphone track stays anonymous without explicit private mode")
    func micTrackUntouched() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 30)],
            to: [entry("my words", at: 3, source: .mic)],
            sessionStart: start)
        #expect(out.first?.speaker == nil)
    }

    @Test("a named unmatched line keeps its prior label")
    func unmatchedNamedLineKeepsPriorLabel() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 5)],
            to: [entry("later", at: 400, speaker: "Speaker Q")],
            sessionStart: start)
        #expect(out.first?.speaker == "Speaker Q")
    }

    @Test("opaque model IDs are numbered by first appearance")
    func labelNaming() {
        let out = SpeakerAssignment.apply(
            segments: [segment("speaker_93", 8, 12), segment("cluster-z", 0, 5)],
            to: [entry("one", at: 1), entry("two", at: 8)],
            sessionStart: start)
        #expect(out.map(\.speaker) == ["Спикер 1", "Спикер 2"])
    }

    @Test("equal first appearances use the raw ID as a stable tie break")
    func deterministicTie() {
        let labels = SpeakerAssignment.canonicalLabels(for: [
            segment("z", 0, 5), segment("a", 0, 5),
        ])
        #expect(labels["a"] == "Спикер 1")
        #expect(labels["z"] == "Спикер 2")
    }

    @Test("the known local user is reserved and remote voices start at 2")
    func reservesLocalSpeaker() {
        let out = SpeakerAssignment.apply(
            segments: [segment("remote-b", 6, 10), segment("remote-a", 0, 5)],
            to: [
                entry("me", at: 1, source: .mic),
                entry("first remote", at: 1),
                entry("second remote", at: 6),
            ],
            sessionStart: start,
            firstRemoteSpeakerNumber: 2,
            localSpeakerLabel: "Вы")
        #expect(out.map(\.speaker) == ["Вы", "Спикер 2", "Спикер 3"])
    }

    @Test("separate turns from one voice have their overlap summed")
    func sumsOverlapBySpeaker() {
        let out = SpeakerAssignment.apply(
            segments: [
                segment("A", 10, 11.2),
                segment("B", 11.2, 13.1),
                segment("A", 13.1, 14.1),
            ],
            to: [entry("split", at: 10)],
            sessionStart: start,
            lineDuration: 4.1)
        #expect(out.first?.speaker == "Спикер 1")
    }

    @Test("duplicate model windows are unioned instead of double-counted")
    func unionsDuplicateWindows() {
        let out = SpeakerAssignment.apply(
            segments: [
                segment("A", 10, 11.5),
                segment("A", 10, 11.5),
                segment("B", 11.5, 14),
            ],
            to: [entry("B holds more", at: 10)],
            sessionStart: start)
        #expect(out.first?.speaker == "Спикер 2")
    }

    @Test("existing real names and cloud labels are never overwritten")
    func protectsExistingLabels() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 20)],
            to: [
                entry("named", at: 1, speaker: "Майя"),
                entry("cloud", at: 2, speaker: "Speaker A"),
            ],
            sessionStart: start)
        #expect(out.map(\.speaker) == ["Майя", "Speaker A"])
    }

    @Test("rerunning with fewer voices clears stale local numeric labels")
    func shrinkingCountClearsUnmatchedLocalLabel() {
        let previous = [
            entry("matched", at: 1, speaker: "Спикер 2"),
            entry("unmatched", at: 12, speaker: "Спикер 3"),
            entry("reviewed", at: 18, speaker: "Майя"),
        ]
        let out = SpeakerAssignment.apply(
            segments: [segment("only", 0, 6)],
            to: previous,
            sessionStart: start,
            firstRemoteSpeakerNumber: 2,
            localSpeakerLabel: "Вы")
        #expect(out.map(\.speaker) == ["Спикер 2", nil, "Майя"])
    }

    @Test("malformed segments cannot create a speaker")
    func ignoresMalformedSegments() {
        let bad = [
            segment("", 0, 5),
            segment("A", 5, 5),
            segment("B", .nan, 8),
            segment("C", -1, 4),
        ]
        #expect(SpeakerAssignment.distinctSpeakers(in: bad) == 0)
        #expect(SpeakerAssignment.apply(
            segments: bad,
            to: [entry("unchanged", at: 1)],
            sessionStart: start
        ).first?.speaker == nil)
    }

    @Test("a negative window is ignored even when its cluster has a valid turn")
    func negativeSegmentCannotWinOverlap() {
        let out = SpeakerAssignment.apply(
            segments: [
                segment("A", -10, 3),
                segment("A", 10, 11),
                segment("B", 0, 2),
            ],
            to: [entry("opening", at: 0)],
            sessionStart: start)
        #expect(out.first?.speaker == "Спикер 1")
    }

    @Test("nothing else about an entry changes")
    func onlySpeakerChanges() {
        let source = entry("same text", at: 2)
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 10)], to: [source], sessionStart: start)
        let labeled = out[0]
        #expect(labeled.id == source.id)
        #expect(labeled.text == source.text)
        #expect(labeled.timestamp == source.timestamp)
        #expect(labeled.source == source.source)
        #expect(labeled.transcriptionEngine == source.transcriptionEngine)
    }

    @Test("no segments is a no-op")
    func emptySegments() {
        let entries = [entry("a", at: 1, speaker: "Speaker Z"), entry("b", at: 2)]
        #expect(SpeakerAssignment.apply(
            segments: [], to: entries, sessionStart: start) == entries)
    }

    @Test("counts normalized distinct voices")
    func speakerCount() {
        let segments = [segment(" A ", 0, 5), segment("B", 5, 9), segment("A", 9, 12)]
        #expect(SpeakerAssignment.distinctSpeakers(in: segments) == 2)
        #expect(SpeakerAssignment.distinctSpeakers(in: []) == 0)
    }

    @Test("too little audio refuses clustering")
    func refusesShortAudio() {
        #expect(!LocalDiarization.canRun(sampleCount: 16_000 * 5))
        #expect(LocalDiarization.canRun(sampleCount: 16_000 * 60))
        #expect(!LocalDiarization.canRun(sampleCount: 16_000 * 60, sampleRate: 0))
    }

    @Test("remote speaker count is explicit and bounded one through four")
    func boundsExpectedSpeakerCount() {
        #expect(LocalDiarization.normalizedRemoteSpeakerCount(-5) == 1)
        #expect(LocalDiarization.normalizedRemoteSpeakerCount(1) == 1)
        #expect(LocalDiarization.normalizedRemoteSpeakerCount(3) == 3)
        #expect(LocalDiarization.normalizedRemoteSpeakerCount(99) == 4)
    }

    @Test("the beta pass requires explicit opt-in")
    func offByDefault() async {
        await SharedDefaults.withExclusiveAccess {
            let key = "transcription.localDiarization"
            let previous = UserDefaults.standard.object(forKey: key)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)
            #expect(!LocalDiarization.isEnabled)
            LocalDiarization.isEnabled = true
            #expect(LocalDiarization.isEnabled)
        }
    }

    /// ORAKUL_DIARIZE_WAV=/path/to/call.wav ORAKUL_DIARIZE_REMOTE_SPEAKERS=2
    /// swift test --filter smokeRealDiarization
    @Test("smoke: real models label a real recording")
    func smokeRealDiarization() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ORAKUL_DIARIZE_WAV"],
              let rawCount = environment["ORAKUL_DIARIZE_REMOTE_SPEAKERS"],
              let count = Int(rawCount) else { return }
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
        let segments = try await LocalDiarization.segments(
            samples: samples,
            expectedRemoteSpeakerCount: count)
        #expect(!segments.isEmpty)
        #expect(SpeakerAssignment.distinctSpeakers(in: segments) >= 1)
        for segment in segments {
            #expect(segment.endSeconds > segment.startSeconds)
        }
    }
}
