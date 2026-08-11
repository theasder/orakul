import AppKit
import SwiftUI

/// Act 1. Two permissions, then six seconds that prove the app can actually
/// hear the room.
///
/// The check exists because a granted permission and a working capture are
/// different things. When they disagree — Screen Recording granted, system audio
/// silent — the cause is always the same macOS quirk and the fix is a relaunch,
/// so this screen offers the relaunch instead of describing it.
struct CaptureCheckStep: View {
    @EnvironmentObject var state: AppState
    @StateObject private var probe = CaptureProbeRunner()
    @State private var probeTask: Task<Void, Never>?
    /// Whether macOS has already been asked. It only ever prompts once, so the
    /// second press has to go to System Settings instead.
    @AppStorage("onboarding.askedMicrophone") private var askedMicrophone = false
    @AppStorage("onboarding.askedScreenRecording") private var askedScreenRecording = false
    let onContinue: () -> Void

    private var usesLocalModel: Bool { Config.transcriptionEngineValue == .local }

    private var relaunchNeeded: Bool {
        guard let verdict = probe.verdict else { return false }
        return CaptureProbe.needsRelaunch(
            verdict: verdict, screenRecordingGranted: state.screenRecordingGranted)
    }

    /// Ceiling on the scrolling area. Chosen so the pinned header, the footer
    /// and the step dots always fit on the shortest Mac display this app
    /// supports — the point is that Continue is never the thing that scrolls
    /// away.
    private static let maxRowsHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            // Scrolls, because this list is not a fixed height. On a machine
            // that already has the speech model there are three rows; on a FIRST
            // RUN there are four (the model still has to download) and five when
            // macOS also needs the relaunch. The sheet pins its width and never
            // bounded its height, so those extra rows pushed Continue and the
            // step dots off the bottom — invisible to anyone whose model was
            // already downloaded, which is every developer.
            ScrollView {
                rows
            }
            .frame(maxHeight: Self.maxRowsHeight)

            footer
        }
        .task {
            await state.refreshPermissionStatus()
            state.prewarmLocalModelIfNeeded()   // start the model download early
        }
        // Granting happens in System Settings, in another app. Without re-reading
        // on the way back, the row still says Enable for a permission the user
        // just switched on — and the obvious conclusion is that it did not work.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await state.refreshPermissionStatus() }
        }
        // Continue is deliberately enabled during the test, so leaving mid-probe
        // is normal. Cancelling shortens the remaining sleep, which brings the
        // teardown forward — without this, two capture sources stay live (and
        // the macOS recording indicator stays on) after the screen is gone.
        .onDisappear { probeTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("Let's make sure Cruxwing can hear the room.",
                  systemImage: "waveform")
                .font(Typo.title).foregroundStyle(Theme.ink)
            // Deliberately does NOT restate the duration. The capture-check row
            // says "Six seconds" right next to the button that spends them, and
            // saying it twice two lines apart reads as a mistake, not emphasis.
            Text("Two permissions, then a quick check. No bot joins your calls — Cruxwing listens on this Mac.")
                .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(spacing: Space.s) {
            PermissionRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Your side of the conversation.",
                granted: state.micGranted,
                kind: .microphone,
                alreadyAsked: askedMicrophone,
                action: {
                    askedMicrophone = true
                    Task { await state.requestMicrophonePermission() }
                })

            PermissionRow(
                icon: "rectangle.on.rectangle",
                title: "Screen Recording",
                detail: "Everyone else's audio, via ScreenCaptureKit. Nothing is screenshotted.",
                granted: state.screenRecordingGranted,
                kind: .screenRecording,
                alreadyAsked: askedScreenRecording,
                action: {
                    askedScreenRecording = true
                    Task { await state.requestScreenRecordingPermission() }
                })

            CaptureCheckRow(probe: probe) {
                probeTask?.cancel()
                probeTask = Task { await probe.run() }
            }

            if usesLocalModel {
                ModelWarmupRow(stateValue: state.transcriptionState) {
                    state.prepareLocalModel()
                }
            }

            // Inside the scroll with the other rows: it appears only after a
            // failed probe, and when it does it is the FIFTH row — exactly the
            // case that used to overflow.
            if relaunchNeeded {
                RelaunchRow()
            }
        }
    }

    /// Pinned below the scroll. Continue must always be reachable — a first-run
    /// user who cannot find it is stuck on the first screen of the product.
    private var footer: some View {
        HStack(spacing: Space.m) {
            Text("Signed out — on-device transcription is unlimited either way.")
                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button("Continue", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Continue")
        }
    }
}

/// A single permission line: live status plus a request/enable affordance.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let kind: PermissionPrompt.Kind
    let alreadyAsked: Bool
    let action: () -> Void

    var body: some View {
        OnboardingRow(icon: icon, title: title, detail: detail) {
            switch PermissionPrompt.action(granted: granted, alreadyAsked: alreadyAsked) {
            case nil:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption.weight(.medium))
                    .foregroundStyle(Theme.speakerYou)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(title) granted")
            case .request:
                Button("Enable", action: action)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Enable \(title)")
            case .openSettings:
                // macOS will not prompt a second time, so pressing Enable again
                // would do nothing at all. Send them where the toggle lives.
                Button("Open System Settings") {
                    if let url = PermissionPrompt.settingsURL(for: kind) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Open System Settings for \(title)")
            }
        }
    }
}

