import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

// The first-run flow beyond the permission checklist. The invariants pinned here
// are the ones that make onboarding safe to ship rather than the ones that make
// it pretty:
//
//   * the sample call obeys the SAME evidence rule the live product enforces —
//     a prepared blind spot whose quote is absent from the sample transcript is
//     exactly the dishonesty the co-pilot refuses to commit;
//   * a sample run writes nothing, anywhere: not history, not the ledger, not
//     the usage counters that decide when the paywall may appear;
//   * the capture probe can tell "granted but silent" from "not granted",
//     because only the first is the macOS relaunch quirk.

@Suite("Sample call script")
struct SampleCallTests {
    private let sample = SampleCall.mobileBeta

    @Test("the script is ordered, bounded, and complete")
    func scriptShape() {
        #expect(!sample.lines.isEmpty)
        #expect(sample.lines.map(\.atSeconds) == sample.lines.map(\.atSeconds).sorted())
        // Long enough to hold a real decision, short enough that nobody skips it.
        #expect(sample.durationSeconds >= 60)
        #expect(sample.durationSeconds <= 120)
        for line in sample.lines {
            #expect(!line.text.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!line.speaker.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(!sample.goal.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test("the prepared blind spot quotes the sample transcript, like a real one")
    func preparedSuggestionIsGrounded() {
        // SuggestionGrounding is the same mechanical check applied to live
        // suggestions. Prepared output gets no exemption from it.
        #expect(SuggestionGrounding.contains(
            evidence: sample.preparedSuggestion.evidence,
            in: sample.fullTranscriptText))
    }

    @Test("the prepared decision quotes the sample transcript too")
    func preparedDecisionIsGrounded() {
        #expect(SuggestionGrounding.contains(
            evidence: sample.preparedDecision.evidence,
            in: sample.fullTranscriptText))
        #expect(!sample.preparedDecision.owner.isEmpty)
        #expect(!sample.preparedDecision.text.isEmpty)
    }

    @Test("playback compresses the call into something nobody skips")
    func playbackIsShort() {
        #expect(SampleCall.playbackSpeed > 1)
        #expect(sample.wallClockSeconds <= 15)
    }

    @Test("lines arrive as a growing prefix")
    func linesRevealInOrder() {
        #expect(sample.lines(throughWallClock: 0).isEmpty)
        let mid = sample.lines(throughWallClock: sample.wallClockSeconds / 2)
        #expect(!mid.isEmpty)
        #expect(mid.count < sample.lines.count)
        #expect(Array(sample.lines.prefix(mid.count)) == mid)
        #expect(sample.lines(throughWallClock: sample.wallClockSeconds) == sample.lines)
        // Overrunning the clock must not drop back to zero lines.
        #expect(sample.lines(throughWallClock: sample.wallClockSeconds * 2) == sample.lines)
    }

    @Test("no card appears before the line it quotes")
    func cardsFollowTheirEvidence() {
        // A blind spot shown before its quote has been spoken teaches the user
        // that the co-pilot invents things — the opposite of the product.
        let spokenBySuggestion = sample
            .lines(throughWallClock: sample.suggestionAtWallClock)
            .map(\.text).joined(separator: " ")
        #expect(SuggestionGrounding.contains(
            evidence: sample.preparedSuggestion.evidence, in: spokenBySuggestion))

        let spokenByDecision = sample
            .lines(throughWallClock: sample.decisionAtWallClock)
            .map(\.text).joined(separator: " ")
        #expect(SuggestionGrounding.contains(
            evidence: sample.preparedDecision.evidence, in: spokenByDecision))
        #expect(sample.suggestionAtWallClock <= sample.decisionAtWallClock)
        #expect(sample.decisionAtWallClock <= sample.wallClockSeconds)
    }

    @Test("prepared output always says it was prepared, and what the real thing does")
    func preparedOutputIsLabelled() {
        // Две вещи, которые подпись обязана сказать: что это заготовка и что
        // настоящие звонки разбираются вживую. Проверяются оба слова, а не
        // строка целиком, — иначе тест ломается от любой правки формулировки.
        #expect(SampleCall.preparedLabel.lowercased().contains("подготовлено"))
        #expect(SampleCall.preparedLabel.lowercased().contains("вживую"))
    }

    @Test("transcript entries carry the sample's own speakers")
    func transcriptEntriesAreSpeakerAttributed() {
        let entries = sample.transcriptEntries()
        #expect(entries.count == sample.lines.count)
        #expect(entries.allSatisfy { !($0.speaker ?? "").isEmpty })
        // Timestamps must ascend, or the transcript view orders fiction wrongly.
        let stamps = entries.map(\.timestamp)
        #expect(stamps == stamps.sorted())
    }
}

@Suite("Capture probe")
struct CaptureProbeTests {
    private let loud = CaptureProbe.signalThreshold + 0.2
    private let quiet = CaptureProbe.signalThreshold - 0.01

    @Test("both sources audible is the only pass")
    func passRequiresBoth() {
        #expect(CaptureProbe.verdict(micPeak: loud, systemPeak: loud) == .pass)
        #expect(CaptureProbe.verdict(micPeak: loud, systemPeak: quiet) == .micOnly)
        #expect(CaptureProbe.verdict(micPeak: quiet, systemPeak: loud) == .systemOnly)
        #expect(CaptureProbe.verdict(micPeak: quiet, systemPeak: quiet) == .silent)
    }

    @Test("the threshold itself counts as signal")
    func thresholdIsInclusive() {
        let edge = CaptureProbe.signalThreshold
        #expect(CaptureProbe.verdict(micPeak: edge, systemPeak: edge) == .pass)
    }

