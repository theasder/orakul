import Foundation
import Testing
@testable import MeetGPT

private final class OrakulDiarizationInvocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() { lock.lock(); value = true; lock.unlock() }
    var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
@Suite("Private speaker-label lifecycle", .serialized)
struct LocalDiarizationLifecycleTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func preparedState() -> AppState {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-local-diarization-\(UUID().uuidString)")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            sessionStore: SessionStore(root: root))
        state.applyTestWorkspace(recording: false)
        state.transcript = [
            TranscriptEntry(
                source: .mic, text: "local", timestamp: start.addingTimeInterval(1),
                transcriptionEngine: .local),
            TranscriptEntry(
                source: .system, text: "first", timestamp: start.addingTimeInterval(2),
                transcriptionEngine: .local),
            TranscriptEntry(
                source: .system, text: "second", timestamp: start.addingTimeInterval(10),
                transcriptionEngine: .local),
        ]
        state.applyTestLocalFinalPassRetention(
            samples: Array(repeating: Int16(0), count: 16_000 * 21),
            startedAt: start,
            optedIn: false,
            localDiarization: true)
        state.applyTestStopInstant(start.addingTimeInterval(21))
        return state
    }

    private func waitUntilFinished(_ state: AppState) async throws {
        for _ in 0..<400 where state.hasScheduledLocalDiarization {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!state.hasScheduledLocalDiarization)
    }

    private func waitUntilInvoked(_ flag: OrakulDiarizationInvocationFlag) async throws {
        for _ in 0..<400 where !flag.isMarked {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(flag.isMarked)
    }

    @Test("label-only consent works with final-pass refinement off")
    func labelOnlyCallIsEligible() {
        let state = preparedState()
        #expect(state.canLabelSpeakersLocally)
        #expect(!state.canRetranscribeLocally)
        #expect(state.retainedAudioSampleCountForTesting == 16_000 * 21)
    }

    @Test("manual pass reserves Вы and assigns stable remote numbers")
    func appliesStableLabels() async throws {
        let state = preparedState()
        state.localDiarizationRunnerOverride = { _, expected, progress in
            progress?(1)
            guard expected == 2 else { return [] }
            return [
                SpeakerSegment(speakerID: "opaque-z", startSeconds: 9, endSeconds: 16),
                SpeakerSegment(speakerID: "opaque-a", startSeconds: 0, endSeconds: 8),
            ]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 2)
        try await waitUntilFinished(state)

        #expect(state.transcript.map(\.speaker) == ["Вы", "Спикер 2", "Спикер 3"])
        #expect(state.localDiarizationNote?.contains("Бета") == true)
        #expect(state.localDiarizationNote?.contains("проверьте") == true)
        #expect(state.retainedAudioSampleCountForTesting == 16_000 * 21,
                "PCM remains available for a count correction and rerun")
    }

    @Test("rerun on the same PCM can shrink the remote count")
    func rerunClearsStaleVoice() async throws {
        let state = preparedState()
        state.localDiarizationRunnerOverride = { _, expected, _ in
            if expected == 2 {
                return [
                    SpeakerSegment(speakerID: "a", startSeconds: 0, endSeconds: 8),
                    SpeakerSegment(speakerID: "b", startSeconds: 8, endSeconds: 18),
                ]
            }
            return [SpeakerSegment(speakerID: "only", startSeconds: 0, endSeconds: 8)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 2)
        try await waitUntilFinished(state)
        #expect(state.transcript.last?.speaker == "Спикер 3")

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilFinished(state)
        #expect(state.transcript.map(\.speaker) == ["Вы", "Спикер 2", nil])
        #expect(state.retainedAudioSampleCountForTesting == 16_000 * 21)
    }

    @Test("Cancel invalidates a non-cooperative model result")
    func cancellationCannotApplyLateResult() async throws {
        let state = preparedState()
        let original = state.transcript
        let invoked = OrakulDiarizationInvocationFlag()
        state.localDiarizationRunnerOverride = { _, _, _ in
            invoked.mark()
            try? await Task.sleep(nanoseconds: 150_000_000)
            return [SpeakerSegment(speakerID: "late", startSeconds: 0, endSeconds: 20)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilInvoked(invoked)
        state.cancelLocalSpeakerLabels()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(state.transcript == original)
        #expect(!state.localDiarizationRunning)
        #expect(!state.diarizing)
        #expect(state.localDiarizationNote?.contains("отменено") == true)
    }

    @Test("cancelling without a private run does not clear cloud busy state")
    func idleCancelDoesNotOwnCloudBusyState() {
        let state = preparedState()
        state.diarizing = true
        state.cancelLocalSpeakerLabels()
        #expect(state.diarizing)
    }

    @Test("a transcript edit while the model runs makes the result stale")
    func transcriptRevisionWins() async throws {
        let state = preparedState()
        let invoked = OrakulDiarizationInvocationFlag()
        state.localDiarizationRunnerOverride = { _, _, _ in
            invoked.mark()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [SpeakerSegment(speakerID: "late", startSeconds: 0, endSeconds: 20)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilInvoked(invoked)
        state.transcript.append(TranscriptEntry(
            source: .system,
            text: "arrived while inference ran",
            timestamp: start.addingTimeInterval(18),
            transcriptionEngine: .local))
        try await waitUntilFinished(state)

        #expect(state.transcript.allSatisfy { $0.speaker == nil })
    }

    @Test("Clear cancels and revision-blocks a late model result")
    func clearWinsOverLateResult() async throws {
        let state = preparedState()
        let invoked = OrakulDiarizationInvocationFlag()
        state.localDiarizationRunnerOverride = { _, _, _ in
            invoked.mark()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [SpeakerSegment(speakerID: "late", startSeconds: 0, endSeconds: 20)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilInvoked(invoked)
        state.clearAll()
        try await Task.sleep(nanoseconds: 160_000_000)

        #expect(state.transcript.isEmpty)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.localDiarizationRunning)
    }

    @Test("History restore cancels and revision-blocks a late model result")
    func restoreWinsOverLateResult() async throws {
        let state = preparedState()
        let invoked = OrakulDiarizationInvocationFlag()
        state.localDiarizationRunnerOverride = { _, _, _ in
            invoked.mark()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [SpeakerSegment(speakerID: "late", startSeconds: 0, endSeconds: 20)]
        }
        let restored = SavedSession(
            id: UUID(), title: "История", startedAt: start, savedAt: start,
            goal: "", entries: [TranscriptEntry(
                source: .system, text: "сохранённая строка", timestamp: start)],
            aiResponse: "", digest: "")

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilInvoked(invoked)
        state.restoreSession(restored)
        try await Task.sleep(nanoseconds: 160_000_000)

        #expect(state.transcript.map(\.text) == ["сохранённая строка"])
        #expect(state.transcript.allSatisfy { $0.speaker == nil })
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.localDiarizationRunning)
    }

    @Test("New call reset cancels and revision-blocks a late model result")
    func newCallWinsOverLateResult() async throws {
        let state = preparedState()
        let invoked = OrakulDiarizationInvocationFlag()
        state.localDiarizationRunnerOverride = { _, _, _ in
            invoked.mark()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [SpeakerSegment(speakerID: "late", startSeconds: 0, endSeconds: 20)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilInvoked(invoked)
        state.resetForNewRecording()
        try await Task.sleep(nanoseconds: 160_000_000)

        #expect(state.transcript.isEmpty)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.localDiarizationRunning)
    }

    @Test("a capped recording labels only its exact retained prefix")
    func truncatedAudioIsDisclosed() async throws {
        let state = preparedState()
        state.truncateRetainedAudioForTesting(maxSamples: 16_000 * 20)
        state.transcript.append(TranscriptEntry(
            source: .system,
            text: "outside retained prefix",
            timestamp: start.addingTimeInterval(20.5),
            speaker: "Спикер 4",
            transcriptionEngine: .local))
        state.localDiarizationRunnerOverride = { _, _, _ in
            [SpeakerSegment(speakerID: "remote", startSeconds: 0, endSeconds: 20)]
        }

        state.labelSpeakersLocallyNow(expectedRemoteSpeakerCount: 1)
        try await waitUntilFinished(state)

        #expect(state.localDiarizationNote?.contains("полностью сохранённая часть") == true)
        #expect(state.localDiarizationNote?.contains("поздние строки не изменены") == true)
        #expect(state.transcript.last?.speaker == "Спикер 4")
    }

    @Test("pause discontinuity releases PCM and refuses aligned labels")
    func pauseRefusesMisalignedAudio() {
        let state = preparedState()
        state.applyTestWorkspace(recording: true)
        state.pauseRecording()
        state.applyTestWorkspace(recording: false)
        #expect(!state.canLabelSpeakersLocally)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.retainedAudioTimelineValidForTesting)
    }
}