/// The test itself: two live meters and a verdict in words, never colour alone.
private struct CaptureCheckRow: View {
    @ObservedObject var probe: CaptureProbeRunner
    /// Owned by the step, so the running probe can be cancelled when the screen
    /// goes away rather than left holding two live captures.
    let start: () -> Void

    private var status: (text: String, tint: Color) {
        switch probe.verdict {
        case .pass:       return ("Both sources heard", Theme.speakerYou)
        case .micOnly:    return ("No system audio", Theme.amber)
        case .systemOnly: return ("No microphone", Theme.amber)
        case .silent:     return ("Nothing heard", Theme.amber)
        case nil:         return (probe.isRunning ? "Listening…" : "Not run yet",
                                  Theme.inkTertiary)
        }
    }

    var body: some View {
        OnboardingRow(
            icon: "waveform.badge.magnifyingglass",
            title: "Capture check",
            detail: probe.isRunning
                ? "Say something, and play any audio — a video, a song."
                : "Six seconds. Proves both sources are audible before your first call.",
            trailing: {
                if probe.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(probe.verdict == nil ? "Run test" : "Run again", action: start)
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("Run capture check")
                }
            },
            footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ProbeMeter(label: "You", level: probe.micLevel,
                               peak: probe.micPeak, tint: Theme.speakerYou)
                    ProbeMeter(label: "System audio", level: probe.systemLevel,
                               peak: probe.systemPeak, tint: Theme.speakerThem)
                    Text(status.text)
                        .font(Typo.caption.weight(.medium))
                        .foregroundStyle(status.tint)
                        .accessibilityLabel("Capture check: \(status.text)")
                    if let failure = probe.startFailure {
                        Text(failure)
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            })
    }
}

/// Level bar with a peak tick. The peak is what the verdict is made of, so it
/// stays visible after the sound stops.
private struct ProbeMeter: View {
    let label: String
    let level: CGFloat
    let peak: CGFloat
    let tint: Color

    var body: some View {
        HStack(spacing: Space.s) {
            Text(label)
                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                .frame(width: 76, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: max(2, geo.size.width * min(1, level)))
                    if peak >= CaptureProbe.signalThreshold {
                        Capsule().fill(tint)
                            .frame(width: 2)
                            .offset(x: min(geo.size.width - 2,
                                           geo.size.width * min(1, peak)))
                    }
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peak >= CaptureProbe.signalThreshold
                            ? "\(label): heard" : "\(label): no signal")
    }
}

/// Offered only when the probe proves the quirk: granted, and silent anyway.
private struct RelaunchRow: View {
    var body: some View {
        OnboardingRow(
            icon: "arrow.clockwise.circle",
            iconTint: Theme.amber,
            title: "macOS hasn't applied Screen Recording yet",
            detail: "A macOS quirk, not a Cruxwing bug — the permission takes effect on the next launch. Nothing is lost."
        ) {
            Button("Quit & reopen") { relaunch() }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .accessibilityLabel("Quit and reopen Cruxwing")
        }
    }

    /// Hands the relaunch to `open`, then exits — the same thing the user would
    /// do by hand, minus the chance of not coming back.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}

/// On-device model warm-up (local engine only). No fake percentage — WhisperKit's
/// download is opaque, so this stays honest: preparing / ready / failed.
private struct ModelWarmupRow: View {
    let stateValue: AppState.TranscriptionState
    let retry: () -> Void

    var body: some View {
        OnboardingRow(
            icon: "cpu",
            title: "On-device model",
            // Size of the model THIS Mac will fetch, not a fixed number: the old
            // "~150 MB" was only true for `base`, while a 16 GB Apple Silicon
            // machine pulls ~480 MB and a Max/Ultra ~1.5 GB. Promising 150 MB and
            // downloading ten times that is how someone abandons onboarding on a
            // tethered connection.
            detail: "A private speech model (\(LocalWhisperModel.approxDownloadForThisMac(selected: Config.localWhisperModel))) downloads once, then runs offline."
        ) {
            switch stateValue {
            case .preparing:
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption.weight(.medium))
                    .foregroundStyle(Theme.speakerYou)
                    .labelStyle(.titleAndIcon)
            case .failed:
                Button("Retry", action: retry).buttonStyle(QuietButtonStyle())
            case .idle:
                Button("Download", action: retry).buttonStyle(QuietButtonStyle())
            }
        }
    }
}

/// Shared row chrome, so every line on this screen sits on the same grid.
struct OnboardingRow<Trailing: View, Footer: View>: View {
    let icon: String
    var iconTint: Color = Theme.accent
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundStyle(iconTint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.callout.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text(detail).font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s)
                trailing()
            }
            footer()
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension OnboardingRow where Footer == EmptyView {
    init(icon: String,
         iconTint: Color = Theme.accent,
         title: String,
         detail: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(icon: icon, iconTint: iconTint, title: title,
                  detail: detail, trailing: trailing, footer: { EmptyView() })
    }
}