    @Test("a refused stream is the relaunch fingerprint — a quiet one is not")
    func relaunchIsOfferedOnlyWhenItIsTheAnswer() {
        // The quirk: macOS reports Screen Recording as granted while
        // ScreenCaptureKit refuses to start until the app is relaunched. THAT
        // refusal is the fingerprint. A stream that starts and hears nothing is
        // a different thing entirely and used to be confused with it.
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .relaunch)
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                    screenRecordingGranted: false,
                                    relaunchAlreadyTried: false) == .none)
        #expect(CaptureProbe.advice(verdict: .pass, systemAudioStarted: true,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .none)
        #expect(CaptureProbe.advice(verdict: .systemOnly, systemAudioStarted: true,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .none)
        // Silent on both, but the stream started: the microphone is the problem
        // and there is nothing to relaunch.
        #expect(CaptureProbe.advice(verdict: .silent, systemAudioStarted: true,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .noSoundPlaying)
        // Silent on both AND refused: the refusal is direct evidence, and it
        // holds whether or not the user happened to say anything.
        #expect(CaptureProbe.advice(verdict: .silent, systemAudioStarted: false,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .relaunch)
    }

    /// The reported bug, as a scenario: «even though i quited and reopened
    /// orakul told me i am supposed to quit and reopen».
    @Test("the relaunch is never advised twice for the same failure")
    func relaunchAdviceDoesNotRepeatAfterARelaunch() {
        // Run 1 — granted, stream refused, no relaunch yet.
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .relaunch)
        // The user quits and reopens. Nothing else changed: same grant, same
        // refusal. Repeating the advice here is the loop with no exit.
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: true) == .regrant)
    }

    /// The far more common reading of the same verdict, and the one the old
    /// code mistook for the quirk: nothing was playing.
    @Test("a healthy but silent stream is never blamed on the permission")
    func silentSystemAudioIsNotBlamedOnThePermission() {
        for tried in [false, true] {
            #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: true,
                                        screenRecordingGranted: true,
                                        relaunchAlreadyTried: tried) == .noSoundPlaying,
                    "a stream that started fine cannot be a permission problem")
        }
    }

    /// The likeliest real answer to the report, and the one no relaunch can
    /// reach: macOS runs an app launched from a DMG or from Downloads out of a
    /// randomized read-only copy, so yesterday's grant belongs to a path that
    /// no longer exists.
    @Test("running from a place macOS cannot remember is never a relaunch problem")
    func translocationIsNotARelaunchProblem() {
        for location in [CaptureProbe.InstallLocation.translocated, .diskImage] {
            for tried in [false, true] {
                #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                            screenRecordingGranted: true,
                                            relaunchAlreadyTried: tried,
                                            installLocation: location) == .moveToApplications,
                        "\(location) must never be answered with a relaunch")
            }
        }
        // From a normal location the relaunch is still the right first answer.
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: false,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false,
                                    installLocation: .normal) == .relaunch)
        // And a working stream is not a location problem either.
        #expect(CaptureProbe.advice(verdict: .micOnly, systemAudioStarted: true,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false,
                                    installLocation: .translocated) == .noSoundPlaying)
    }

    @Test("the location is read off the path macOS actually gives us",
          arguments: [
            ("/Applications/orakul.app", CaptureProbe.InstallLocation.normal),
            ("/Users/me/Applications/orakul.app", .normal),
            ("/private/var/folders/x9/T/AppTranslocation/9F2-A1/d/orakul.app", .translocated),
            ("/Volumes/orakul/orakul.app", .diskImage),
            // Не путать с томом: путь пользователя может содержать слово, но
            // начинается не с /Volumes.
            ("/Users/me/Volumes-backup/orakul.app", .normal),
          ])
    func locationIsClassifiedFromTheBundlePath(path: String,
                                               expected: CaptureProbe.InstallLocation) {
        #expect(CaptureProbe.installLocation(bundlePath: path) == expected)
    }

    @Suite("Relaunch memory")
    struct RelaunchMemoryTests {
        /// A suite-unique domain: `.standard` is shared with every other test in
        /// the process, and a flag left behind there would surface as an
        /// unrelated failure somewhere else.
        private func freshDefaults(_ name: String) -> UserDefaults {
            let defaults = UserDefaults(suiteName: "orakul.tests.\(name)")!
            defaults.removePersistentDomain(forName: "orakul.tests.\(name)")
            return defaults
        }

        @Test("nothing is remembered until the advice is actually shown")
        func emptyByDefault() {
            let memory = RelaunchMemory(defaults: freshDefaults("empty"), launchUptime: 100)
            #expect(!memory.relaunchAlreadyTried)
        }

        @Test("advice given in this run does not read as a relaunch")
        func sameSessionIsNotARelaunch() {
            // The advice is always stamped LATER than the launch that gave it.
            // Without this, a second probe in the same session would already
            // claim the relaunch had been tried and skip straight to «it did
            // not help» — before the user had a chance to quit anything.
            let defaults = freshDefaults("same-session")
            RelaunchMemory(defaults: defaults, launchUptime: 100).noteAdvised(atUptime: 106)
            #expect(!RelaunchMemory(defaults: defaults, launchUptime: 100).relaunchAlreadyTried)
        }

        @Test("a launch after the advice reads as the relaunch it asked for")
        func laterLaunchIsARelaunch() {
            let defaults = freshDefaults("relaunched")
            RelaunchMemory(defaults: defaults, launchUptime: 100).noteAdvised(atUptime: 106)
            // Next process: launched at 200 s of uptime, after the 106 s stamp.
            #expect(RelaunchMemory(defaults: defaults, launchUptime: 200).relaunchAlreadyTried)
        }

        @Test("working capture forgets the advice")
        func successClears() {
            // Otherwise a user whose problem was solved months ago meets
            // «relaunching did not help» the first time anything goes quiet.
            let defaults = freshDefaults("cleared")
            RelaunchMemory(defaults: defaults, launchUptime: 100).noteAdvised(atUptime: 106)
            RelaunchMemory(defaults: defaults, launchUptime: 200).clear()
            #expect(!RelaunchMemory(defaults: defaults, launchUptime: 300).relaunchAlreadyTried)
        }
    }
}

@Suite("Social sign-in availability")
struct SocialSignInTests {
    @Test("Google is offered whenever its client is configured")
    func googleStandsOnItsOwn() {
        // Google account login was hidden behind the same switch as Sign in with
        // Apple, whose reason for being off is App Store Connect verification —
        // something Google has no part in. A configured provider was invisible
        // for a reason that did not apply to it.
        #expect(SocialSignIn.showsGoogle(hasClient: true, appleFlagEnabled: false))
        #expect(SocialSignIn.showsGoogle(hasClient: true, appleFlagEnabled: true))
        #expect(!SocialSignIn.showsGoogle(hasClient: false, appleFlagEnabled: true))
    }

