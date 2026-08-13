import Foundation
import Testing
@testable import MeetGPT

/// F5, first slice: on-device speaker labels.
///
/// The single most-repeated technical complaint in the mined competitor
/// reviews — "speaker attribution broke down when people talked over each
/// other, which is every product review I run", "the inability to tell who
/// said what is a show stopper". Cruxwing's existing answer is a metered
/// cloud pass; this one runs on the Mac, which is the only version a
/// privacy-led product can offer by default.
///
/// The model call is a thin shell. What is tested here is the part that can be
/// wrong in a way nobody notices: mapping diarizer time-ranges onto transcript
/// lines. Every rule below exists because the alternative silently mislabels
/// somebody's words.
@Suite("Local speaker labels")
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
            to: [entry("first thing", at: 2), entry("second thing", at: 12)],
            sessionStart: start)
        #expect(out.map(\.speaker) == ["Speaker A", "Speaker B"])
    }

    @Test("overlapping speech goes to whoever holds the line longest, not whoever started")
    func overlapWins() {
        // Crosstalk: B starts before this line and A takes over during it. The
        // line's own window is what decides, so the label follows the speech in
        // it rather than the segment that happens to contain its first instant.
        let out = SpeakerAssignment.apply(
            segments: [segment("B", 9, 10.4), segment("A", 10.4, 16)],
            to: [entry("a long sentence that runs on", at: 10)],
            sessionStart: start, lineDuration: 5)
        #expect(out.first?.speaker == "Speaker A")
    }

    @Test("the microphone track is never relabelled — that speaker is known")
    func micTrackUntouched() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 30)],
            to: [entry("my own words", at: 3, source: .mic)],
            sessionStart: start)
        #expect(out.first?.speaker == nil,
                "the local track is this user; a diarizer label there is noise")
    }

    @Test("a line with no matching segment keeps whatever it had")
    func unmatchedLineKeepsPriorLabel() {
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 5)],
            to: [entry("said much later", at: 400, speaker: "Speaker Q")],
            sessionStart: start)
        #expect(out.first?.speaker == "Speaker Q",
                "a gap in diarization must never erase a label that already existed")
    }

    @Test("labels are stable and human-readable across a session")
    func labelNaming() {
        let out = SpeakerAssignment.apply(
            segments: [segment("speaker_2", 0, 5), segment("3", 5, 10)],
            to: [entry("one", at: 1), entry("two", at: 6)],
            sessionStart: start)
        // Whatever the model calls them, the transcript says "Speaker X" — the
        // same shape the cloud pass already produces, so exports and the
        // renderer's cross-track logic keep working unchanged.
        #expect(out.allSatisfy { ($0.speaker ?? "").hasPrefix("Speaker ") })
        #expect(Set(out.compactMap(\.speaker)).count == 2)
    }

    @Test("nothing else about an entry changes")
    func onlySpeakerChanges() {
        let source = entry("the text stays exactly this", at: 2)
        let out = SpeakerAssignment.apply(
            segments: [segment("A", 0, 10)], to: [source], sessionStart: start)
        let labelled = out[0]
        #expect(labelled.id == source.id)
        #expect(labelled.text == source.text)
        #expect(labelled.timestamp == source.timestamp)
        #expect(labelled.source == source.source)
    }

    @Test("no segments at all is a no-op, not an erasure")
    func emptySegments() {
        let entries = [entry("a", at: 1, speaker: "Speaker Z"), entry("b", at: 2)]
        #expect(SpeakerAssignment.apply(segments: [], to: entries, sessionStart: start) == entries)
    }

    @Test("counts the distinct voices it actually found")
    func speakerCount() {
        let segments = [segment("A", 0, 5), segment("B", 5, 9), segment("A", 9, 12)]
        #expect(SpeakerAssignment.distinctSpeakers(in: segments) == 2)
        #expect(SpeakerAssignment.distinctSpeakers(in: []) == 0)
    }

    // MARK: gating

    @Test("too little audio to cluster means no attempt at all")
    func refusesShortAudio() {
        // Clustering a few seconds of speech produces a confident guess, and a
        // confident wrong speaker label is the complaint being answered here.
        #expect(!LocalDiarization.canRun(sampleCount: 16_000 * 5))
        #expect(LocalDiarization.canRun(sampleCount: 16_000 * 60))
        #expect(!LocalDiarization.canRun(sampleCount: 16_000 * 60, sampleRate: 0),
                "a nonsense sample rate must not divide by zero into 'sure, run it'")
    }

    @Test("the local pass ships dark until it is measured")
    func offByDefault() {
        // Same discipline as the Parakeet lane: the code ships, the flag waits
        // for evidence against the cloud pass on real multi-party calls.
        let key = "transcription.localDiarization"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!LocalDiarization.isEnabled)
        LocalDiarization.isEnabled = true
        #expect(LocalDiarization.isEnabled)
        if let previous { UserDefaults.standard.set(previous, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Env-gated smoke against the real CoreML models, like the Parakeet lane's.
    /// CRUXWING_DIARIZE_WAV=/path/to/call.wav swift test --filter smokeRealDiarization
    @Test("smoke: real models label a real recording",
          .enabled(if: ProcessInfo.processInfo.environment["CRUXWING_DIARIZE_WAV"] != nil))
    func smokeRealDiarization() async throws {
        // Наличие гарантирует трейт выше — без переменной тело не соберётся.
        let path = ProcessInfo.processInfo.environment["CRUXWING_DIARIZE_WAV"]!
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples = LocalWhisperTranscription.floatSamples(fromWAV: wav)
        let segments = try await LocalDiarization.segments(samples: samples)
        #expect(!segments.isEmpty)
        #expect(SpeakerAssignment.distinctSpeakers(in: segments) >= 1)
        for segment in segments {
            #expect(segment.endSeconds > segment.startSeconds)
        }
    }
}
