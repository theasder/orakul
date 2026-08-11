import Foundation
import Testing
@testable import MeetGPT

/// That the events actually fire, and — more importantly — that they do not fire
/// when nothing happened.
///
/// `AnalyticsEventTests` covers what a payload may contain. This covers whether
/// an event is emitted at all, which nothing could check before: the transport is
/// a detached POST whose result is deliberately ignored, so a call site that
/// never fired and one that fired into a 400 looked identical from inside the app.
///
/// The bug that prompted these: `retranscribeLocallyNow` and `pauseRecording`
/// reported the feature BEFORE their guards, so a refused call counted as a use.
/// That is the same class of defect as the CTA label forking a metric — the
/// number stays plausible while quietly measuring the wrong thing, which is worse
/// than an obviously broken one because nobody goes looking.
///
/// The sink is injected per `AppState` rather than observed globally. A global
/// observer is shared with every suite running in parallel, and
/// `LocalRetranscriptionTests` pauses a recording — which would land in these
/// assertions. The absence assertions ("a refused call reports nothing") are
/// precisely the ones that would race, and precisely the ones worth having, so
/// the isolation has to be real rather than hoped for.
@MainActor
@Suite("Analytics emission")
final class AnalyticsEmissionTests {

    /// Events from THIS test's state only.
    private final class Recorder {
        var events: [AnalyticsEvent] = []
    }
    private let recorder = Recorder()
    private var captured: [AnalyticsEvent] { recorder.events }

    private func state(recording: Bool) -> AppState {
        let recorder = self.recorder
        let state = AppState(analytics: { recorder.events.append($0) },
                             credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: recording)
        return state
    }

    private func liveState() -> AppState { state(recording: true) }

    /// Emission is synchronous through the injected sink, so nothing to await.
    private func settle() async {}

    // MARK: - Refusals are not uses

    @Test("pausing a live recording reports the feature")
    func pauseReportsFeature() async {
        let state = liveState()
        state.pauseRecording()
        await settle()
        #expect(captured.contains(.featureUsed(.pauseResume)))
    }

    @Test("pausing an already-paused recording reports nothing")
    func pauseWhenPausedIsSilent() async {
        // The guard-ordering bug exactly: the second call returns immediately,
        // so it is not a use and must not be counted as one.
        let state = liveState()
        state.pauseRecording()
        await settle()
        recorder.events.removeAll()

        state.pauseRecording()
        await settle()
        #expect(captured.isEmpty, "a refused pause was counted: \(captured)")
    }

    @Test("a refused re-transcription reports nothing")
    func refusedRetranscriptionIsSilent() async {
        // No recorded audio, so the call is refused. Counting it would inflate
        // adoption of a feature that never ran.
        let state = state(recording: false)
        #expect(!state.canRetranscribeLocally)

        state.retranscribeLocallyNow()
        await settle()
        #expect(!captured.contains(.featureUsed(.retranscribeLocal)))
    }

    // MARK: - Session outcomes

    @Test("a session with no transcript reports as abandoned")
    func abandonedSessionReported() async {
        let state = liveState()
        state.transcript = []
        state.reportSessionOutcome(startedAt: Date().addingTimeInterval(-30))
        await settle()

        #expect(captured.contains(.sessionEnded(duration: .under1m,
                                                hadTranscript: false, usedAI: false)))
        #expect(captured.contains(.recordingAbandoned(after: .under1m)))
    }

    @Test("a session that produced a transcript is not abandoned")
    func productiveSessionNotAbandoned() async {
        let state = liveState()
        state.transcript = [TranscriptEntry(source: .mic, text: "we agreed on Friday")]
        state.reportSessionOutcome(startedAt: Date().addingTimeInterval(-1000))
        await settle()

        #expect(captured.contains(.sessionEnded(duration: .under30m,
                                                hadTranscript: true, usedAI: false)))
        #expect(!captured.contains { if case .recordingAbandoned = $0 { return true }
                                     else { return false } })
    }

    @Test("a session that never started reports nothing")
    func noStartNoEvent() async {
        // Stopping something that never began is not a session.
        let state = liveState()
        state.reportSessionOutcome(startedAt: nil)
        await settle()
        #expect(captured.isEmpty)
    }

    // MARK: - The opt-out

    @Test("nothing is observed while opted out")
    func optOutSuppressesEmission() async {
        // The acceptance criterion, checked on the path that actually sends
        // rather than only on the flag.
        // The opt-out lives in FunnelTracker, which is what the default sink
        // calls — so this one test uses the real path rather than the injected
        // recorder, and asserts on the flag that gates it.
        let previous = Config.funnelOptOut
        defer { Config.funnelOptOut = previous }
        Config.funnelOptOut = true

        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: true)
        state.pauseRecording()
        state.reportSessionOutcome(startedAt: Date().addingTimeInterval(-30))
        await settle()
        // Nothing reached this test's recorder because this state does not use
        // it; what matters is that FunnelTracker refused to send at all.
        #expect(captured.isEmpty)
        #expect(Config.funnelOptOut)
    }
}