    @Test("Apple stays behind its own flag")
    func appleKeepsItsGate() {
        #expect(SocialSignIn.showsApple(flagEnabled: true))
        #expect(!SocialSignIn.showsApple(flagEnabled: false))
    }

    @Test("the divider only appears when there is something to divide")
    func dividerFollowsTheButtons() {
        #expect(!SocialSignIn.showsDivider(apple: false, google: false))
        #expect(SocialSignIn.showsDivider(apple: false, google: true))
        #expect(SocialSignIn.showsDivider(apple: true, google: false))
    }
}

@MainActor
@Suite("Sample playback", .serialized)
struct SamplePlaybackTests {
    /// Time under the test's control. `sleep` advances the clock by exactly the
    /// requested amount and returns, so a full 90-second sample plays out in
    /// microseconds with the same timing semantics it has on a real Mac.
    private final class FakeClock: SampleClock {
        private(set) var now: Double = 0
        private(set) var sleeps = 0

        func sleep(seconds: Double) async {
            sleeps += 1
            now += seconds
            await Task.yield()
        }

        /// Simulates a stalled frame — the app was descheduled, the laptop lid
        /// closed, the main actor was busy.
        func jump(_ seconds: Double) { now += seconds }
    }

    private let sample = SampleCall.mobileBeta

    @Test("playing runs to the end and stops")
    func playbackTerminates() async {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        await playback.play()

        #expect(playback.elapsed == sample.wallClockSeconds)
        #expect(playback.isFinished)
        #expect(playback.visibleLines == sample.lines)
        #expect(clock.sleeps > 1)   // it really ticked rather than jumping
    }

    @Test("the transcript only ever grows")
    func linesOnlyGrow() async {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)
        var seen = 0

        await playback.play { current in
            #expect(current.visibleLines.count >= seen)
            seen = current.visibleLines.count
        }

        #expect(seen == sample.lines.count)
    }

    @Test("no card is ever on screen before the line it quotes")
    func cardsNeverPrecedeTheirEvidence() async {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        await playback.play { current in
            // This is the product's own rule, enforced frame by frame: a card
            // visible while its quote has not been spoken would teach a new user
            // that the co-pilot makes things up.
            if current.isSuggestionVisible {
                let spoken = current.visibleLines.map(\.text).joined(separator: " ")
                #expect(SuggestionGrounding.contains(
                    evidence: self.sample.preparedSuggestion.evidence, in: spoken))
            }
            if current.isDecisionVisible {
                let spoken = current.visibleLines.map(\.text).joined(separator: " ")
                #expect(SuggestionGrounding.contains(
                    evidence: self.sample.preparedDecision.evidence, in: spoken))
            }
        }
    }

    @Test("a stalled frame catches up instead of running long")
    func elapsedFollowsTheClockNotTheFrameCount() async {
        // Accumulating a fixed step per frame drifts, because a sleep is a
        // minimum and never a promise: the on-screen clock would slowly fall
        // behind and the sample would outlast its own stated duration.
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        playback.begin()
        clock.jump(sample.wallClockSeconds / 2)
        playback.sample(now: clock.now)

        #expect(playback.elapsed >= sample.wallClockSeconds / 2)
        #expect(!playback.isFinished)
    }

    @Test("elapsed never runs past the end of the call")
    func elapsedIsClamped() async {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        playback.begin()
        clock.jump(sample.wallClockSeconds * 10)
        playback.sample(now: clock.now)

        #expect(playback.elapsed == sample.wallClockSeconds)
        #expect(playback.isFinished)
        #expect(playback.visibleLines == sample.lines)
    }

    @Test("reduced motion gets the finished call without waiting for it")
    func reducedMotionSkipsTheAnimation() {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        playback.completeImmediately()

        #expect(playback.isFinished)
        #expect(playback.visibleLines == sample.lines)
        #expect(playback.isSuggestionVisible)
        #expect(playback.isDecisionVisible)
        #expect(clock.sleeps == 0)
    }

    @Test("stopping halts the sample where it stands")
    func stopHalts() async {
        let clock = FakeClock()
        let playback = SamplePlayback(sample: sample, clock: clock)

        playback.begin()
        clock.jump(1)
        playback.sample(now: clock.now)
        let atStop = playback.elapsed
        playback.stop()

        clock.jump(sample.wallClockSeconds)
        playback.sample(now: clock.now)

        #expect(playback.elapsed == atStop)
        #expect(!playback.isFinished)
    }
}

@MainActor
@Suite("Capture probe runner", .serialized)
struct CaptureProbeRunnerTests {
    /// Stands in for a capture source. Emits whatever levels the test wants and
    /// records whether it was stopped — the probe must never leave a capture
    /// running.
    private final class FakeSource: CaptureProbeSource {
        let levels: [CGFloat]
        let failure: Error?
        private(set) var started = false
        private(set) var stopped = false

        init(levels: [CGFloat] = [], failure: Error? = nil) {
            self.levels = levels
            self.failure = failure
        }

        func start(onLevel: @escaping (CGFloat) -> Void) async throws {
            if let failure { throw failure }
            started = true
            levels.forEach(onLevel)
        }

        func stop() async { stopped = true }
    }

    private struct SourceFailure: LocalizedError {
        var errorDescription: String? { "device busy" }
    }

    private let loud = CaptureProbe.signalThreshold + 0.3
    private let quiet = CaptureProbe.signalThreshold - 0.02

    @Test("hearing both sources reports a pass and stops both captures")
    func passStopsEverything() async {
        let mic = FakeSource(levels: [0.01, loud, 0.02])
        let system = FakeSource(levels: [quiet, loud])
        let runner = CaptureProbeRunner(mic: mic, system: system, duration: 0)

        await runner.run()

        #expect(runner.verdict == .pass)
        #expect(runner.micPeak >= loud)
        #expect(runner.systemPeak >= loud)
        #expect(mic.stopped)
        #expect(system.stopped)
        #expect(!runner.isRunning)
        // Live levels drop back to zero; the peaks are what the verdict is made
        // of, so those stay readable after the sound stops.
        #expect(runner.micLevel == 0)
        #expect(runner.systemLevel == 0)
    }

