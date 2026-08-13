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

    /// What to actually tell the user when the check does not pass.
    enum Advice: Equatable {
        /// Nothing to add — the rows above already say it.
        case none
        /// Granted, and ScreenCaptureKit still refused to start. Relaunching
        /// fixes exactly this.
        case relaunch
        /// The relaunch was already tried and changed nothing, so the quirk is
        /// ruled out and the permission belongs to some other copy of the app.
        case regrant
        /// The stream is healthy and heard nothing: no sound was playing.
        case noSoundPlaying
        /// The app is running from somewhere macOS refuses to remember a
        /// permission for. No number of relaunches can fix this one.
        case moveToApplications
    }

    /// Where this copy of the app is running from.
    ///
    /// macOS ties a permission to the app's location on disk, and two locations
    /// make that tie impossible to keep:
    ///
    /// - **Translocation.** An app launched straight from a downloaded DMG (or
    ///   from Downloads, still carrying the quarantine flag) is run from a
    ///   randomized read-only copy under `AppTranslocation`. The path is
    ///   different on every launch, so the grant recorded against the last one
    ///   never applies to the next.
    /// - **Still inside the disk image.** `/Volumes/…` is not where an app
    ///   lives; the volume goes away and the grant with it.
    ///
    /// Both present exactly as this bug was reported — grant it, quit, reopen,
    /// and be asked to grant it again — which is why the check exists.
    enum InstallLocation: Equatable {
        case normal
        case translocated
        case diskImage
    }

    static func installLocation(bundlePath: String) -> InstallLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        return .normal
    }

    /// Which of them to show.
    ///
    /// **Why this is not `verdict == .micOnly`.** It was, and it produced a loop
    /// with no exit: «even though i quited and reopened orakul told me i am
    /// supposed to quit and reopen». `micOnly` means the microphone was heard
    /// and system audio was not — which is the relaunch quirk, and is equally
    /// the far more common case of no video or music playing during the six
    /// seconds. Blaming the quirk for both meant a user who stayed silent on the
    /// system side got sent to relaunch, came back, stayed silent again, and was
    /// sent to relaunch again. Nothing about relaunching could ever clear it.
    ///
    /// The discriminator is not the verdict but whether the stream STARTED.
    /// `SCShareableContent.excludingDesktopWindows` throws when macOS has not
    /// applied the permission to this process; a stream that starts and delivers
    /// silence is a stream with nothing to deliver. So the verdict does not
    /// enter into the relaunch branch at all — a failed start is direct evidence
    /// and holds whether or not the user also said anything.
    ///
    /// `relaunchAlreadyTried` closes the loop: a relaunch that did not help is
    /// proof the quirk is not the cause, and repeating the advice is the bug.
    static func advice(verdict: Verdict,
                       systemAudioStarted: Bool,
                       screenRecordingGranted: Bool,
                       relaunchAlreadyTried: Bool,
                       installLocation: InstallLocation = .normal) -> Advice {
        // System audio was heard: whatever else is wrong, it is not this.
        if verdict == .pass || verdict == .systemOnly { return .none }
        // Not granted — the permission row above already offers the toggle, and
        // sending someone to relaunch before granting is a round trip that
        // cannot succeed.
        guard screenRecordingGranted else { return .none }

        if !systemAudioStarted {
            // Checked before the relaunch, because from these two locations the
            // relaunch is guaranteed not to work and the advice would be the
            // loop all over again.
            guard installLocation == .normal else { return .moveToApplications }
            return relaunchAlreadyTried ? .regrant : .relaunch
        }
        return .noSoundPlaying
    }
}

/// Whether this launch is the one that followed our own relaunch advice.
///
/// Survives the quit, because that is the whole point: the question is about the
/// PREVIOUS run. Written when the advice is shown, read on the next launch.
///
/// Time here is uptime, not a wall clock: it cannot be moved by the user or a
/// time-zone change, and it needs no permission to read. The advice is stamped
/// with the uptime at which it was given; a process whose own launch is later
/// than that stamp is by definition a process that started afterwards.
///
/// One known hole, left deliberately: a reboot resets uptime, so an advice
/// stamped at 106 s looks "later" than the next boot's launch at 60 s and the
/// relaunch goes undetected. It costs one extra piece of advice after a reboot —
/// and a reboot applies the permission anyway, so the probe passes and the
/// advice is never reached. The loop still terminates on the run after that.
struct RelaunchMemory {
    static let key = "onboarding.relaunchAdvisedAtUptime"

    /// Uptime at the moment this process first reads the value — close enough to
    /// launch, and never later than the advice it is compared against.
    static let launchUptime = ProcessInfo.processInfo.systemUptime

    let defaults: UserDefaults
    let launchUptime: Double

    init(defaults: UserDefaults = .standard,
         launchUptime: Double = RelaunchMemory.launchUptime) {
        self.defaults = defaults
        self.launchUptime = launchUptime
    }

    /// True once the app has been restarted since we asked for it.
    var relaunchAlreadyTried: Bool {
        guard let advised = defaults.object(forKey: Self.key) as? Double else { return false }
        return launchUptime > advised
    }

    /// Called when the relaunch row is actually shown — not when it is merely
    /// possible, or the memory would record advice the user never saw.
    func noteAdvised(atUptime uptime: Double = ProcessInfo.processInfo.systemUptime) {
        defaults.set(uptime, forKey: Self.key)
    }

    /// The capture works now, so nothing is pending. Without this, a user who
    /// fixed the problem months ago still carries the flag and would be told
    /// «relaunching did not help» the first time anything else goes silent.
    func clear() {
        defaults.removeObject(forKey: Self.key)
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
    /// Whether ScreenCaptureKit accepted the capture at all. This — not a silent
    /// meter — is what separates «macOS has not applied the permission» from
    /// «nothing was playing», and getting those two confused is what sent users
    /// round the relaunch loop.
    @Published private(set) var systemAudioStarted = true

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
        systemAudioStarted = true
        do {
            try await system.start { [weak self] level in
                Task { @MainActor in self?.noteSystem(level) }
            }
        } catch {
            systemAudioStarted = false
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
