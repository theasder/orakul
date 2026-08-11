import AVFoundation
import CoreGraphics
import Foundation

/// Proves both capture sources are actually audible, rather than merely
/// permitted.
///
/// A granted permission and a working capture are different things, and the gap
/// between them is where first-run support goes to die: macOS reports Screen
/// Recording as granted, ScreenCaptureKit returns silence until the app is
/// relaunched, and the user concludes the product does not work. Six seconds of
/// metering turns that into a button.
enum CaptureProbe {
    /// How long the check listens. Long enough to say a sentence and start a
    /// video; short enough that nobody abandons it.
    static let durationSeconds: Double = 6

    /// Peak level, on `AudioLevel`'s normalized 0...1 scale, that counts as
    /// signal. Well above the noise floor of a quiet room, well below speech.
    static let signalThreshold: CGFloat = 0.06

    enum Verdict: Equatable {
        case pass
        /// Only the microphone was heard — the fingerprint of the relaunch quirk
        /// when Screen Recording is granted.
        case micOnly
        /// Only system audio was heard: nothing was said, or the mic is muted.
        case systemOnly
        case silent
    }

    static func verdict(micPeak: CGFloat, systemPeak: CGFloat) -> Verdict {
        let mic = micPeak >= signalThreshold
        let system = systemPeak >= signalThreshold
        switch (mic, system) {
        case (true, true):   return .pass
        case (true, false):  return .micOnly
        case (false, true):  return .systemOnly
        case (false, false): return .silent
        }
    }

    /// Relaunching fixes exactly one thing: a granted Screen Recording
    /// permission macOS has not applied to this process yet. Offering it for a
    /// muted microphone or an ungranted permission sends the user round a loop
    /// that cannot succeed.
    static func needsRelaunch(verdict: Verdict, screenRecordingGranted: Bool) -> Bool {
        verdict == .micOnly && screenRecordingGranted
    }
}

/// One audible source, as the probe needs it: start reporting levels, then stop.
///
/// The seam exists so the probe's own logic — peak tracking, verdicts, teardown,
/// and what happens when a source refuses to start — can be tested without a
/// microphone, a screen-recording permission, or six real seconds.
protocol CaptureProbeSource: AnyObject {
    func start(onLevel: @escaping (CGFloat) -> Void) async throws
    func stop() async
}

/// The live microphone, wrapped to fit the seam.
final class MicrophoneProbeSource: CaptureProbeSource {
    private let mic = MicrophoneCapture()

    func start(onLevel: @escaping (CGFloat) -> Void) async throws {
        try mic.start { buffer in onLevel(AudioLevel.rms(buffer)) }
    }

    func stop() async { mic.stop() }
}

/// System audio via ScreenCaptureKit, wrapped to fit the seam.
final class SystemAudioProbeSource: CaptureProbeSource {
    private let system = SystemAudioCapture()

    func start(onLevel: @escaping (CGFloat) -> Void) async throws {
        try await system.start { buffer in onLevel(AudioLevel.rms(buffer)) }
    }

    func stop() async { await system.stop() }
}

/// Runs the probe against the real capture path — the same engines a live
/// recording uses — while writing nothing: no chunker, no transcription, no
/// session, no file. It only remembers the loudest thing it heard.
@MainActor
final class CaptureProbeRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var micLevel: CGFloat = 0
    @Published private(set) var systemLevel: CGFloat = 0
    @Published private(set) var micPeak: CGFloat = 0
    @Published private(set) var systemPeak: CGFloat = 0
    @Published private(set) var verdict: CaptureProbe.Verdict?
    @Published private(set) var startFailure: String?

    private let mic: any CaptureProbeSource
    private let system: any CaptureProbeSource
    private let duration: Double

    init(mic: any CaptureProbeSource = MicrophoneProbeSource(),
         system: any CaptureProbeSource = SystemAudioProbeSource(),
         duration: Double = CaptureProbe.durationSeconds) {
        self.mic = mic
        self.system = system
        self.duration = duration
    }

    /// Listens for `duration` seconds, then reports. A source that refuses to
    /// start is not fatal: the other still produces a verdict, which is exactly
    /// how "granted but silent" gets diagnosed.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        verdict = nil
        startFailure = nil
        micPeak = 0
        systemPeak = 0

        var failures: [String] = []
        do {
            try await system.start { [weak self] level in
                Task { @MainActor in self?.noteSystem(level) }
            }
        } catch {
            failures.append("system audio: \(error.localizedDescription)")
        }
        do {
            try await mic.start { [weak self] level in
                Task { @MainActor in self?.noteMic(level) }
            }
        } catch {
            failures.append("microphone: \(error.localizedDescription)")
        }

        if duration > 0 {
            try? await Task.sleep(for: .seconds(duration))
        }

        // Both are stopped even if one never started: a half-started capture is
        // still worth tearing down, and leaving one live would keep the system
        // recording indicator on after a check the user thinks has finished.
        await mic.stop()
        await system.stop()

        micLevel = 0
        systemLevel = 0
        startFailure = failures.isEmpty ? nil : failures.joined(separator: " · ")
        verdict = CaptureProbe.verdict(micPeak: micPeak, systemPeak: systemPeak)
        isRunning = false
    }

    private func noteMic(_ level: CGFloat) {
        micLevel = level
        micPeak = max(micPeak, level)
    }

    private func noteSystem(_ level: CGFloat) {
        systemLevel = level
        systemPeak = max(systemPeak, level)
    }
}