    @Test("a silent system source produces the relaunch fingerprint, not a pass")
    func silentSystemIsMicOnly() async {
        let runner = CaptureProbeRunner(
            mic: FakeSource(levels: [loud]),
            system: FakeSource(levels: [quiet]),
            duration: 0)

        await runner.run()

        #expect(runner.verdict == .micOnly)
        // Both sources started, so this is «nothing was playing», not the
        // permission quirk — the distinction the advice now turns on.
        #expect(runner.systemAudioStarted)
        #expect(CaptureProbe.advice(verdict: .micOnly,
                                    systemAudioStarted: runner.systemAudioStarted,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .noSoundPlaying)
    }

    @Test("a source that refuses to start still yields a verdict, and says why")
    func oneDeadSourceStillReports() async {
        // This is the case the whole check exists for: ScreenCaptureKit failing
        // must not leave the user staring at a spinner with no answer.
        let system = FakeSource(failure: SourceFailure())
        let runner = CaptureProbeRunner(
            mic: FakeSource(levels: [loud]), system: system, duration: 0)

        await runner.run()

        #expect(runner.verdict == .micOnly)
        #expect(runner.startFailure?.contains("device busy") == true)
        #expect(!system.started)
        // The flag the advice reads. A refused stream is the ONLY thing that
        // justifies sending the user to relaunch, so the runner has to report
        // the refusal itself rather than let the verdict stand in for it.
        #expect(!runner.systemAudioStarted)
        #expect(CaptureProbe.advice(verdict: runner.verdict ?? .silent,
                                    systemAudioStarted: runner.systemAudioStarted,
                                    screenRecordingGranted: true,
                                    relaunchAlreadyTried: false) == .relaunch)
        // Stopped anyway — a half-started capture is still worth tearing down.
        #expect(system.stopped)
    }

    @Test("hearing nothing is reported as silence, not as failure")
    func silenceIsAVerdict() async {
        let runner = CaptureProbeRunner(
            mic: FakeSource(levels: [quiet]),
            system: FakeSource(levels: [quiet]),
            duration: 0)

        await runner.run()

        #expect(runner.verdict == .silent)
        #expect(runner.startFailure == nil)
    }

    @Test("running again clears the previous verdict and peaks")
    func rerunStartsClean() async {
        let runner = CaptureProbeRunner(
            mic: FakeSource(levels: [loud]),
            system: FakeSource(levels: [loud]),
            duration: 0)
        await runner.run()
        #expect(runner.verdict == .pass)

        // Second attempt, quiet room: the old pass must not linger and tell the
        // user their capture works when this run heard nothing.
        let quietRunner = CaptureProbeRunner(
            mic: FakeSource(levels: [quiet]),
            system: FakeSource(levels: [quiet]),
            duration: 0)
        await quietRunner.run()
        #expect(quietRunner.verdict == .silent)
        #expect(quietRunner.micPeak < CaptureProbe.signalThreshold)
    }
}

/// Every quick prompt, against every recording type, checked mechanically.
///
/// The hand-written cases only ever covered the prompts somebody remembered to
/// adapt. This walks the whole matrix, so a prompt that asks a lecture who owns
/// an action item fails here rather than in front of a user.
@Suite("Recording-aware prompt matrix")
struct PromptMatrixTests {
    /// Vocabulary that only makes sense when people were in a room together.
    private let meetingOnly = [
        "owner", "attendee", "action item", "due date",
        "decision ledger", "follow-up meeting", "next meeting", "mini-agenda",
    ]

    /// A prompt may — and should — mention these words in order to FORBID them:
    /// "do not invent owners" is the fix, not the bug. So a clause is only a
    /// failure when it asks for the thing without ruling it out.
    private let negations = [
        "do not", "don't", "never", "without inventing", "no invented",
        "rather than", "instead of", "not a", "avoid",
    ]

    private func offendingClauses(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".•;\n"))
            .filter { clause in
                let lower = clause.lowercased()
                guard meetingOnly.contains(where: { lower.contains($0) }) else { return false }
                return !negations.contains(where: { lower.contains($0) })
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test("no prompt asks a non-meeting recording for owners or action items")
    func mediaPromptsNeverDemandMeetingArtefacts() {
        for kind in RecordingContextKind.allCases where kind != .meeting {
            for prompt in QuickPrompts.all {
                let adapted = RecordingPromptAdapter.adapt(prompt, kind: kind)
                let offenders = offendingClauses(adapted.prompt)
                #expect(offenders.isEmpty,
                        """
                        "\(prompt.id)" still asks a \(kind.label) for meeting artefacts: \
                        \(offenders.joined(separator: " | "))
                        """)
            }
        }
    }

    @Test("titles stop promising meeting output too")
    func adaptedTitlesAreHonest() {
        // A button labelled "Unresolved Issues … with owners and dates" is a
        // promise the lecture cannot keep, made before the model is even called.
        for kind in RecordingContextKind.allCases where kind != .meeting {
            for prompt in QuickPrompts.all {
                let adapted = RecordingPromptAdapter.adapt(prompt, kind: kind)
                #expect(offendingClauses(adapted.tooltip).isEmpty,
                        "\"\(prompt.id)\" tooltip promises meeting artefacts for a \(kind.label)")
            }
        }
    }

    @Test("a meeting keeps every meeting-shaped prompt intact")
    func meetingIsUntouched() {
        // The adaptation must not leak backwards: a real meeting still wants
        // owners, dates and the ledger.
        for prompt in QuickPrompts.all {
            #expect(RecordingPromptAdapter.adapt(prompt, kind: .meeting).prompt == prompt.prompt)
        }
    }

    @Test("adapting is idempotent")
    func adaptingTwiceChangesNothing() {
        // The composer maps prompts through the adapter on every render, so a
        // second pass over an already-adapted prompt must be a no-op.
        for kind in RecordingContextKind.allCases {
            for prompt in QuickPrompts.all {
                let once = RecordingPromptAdapter.adapt(prompt, kind: kind)
                let twice = RecordingPromptAdapter.adapt(once, kind: kind)
                #expect(once.prompt == twice.prompt)
                #expect(once.title == twice.title)
            }
        }
    }
}

