import Foundation
import Testing
@testable import MeetGPT

private actor BlockingLocalFinalPassTranscriber: TranscriptionService {
    private var continuation: CheckedContinuation<String, Never>?
    private var started = false

    func transcribe(wav: Data) async throws -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return started
    }

    func release(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private actor ImmediateLocalFinalPassTranscriber: TranscriptionService {
    let text: String
    init(_ text: String) { self.text = text }
    func transcribe(wav: Data) async throws -> String { text }
}

/// Re-transcribing the finished recording locally in bounded windows.
///
/// A five-minute whole-file decode returned only 92 words against a 611-word
/// reference. Twelve-second windows with overlap were the measured safe
/// default, and the replacement remains transactional.
///
/// The tests that matter are the refusals. This rewrites a transcript that took
/// a whole meeting to produce, so every path that could replace something good
/// with something worse — or with nothing — is pinned here.
@MainActor
@Suite("Local re-transcription", .serialized)
struct LocalRetranscriptionTests {

    private func finishedCall() -> AppState {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: false)
        return state
    }

    private func installEligibleLocalCall(_ state: AppState) {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        state.transcript = [TranscriptEntry(
            source: .system,
            text: (0..<20).map { "word\($0)" }.joined(separator: " "),
            timestamp: start,
            transcriptionEngine: .local)]
        state.applyTestLocalFinalPassRetention(
            samples: AudioFixtures.voicedInt16(count: 2 * LocalFinalPass.sampleRate),
            startedAt: start,
            preparedModel: "base")
    }

    @Test("an ordinary finished Local Whisper call remains eligible after reset")
    func ordinaryLocalCallIsEligible() {
        let state = finishedCall()
        installEligibleLocalCall(state)
        #expect(state.canRetranscribeLocally)
    }

    @Test("retention follows the opt-in toggle")
    func retentionRequiresOptIn() {
        #expect(!AppState.shouldRetainSessionAudio(
            engine: .local,
            hasAssemblyAI: false,
            assemblyDiarization: false,
            localFinalPassEnabled: false))
        #expect(AppState.shouldRetainSessionAudio(
            engine: .local,
            hasAssemblyAI: false,
            assemblyDiarization: false,
            localFinalPassEnabled: true))
        #expect(AppState.shouldRetainSessionAudio(
            engine: .local,
            hasAssemblyAI: false,
            assemblyDiarization: false,
            serverDiarization: true,
            localFinalPassEnabled: false))
    }

    @Test("pause invalidates linear final-pass time and releases unshared PCM")
    func pauseInvalidatesFinalPass() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        installEligibleLocalCall(state)
        state.pauseRecording()
        state.resumeRecording()
        state.applyTestWorkspace(recording: false)
        #expect(!state.canRetranscribeLocally)
        #expect(state.retainedAudioSampleCountForTesting == 0)
    }

    @Test("accepted refinement keeps PCM needed by opted-in diarization")
    func assemblyConsumerKeepsAudio() {
        #expect(!AppState.shouldReleaseRetainedAudioAfterLocalFinalPass(
            hasAssemblyAI: true,
            assemblyDiarization: true))
        #expect(AppState.shouldReleaseRetainedAudioAfterLocalFinalPass(
            hasAssemblyAI: false,
            assemblyDiarization: true))
        #expect(AppState.shouldReleaseRetainedAudioAfterLocalFinalPass(
            hasAssemblyAI: true,
            assemblyDiarization: false))
        #expect(!AppState.shouldReleaseRetainedAudioAfterLocalFinalPass(
            hasAssemblyAI: false,
            assemblyDiarization: false,
            serverDiarization: true))
    }

    @Test("PCM retained only for diarization does not authorize Local replacement")
    func sharedPCMDoesNotOptInFinalPass() {
        let state = finishedCall()
        let start = Date(timeIntervalSinceReferenceDate: 30_000)
        state.transcript = [TranscriptEntry(
            source: .system,
            text: (0..<20).map { "word\($0)" }.joined(separator: " "),
            timestamp: start,
            transcriptionEngine: .local)]
        state.applyTestLocalFinalPassRetention(
            samples: AudioFixtures.voicedInt16(
                count: 2 * LocalFinalPass.sampleRate),
            startedAt: start,
            preparedModel: "base",
            optedIn: false,
            serverDiarizationEligible: true)

        #expect(state.retainedAudioSampleCountForTesting > 0)
        #expect(!state.canRetranscribeLocally)
    }

    @Test("accepted final pass keeps PCM for signed-in server diarization")
    func serverConsumerKeepsAudioAfterPass() async {
        let words = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let service = ImmediateLocalFinalPassTranscriber(words)
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        let start = Date(timeIntervalSinceReferenceDate: 31_000)
        state.transcript = [TranscriptEntry(
            source: .system,
            text: words,
            timestamp: start,
            transcriptionEngine: .local)]
        state.applyTestLocalFinalPassRetention(
            samples: AudioFixtures.voicedInt16(
                count: 2 * LocalFinalPass.sampleRate),
            startedAt: start,
            preparedModel: "base",
            serverDiarizationEligible: true)

        state.retranscribeLocallyNow()
        for _ in 0..<10_000 {
            if !state.localRetranscribing { break }
            await Task.yield()
        }
        #expect(!state.localRetranscribing)
        #expect(state.retainedAudioSampleCountForTesting > 0)
        #expect(state.transcript.contains { $0.text == words })
    }

    @Test("Clear cancels and revision-blocks a non-cooperative manual pass")
    func clearCancelsManualPass() async {
        let service = BlockingLocalFinalPassTranscriber()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        installEligibleLocalCall(state)
        state.retranscribeLocallyNow()
        #expect(await service.waitUntilStarted())

        state.clearAll()
        await service.release((0..<20).map { "word\($0)" }.joined(separator: " "))
        await Task.yield()
        #expect(state.transcript.isEmpty)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.localRetranscribing)
    }

    @Test("accepted final pass releases PCM with no other opted-in consumer")
    func acceptedPassReleasesAudio() async {
        let words = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let service = ImmediateLocalFinalPassTranscriber(words)
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        installEligibleLocalCall(state)

        state.retranscribeLocallyNow()
        for _ in 0..<10_000 {
            if !state.localRetranscribing { break }
            await Task.yield()
        }
        #expect(!state.localRetranscribing)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(state.transcript.contains { $0.text == words })
    }

    @Test("decoder failure preserves live text and releases unshared PCM")
    func failedPassReleasesAudio() async {
        let service = ImmediateLocalFinalPassTranscriber("")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        installEligibleLocalCall(state)
        let live = state.transcript

        state.retranscribeLocallyNow()
        for _ in 0..<10_000 {
            if !state.localRetranscribing { break }
            await Task.yield()
        }
        #expect(state.transcript == live)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.canRetranscribeLocally)
    }

    @Test("quality refusal preserves live text and releases unshared PCM")
    func refusedPassReleasesAudio() async {
        let service = ImmediateLocalFinalPassTranscriber("word0 word1")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        installEligibleLocalCall(state)
        let live = state.transcript

        state.retranscribeLocallyNow()
        for _ in 0..<10_000 {
            if !state.localRetranscribing { break }
            await Task.yield()
        }
        #expect(state.transcript == live)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.canRetranscribeLocally)
    }

    @Test("restore-style invalidation cancels an automatic pass")
    func clearCancelsAutomaticPass() async {
        let service = BlockingLocalFinalPassTranscriber()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            localFinalPassServiceFactory: { _, _ in service })
        state.applyTestWorkspace(recording: false)
        installEligibleLocalCall(state)
        let task = state.scheduleAutomaticLocalFinalPass(after: nil, enabled: true)
        #expect(await service.waitUntilStarted())

        state.clearAll()
        await service.release((0..<20).map { "word\($0)" }.joined(separator: " "))
        await task?.value
        #expect(state.transcript.isEmpty)
        #expect(state.retainedAudioSampleCountForTesting == 0)
        #expect(!state.localRetranscribing)
    }

    @Test("refuses while a call is still live")
    func refusesWhileRecording() {
        // Re-reading audio that is still being written would race the capture
        // and produce a transcript of half a meeting.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        #expect(!state.canRetranscribeLocally)
    }

    @Test("refuses while paused, because the call has not finished")
    func refusesWhilePaused() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.pauseRecording()
        // A paused call is still live: more audio is coming.
        #expect(!state.canRetranscribeLocally)
    }

    @Test("refuses when there is no recorded audio")
    func refusesWithoutAudio() {
        // An imported Fireflies session, or a workspace that only ever ran
        // prompts, has a transcript but no audio to re-read.
        let state = finishedCall()
        #expect(!state.canRetranscribeLocally)
    }

    @Test("refuses while diarization is already rewriting the transcript")
    func refusesDuringDiarization() {
        let state = finishedCall()
        state.diarizing = true
        // Two passes rewriting the same transcript would race, and the loser's
        // result would silently win.
        #expect(!state.canRetranscribeLocally)
    }

    @Test("refuses while another local pass is running")
    func refusesWhenAlreadyRunning() {
        let state = finishedCall()
        state.localRetranscribing = true
        #expect(!state.canRetranscribeLocally)
    }

    @Test("running it when refused is a no-op rather than a crash")
    func runningWhenRefusedIsSafe() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.retranscribeLocallyNow()
        // The guard is checked again inside the task, so a caller that skipped
        // canRetranscribeLocally cannot start one anyway.
        #expect(!state.localRetranscribing)
    }

    @Test("only offered when the local engine is the one in use")
    func onlyForTheLocalEngine() {
        // Re-running Whisper over a call transcribed by Deepgram or the server
        // would replace a better transcript with a worse one — the opposite of
        // the point.
        let previous = Config.transcriptionEngineValue
        defer { Config.transcriptionEngineValue = previous }

        let state = finishedCall()
        Config.transcriptionEngineValue = .deepgram
        #expect(!state.canRetranscribeLocally)
    }

}