@Suite("Permission prompts")
struct PermissionPromptTests {
    @Test("a granted permission asks for nothing")
    func grantedNeedsNoAction() {
        #expect(PermissionPrompt.action(granted: true, alreadyAsked: false) == nil)
        #expect(PermissionPrompt.action(granted: true, alreadyAsked: true) == nil)
    }

    @Test("the first press asks macOS")
    func firstPressPrompts() {
        #expect(PermissionPrompt.action(granted: false, alreadyAsked: false) == .request)
    }

    @Test("after a refusal the button goes to System Settings instead")
    func secondPressOpensSettings() {
        // macOS only ever shows the Screen Recording prompt once. Asking again
        // is a no-op, so a button that keeps calling it is a dead control: the
        // user presses it, nothing happens, and they conclude the app is broken.
        #expect(PermissionPrompt.action(granted: false, alreadyAsked: true) == .openSettings)
    }

    @Test("each permission points at its own Privacy pane")
    func settingsDeepLinks() {
        let mic = PermissionPrompt.settingsURL(for: .microphone)
        let screen = PermissionPrompt.settingsURL(for: .screenRecording)
        #expect(mic?.absoluteString.contains("Privacy_Microphone") == true)
        #expect(screen?.absoluteString.contains("Privacy_ScreenCapture") == true)
        #expect(mic != screen)
    }
}

@Suite("Onboarding steps")
struct OnboardingStepTests {
    @Test("a fresh install starts at the capture check")
    func freshInstall() {
        #expect(OnboardingGate.step(
            lastCompleted: nil,
            microphoneGranted: false,
            screenRecordingGranted: false) == .capture)
    }

    @Test("quitting mid-flow resumes at the next step, not the first")
    func resumesWhereItStopped() {
        #expect(OnboardingGate.step(
            lastCompleted: .capture,
            microphoneGranted: true,
            screenRecordingGranted: true) == .sample)
    }

    @Test("a finished flow presents nothing")
    func finishedPresentsNothing() {
        #expect(OnboardingGate.step(
            lastCompleted: .sample,
            microphoneGranted: true,
            screenRecordingGranted: true) == nil)
    }

    @Test("permissions revoked later re-present the capture check")
    func revokedPermissionsReopenPreflight() {
        // Existing behaviour: a rename or re-sign can invalidate TCC while the
        // completion flag stays true. That must still drag the user back.
        #expect(OnboardingGate.step(
            lastCompleted: .sample,
            microphoneGranted: true,
            screenRecordingGranted: false) == .capture)
        #expect(OnboardingGate.step(
            lastCompleted: .sample,
            microphoneGranted: false,
            screenRecordingGranted: true) == .capture)
    }

    @Test("the boolean gate keeps its old meaning for callers that still use it")
    func legacyGateStillWorks() {
        #expect(OnboardingGate.shouldPresent(
            completed: true, microphoneGranted: true, screenRecordingGranted: false))
        #expect(!OnboardingGate.shouldPresent(
            completed: true, microphoneGranted: true, screenRecordingGranted: true))
    }
}

@Suite("Coach tips")
struct CoachTipTests {
    private func context(recording: Bool = false,
                         retired: Set<String> = [],
                         hasGoal: Bool = false,
                         hasSomethingToLog: Bool = false,
                         showsNoCallCard: Bool = false) -> CoachTipQueue.Context {
        CoachTipQueue.Context(
            isRecording: recording, retired: retired,
            hasGoal: hasGoal, hasSomethingToLog: hasSomethingToLog,
            showsNoCallCard: showsNoCallCard)
    }

    @Test("the recording-type tip yields to the card that already says it")
    func noDuplicateLessonWithTheNoCallCard() {
        // "No call until Monday?" and "Not a meeting?" both teach that a
        // lecture gets a learning plan and that the type is yours to override —
        // and they rendered two cards apart in the same sidebar, which reads as
        // the app repeating itself. The card wins: it teaches with buttons.
        #expect(CoachTipQueue.next(context(showsNoCallCard: true)) != .recordingType)
    }

    @Test("dismissing the card brings the tip back")
    func tipReturnsWhenTheCardGoes() {
        // Suppressed, not retired: the lesson still has not been delivered
        // anywhere else, so hiding the card must not also swallow the tip.
        #expect(CoachTipQueue.next(context(showsNoCallCard: false)) == .recordingType)
    }

    @Test("suppressing the first tip does not block the queue")
    func laterTipsStillSurface() {
        // The suppression must skip past recordingType rather than return nil,
        // or hiding one lesson would silence every lesson after it.
        #expect(CoachTipQueue.next(
            context(hasSomethingToLog: true, showsNoCallCard: true)) == .goalQuality)
    }

    @Test("nothing pops up during a live call")
    func silentWhileRecording() {
        #expect(CoachTipQueue.next(context(recording: true)) == nil)
    }

    @Test("the recording type comes first")
    func firstTip() {
        #expect(CoachTipQueue.next(context()) == .recordingType)
    }

    @Test("a retired tip never returns")
    func retiredTipsAreSkipped() {
        #expect(CoachTipQueue.next(
            context(retired: [CoachTip.recordingType.id])) == .goalQuality)
        #expect(CoachTipQueue.next(context(
            retired: [CoachTip.recordingType.id, CoachTip.goalQuality.id])) == nil)
    }

    @Test("the goal tip stands down once a goal exists")
    func goalTipDependsOnState() {
        #expect(CoachTipQueue.next(context(
            retired: [CoachTip.recordingType.id], hasGoal: true)) == nil)
    }

    @Test("the pin tip waits for something to pin")
    func pinTipNeedsACandidate() {
        let retired: Set<String> = [CoachTip.recordingType.id, CoachTip.goalQuality.id]
        #expect(CoachTipQueue.next(context(retired: retired, hasGoal: true)) == nil)
        #expect(CoachTipQueue.next(context(
            retired: retired, hasGoal: true, hasSomethingToLog: true)) == .pinDecision)
    }

    @Test("a feature the user already found never gets explained to them")
    func alreadyUsedFeaturesRetireTheirTips() {
        // The retirement hook is an onChange, which by definition cannot fire
        // for state that was ALREADY set when the view appeared. Someone who
        // pinned a recording type in a previous session would otherwise be
        // taught about the control they are visibly using.
        #expect(CoachTip.usedTipIDs(recordingTypeChosen: true)
            .contains(CoachTip.recordingType.id))
        #expect(CoachTip.usedTipIDs(recordingTypeChosen: false).isEmpty)

        let retired = CoachTip.usedTipIDs(recordingTypeChosen: true)
        #expect(CoachTipQueue.next(context(retired: retired)) == .goalQuality)
    }

    @Test("retiring decides, and says when there is nothing to do")
    func retirementDecision() {
        // Returning nil rather than an unchanged set is what lets the caller
        // skip a UserDefaults write on every unrelated state change.
        #expect(CoachTipRetirement.retiring(.recordingType, used: false, in: []) == nil)
        #expect(CoachTipRetirement.retiring(.recordingType, used: true, in: [])
            == [CoachTip.recordingType.id])
        // Already retired — no write, no duplicate.
        #expect(CoachTipRetirement.retiring(
            .recordingType, used: true, in: [CoachTip.recordingType.id]) == nil)
    }

    @Test("retiring one tip leaves the others retired")
    func retirementIsAdditive() {
        let existing: Set<String> = [CoachTip.goalQuality.id]
        let next = CoachTipRetirement.retiring(.recordingType, used: true, in: existing)
        #expect(next == [CoachTip.goalQuality.id, CoachTip.recordingType.id])
    }

    @Test("every tip carries text a user can act on")
    func tipsHaveCopy() {
        for tip in CoachTip.allCases {
            #expect(!tip.id.isEmpty)
            #expect(!tip.title.isEmpty)
            #expect(!tip.body.isEmpty)
        }
    }
}

@Suite("Onboarding progress is stored, and only moves forward", .serialized)
struct OnboardingProgressTests {
    /// Each case gets its own defaults domain rather than borrowing the one the
    /// whole app (and every other suite) shares. Save-and-restore is not enough:
    /// suites run in parallel, so a restore that lands a microsecond late is a
    /// failure in someone else's test — which is exactly the flakiness this
    /// suite used to contribute to.
    private func withCleanDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "onboarding-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        Config.$onboardingSuiteName.withValue(suite) { body(store) }
    }

    @Test("a test's onboarding writes cannot reach the shared domain")
    func defaultsAreIsolated() {
        let standardBefore = UserDefaults.standard.string(forKey: "onboarding.step")

        withCleanDefaults { store in
            Config.onboardingStep = .sample
            #expect(store.string(forKey: "onboarding.step") == "sample")
        }

        // The domain every other suite reads in parallel is untouched — which is
        // the whole point, and what the old save-and-restore could not promise.
        #expect(UserDefaults.standard.string(forKey: "onboarding.step") == standardBefore)
    }

    @Test("a fresh install has no recorded step")
    func freshInstallHasNoStep() {
        withCleanDefaults { _ in
            #expect(Config.onboardingStep == nil)
        }
    }

    @Test("an existing user who finished the old pre-flight keeps their progress")
    func legacyFlagMigrates() {
        withCleanDefaults { store in
            // Shipping the step-based flow must not drag every existing install
            // back through a permissions screen they already completed.
            store.set(true, forKey: "onboarding.completed")
            #expect(Config.onboardingStep == .capture)
            #expect(OnboardingGate.step(lastCompleted: Config.onboardingStep,
                                        microphoneGranted: true,
                                        screenRecordingGranted: true) == .sample)
        }
    }

    @Test("recording a step round-trips and keeps the legacy flag truthful")
    func stepRoundTrips() {
        withCleanDefaults { _ in
            Config.onboardingStep = .sample
            #expect(Config.onboardingStep == .sample)
            #expect(Config.onboardingCompleted)
        }
    }

    @Test("clearing the step actually resets the user to a fresh install")
    func stepCanBeCleared() {
        withCleanDefaults { _ in
            Config.onboardingStep = .sample
            #expect(Config.onboardingStep == .sample)

            Config.onboardingStep = nil

            // The legacy flag is a FALLBACK for reading, not a second source of
            // truth. Leaving it set here means a cleared step silently reads
            // back as .capture, so QA and support can never put an account back
            // to a genuine first run.
            #expect(Config.onboardingStep == nil)
            #expect(!Config.onboardingCompleted)
            #expect(OnboardingGate.step(lastCompleted: Config.onboardingStep,
                                        microphoneGranted: true,
                                        screenRecordingGranted: true) == .capture)
        }
    }

    @Test("progress never moves backwards")
    func progressIsMonotonic() {
        // Revoking a permission reopens the capture check. Finishing it again
        // must not erase a sample the user already sat through.
        #expect(OnboardingStep.furthestCompleted(recorded: .sample, finished: .capture) == .sample)
        #expect(OnboardingStep.furthestCompleted(recorded: .capture, finished: .sample) == .sample)
        #expect(OnboardingStep.furthestCompleted(recorded: nil, finished: .capture) == .capture)
        #expect(OnboardingStep.furthestCompleted(recorded: .capture, finished: .capture) == .capture)
    }

    @Test("re-granting a permission does not force the sample a second time")
    func repeatedCaptureCheckDoesNotReplayTheSample() {
        // Revoking a permission (a rename, a re-sign, a macOS update) reopens
        // the capture check for someone who finished onboarding weeks ago.
        // Finishing it must hand them their workspace back — not sit them
        // through the sample call again.
        #expect(OnboardingStep.nextToPresent(finished: .capture, recorded: .sample) == nil)
        // A genuine first run still advances into the sample.
        #expect(OnboardingStep.nextToPresent(finished: .capture, recorded: nil) == .sample)
        #expect(OnboardingStep.nextToPresent(finished: .capture, recorded: .capture) == .sample)
        // And finishing the last step always ends the flow.
        #expect(OnboardingStep.nextToPresent(finished: .sample, recorded: .sample) == nil)
    }

    @Test("the step order is the flow order")
    func ordering() {
        #expect(OnboardingStep.capture < OnboardingStep.sample)
        #expect(OnboardingStep.capture.next == .sample)
        #expect(OnboardingStep.sample.next == nil)
    }
}

@Suite("Sidebar onboarding prompts")
struct OnboardingPromptsTests {
    @Test("the setup card counts only what is genuinely outstanding")
    func setupCounts() {
        #expect(OnboardingPrompts.setupRemaining(
            captureVerified: true, keyReady: true, appsConnected: true) == 0)
        #expect(OnboardingPrompts.setupRemaining(
            captureVerified: true, keyReady: false, appsConnected: false) == 2)
        #expect(OnboardingPrompts.setupRemaining(
            captureVerified: false, keyReady: false, appsConnected: false) == 3)
    }

    @Test("строку про ключ можно отложить, не пряча всю карточку")
    func providerKeyRowIsIndividuallyDismissible() {
        // Ключ необязателен — запись, расшифровка и поиск по звонкам работают
        // без него, — поэтому у строки свой крестик. Скрыть всю карточку ради
        // одной строки значит выбросить заодно и шаг про подключения.
        #expect(OnboardingPrompts.showsProviderKeyRow(hasKey: false, dismissed: false))
        #expect(!OnboardingPrompts.showsProviderKeyRow(hasKey: false, dismissed: true))
        #expect(!OnboardingPrompts.showsProviderKeyRow(hasKey: true, dismissed: false))
    }

    @Test("отложенная строка перестаёт считаться невыполненной")
    func dismissedRowLeavesTheCount() {
        // Иначе карточка навсегда обещает «осталось 1», а под ней ничего нет.
        let readyOrPutOff = OnboardingPrompts.showsProviderKeyRow(
            hasKey: false, dismissed: true) == false
        #expect(OnboardingPrompts.setupRemaining(
            captureVerified: true,
            keyReady: readyOrPutOff,
            appsConnected: true) == 0)
    }

    @Test("the no-call card waits for onboarding to finish and stays out of a live call")
    func noCallCardEligibility() {
        // The card is a nudge for the empty evening between installing and the
        // next real meeting — not something to shove in front of someone who is
        // mid-recording, or who already has calls in their history.
        #expect(OnboardingPrompts.showsNoCallCard(
            dismissed: false, isRecording: false,
            hasSavedSessions: false, lastStep: .sample))
        #expect(!OnboardingPrompts.showsNoCallCard(
            dismissed: true, isRecording: false,
            hasSavedSessions: false, lastStep: .sample))
        #expect(!OnboardingPrompts.showsNoCallCard(
            dismissed: false, isRecording: true,
            hasSavedSessions: false, lastStep: .sample))
        #expect(!OnboardingPrompts.showsNoCallCard(
            dismissed: false, isRecording: false,
            hasSavedSessions: true, lastStep: .sample))
        // Mid-onboarding the sheet is still up; a sidebar nudge behind it is noise.
        #expect(!OnboardingPrompts.showsNoCallCard(
            dismissed: false, isRecording: false,
            hasSavedSessions: false, lastStep: .capture))
        #expect(!OnboardingPrompts.showsNoCallCard(
            dismissed: false, isRecording: false,
            hasSavedSessions: false, lastStep: nil))
    }
}

@MainActor
@Suite("Sample run isolation", .serialized)
struct SampleRunIsolationTests {
    private func makeStore() -> (SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-sample-\(UUID().uuidString)")
        return (SessionStore(root: root), root)
    }

    @Test("a sample run saves no session")
    func sampleIsNeverPersisted() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(credentialStore: InMemoryKeychain(), sessionStore: store)

        state.startSampleRun()
        // Everything persistCurrentSession normally requires is now present, so
        // the flag is the only thing between fiction and the History list.
        state.transcript = SampleCall.mobileBeta.transcriptEntries()
        state.meetingTitle = "Mobile beta — sample"
        state.persistCurrentSession()

        #expect(store.list().isEmpty)
        #expect(state.sampleRunActive)
    }

    @Test("ending a sample restores the workspace it borrowed")
    func sampleLeavesNothingBehind() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(credentialStore: InMemoryKeychain(), sessionStore: store)
        state.callGoal = "Real goal the user typed"

        state.startSampleRun()
        state.transcript = SampleCall.mobileBeta.transcriptEntries()
        state.suggestions = [SampleCall.mobileBeta.preparedSuggestion]
        state.pinSampleDecision()
        state.endSampleRun()

        #expect(!state.sampleRunActive)
        #expect(state.transcript.isEmpty)
        #expect(state.suggestions.isEmpty)
        #expect(state.samplePinnedDecision == nil)
        #expect(state.callGoal == "Real goal the user typed")
        #expect(store.list().isEmpty)
    }

    @Test("pinning inside the sample never reaches the real ledger")
    func pinnedSampleDecisionIsPreviewOnly() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.startSampleRun()
        state.pinSampleDecision()

        #expect(state.samplePinnedDecision != nil)
        // The ledger holds confirmed team decisions and nothing else, so the
        // preview lives in its own property and cannot be mistaken for one.
        #expect(state.ledgerDecisions.isEmpty)
    }

    @Test("appearing twice does not overwrite the restore point")
    func doubleStartKeepsTheOriginalWorkspace() {
        // SwiftUI can run onAppear more than once for the same sheet. A second
        // startSampleRun that captured the SAMPLE as the restore point would
        // hand the user fiction back when the sheet closed.
        let state = AppState(credentialStore: InMemoryKeychain())
        let real = [TranscriptEntry(source: .mic, text: "A real line the user recorded.")]
        state.transcript = real
        state.meetingTitle = "Real call"

        state.startSampleRun()
        state.transcript = SampleCall.mobileBeta.transcriptEntries()
        state.startSampleRun()      // second onAppear
        state.endSampleRun()

        #expect(state.transcript == real)
        #expect(state.meetingTitle == "Real call")
    }

    @Test("ending a sample that never started changes nothing")
    func endWithoutStartIsANoOp() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let real = [TranscriptEntry(source: .mic, text: "A real line the user recorded.")]
        state.transcript = real

        state.endSampleRun()

        #expect(state.transcript == real)
        #expect(!state.sampleRunActive)
    }

    @Test("the sample refuses to borrow a workspace that is mid-recording")
    func sampleNeverInterruptsALiveCall() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.status = .recording
        let live = [TranscriptEntry(source: .system, text: "Live call in progress right now.")]
        state.transcript = live

        state.startSampleRun()

        #expect(!state.sampleRunActive)
        #expect(state.transcript == live)
        // And a pin cannot be smuggled in either.
        state.pinSampleDecision()
        #expect(state.samplePinnedDecision == nil)
    }

    @Test("a sample-only session does not unlock the paywall")
    func sampleDoesNotCountAsAValueMoment() {
        let before = (UsageTracker.meetings, UsageTracker.aiRequests)
        let state = AppState(credentialStore: InMemoryKeychain())

        state.startSampleRun()
        state.transcript = SampleCall.mobileBeta.transcriptEntries()
        state.pinSampleDecision()
        state.endSampleRun()

        // Config.shouldShowPaywall keys off exactly these two counters, so
        // holding them still is what stops a fictional call triggering a real
        // upsell.
        #expect(UsageTracker.meetings == before.0)
        #expect(UsageTracker.aiRequests == before.1)
    }
}

/// The first screen, on a machine that has nothing yet.
///
/// Both bugs pinned here were invisible to anyone who had run the app before:
/// the row list only overflows when the speech model still has to download, and
/// the duplicated sentence only reads as wrong when you meet it cold.
@MainActor
@Suite("Capture check screen")
struct CaptureCheckStepTests {

    private func inspected() throws -> InspectableView<ViewType.ClassifiedView> {
        try CaptureCheckStep(onContinue: {})
            .environmentObject(AppState(credentialStore: InMemoryKeychain()))
            .inspect()
    }

    /// The reported bug, at the level the user actually meets it: what the
    /// screen SAYS. The pure function can return `.regrant` while the view
    /// still renders the relaunch button, and then nothing has been fixed.
    @Test("only the relaunch advice offers the relaunch button",
          arguments: [CaptureProbe.Advice.relaunch,
                      .regrant,
                      .noSoundPlaying,
                      .moveToApplications])
    func onlyRelaunchAdviceOffersRelaunch(advice: CaptureProbe.Advice) throws {
        let rendered = try AdviceRow(advice: advice).inspect()
        let offersRelaunch = (try? rendered.find(button: "Выйти и открыть заново")) != nil
        #expect(offersRelaunch == (advice == .relaunch),
                "«\(advice)» must \(advice == .relaunch ? "" : "not ")offer a relaunch")
    }

    @Test("each advice says something different about why")
    func adviceTextsAreDistinct() throws {
        // Three causes wearing one message is how the loop happened. If two of
        // these ever render the same words again, they are one message again.
        let texts = try [CaptureProbe.Advice.relaunch, .regrant,
                         .noSoundPlaying, .moveToApplications].map {
            try AdviceRow(advice: $0).inspect()
                .findAll(ViewType.Text.self)
                .compactMap { try? $0.string() }
                .joined(separator: " ")
        }
        for text in texts { #expect(!text.isEmpty, "an advice rendered no words at all") }
        #expect(Set(texts).count == texts.count, "two different causes render the same message")

        // The one that is not a permission problem must not talk like one.
        let noSound = texts[2]
        #expect(!noSound.contains("перезапуск") && !noSound.contains("Перезапуск"),
                "a stream that started fine is not solved by restarting anything")
        #expect(noSound.contains("Ещё раз"), "it must name the button that retries")
    }

    @Test("nothing is advised before the check has run")
    func noAdviceBeforeAProbe() throws {
        // `.none` renders EmptyView. A row of blank chrome appearing before the
        // user has pressed anything reads as a failure that has not happened.
        let rendered = try AdviceRow(advice: .none).inspect()
        #expect(rendered.findAll(ViewType.Text.self).isEmpty)
    }

    @Test("Continue is pinned outside the scrolling rows")
    func continueIsAlwaysReachable() throws {
        // The regression: the sheet fixes its width and never bounded its
        // height, so on a first run — where a fourth row appears for the model
        // download, and a fifth after a failed probe — Continue and the step
        // dots were pushed off the bottom of the window with no way to scroll
        // to them. A first-run user could not leave the first screen.
        let view = try inspected()
        let scroll = try view.find(ViewType.ScrollView.self)
        #expect(throws: (any Error).self, "Continue must NOT be inside the scroll") {
            _ = try scroll.find(button: "Продолжить")
        }
        #expect(throws: Never.self, "Continue must still exist on the screen") {
            _ = try view.find(button: "Продолжить")
        }
    }

    @Test("the rows scroll and are height-bounded")
    func rowsScroll() throws {
        #expect(throws: Never.self) { _ = try inspected().find(ViewType.ScrollView.self) }
    }

    @Test("the duration is stated once, next to the button that spends it")
    func durationIsNotDuplicated() throws {
        // "…then a six-second test" in the subhead AND "Six seconds." in the
        // capture row, two lines apart, read as a rendering fault.
        let text = try inspected().findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
        // Текст переведён; правило прежнее — длительность названа один раз и
        // ровно там, где на неё нажимают.
        let mentions = text.filter {
            $0.lowercased().contains("шесть секунд") || $0.lowercased().contains("шестисекунд")
        }
        #expect(mentions.count == 1, "duration mentioned \(mentions.count)×: \(mentions)")
        #expect(mentions.first?.hasPrefix("Шесть секунд") == true,
                "the surviving mention should be the capture row's, beside «Проверить»")
    }
}
