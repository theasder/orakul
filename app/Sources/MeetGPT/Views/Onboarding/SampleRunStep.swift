import SwiftUI

/// Act 2. A written call replays at speed, a blind spot arrives carrying its
/// quote, and one decision gets confirmed — the whole product loop, before the
/// user's first real meeting.
///
/// Everything here is fiction and says so: the banner is in every frame and
/// cannot be dismissed while the sample runs, and each card carries
/// `SampleCall.preparedLabel`. The isolation itself is enforced in `AppState`,
/// not here — this view could not write a session, a ledger row, or a usage
/// count even if it tried.
struct SampleRunStep: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    private let sample = SampleCall.mobileBeta
    /// The replay clock lives here rather than in the view's own `@State`, so
    /// its timing can be tested without waiting eleven real seconds.
    @StateObject private var playback: SamplePlayback
    @State private var ticker: Task<Void, Never>?

    init(playback: SamplePlayback = SamplePlayback(),
         onFinish: @escaping () -> Void) {
        _playback = StateObject(wrappedValue: playback)
        self.onFinish = onFinish
    }

    private var visibleLines: [SampleCall.Line] { playback.visibleLines }
    private var suggestionVisible: Bool { playback.isSuggestionVisible }
    private var decisionVisible: Bool { playback.isDecisionVisible }
    private var finished: Bool { playback.isFinished }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            banner

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Goal for this call").font(Typo.label)
                    .foregroundStyle(Theme.inkTertiary)
                Text(sample.goal).font(Typo.callout).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: Space.m) {
                transcript
                copilot
            }

            footer
        }
        .onAppear(perform: begin)
        // Esc dismisses the sheet without touching the buttons. Without this,
        // sampleRunActive would stay true for the rest of the session and
        // silently block every real session from being saved. endSampleRun is
        // guarded, so running it twice is a no-op.
        .onDisappear {
            stopTicker()
            state.endSampleRun()
        }
    }

    // MARK: Pieces

    private var banner: some View {
        HStack(spacing: Space.s) {
            Text("SAMPLE")
                .font(Typo.label).foregroundStyle(Theme.speakerThem)
                .padding(.horizontal, Space.s).padding(.vertical, 2)
                .background(Theme.accentTint, in: Capsule())
            Text("Fictional call — none of this is your data, and none of it is saved.")
                .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Text(clock).font(Typo.caption.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentTint,
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample call. Fictional, and not saved.")
    }

    private var clock: String {
        "\(format(playback.callSeconds)) / \(format(playback.totalCallSeconds))"
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Транскрипт").font(Typo.label).foregroundStyle(Theme.inkTertiary)
            // The rows scroll inside their own box: eleven lines of replay
            // must never decide the height of the whole onboarding window,
            // and a bounded box can never push its border through a row.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(visibleLines, id: \.atSeconds) { line in
                            HStack(alignment: .top, spacing: Space.s) {
                                Text(line.speaker)
                                    .font(Typo.caption.weight(.medium))
                                    .foregroundStyle(line.source == .mic
                                                     ? Theme.speakerYou : Theme.speakerThem)
                                    .frame(width: 46, alignment: .leading)
                                Text(line.text).font(Typo.callout)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.atSeconds)
                        }
                        if visibleLines.isEmpty {
                            Text("Starting…").font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Space.m)
                }
                .onChange(of: visibleLines.count) {
                    // Keep the newest replay line in view, the way live
                    // captions would; without this the scroll pins to the top
                    // and the "arriving" lines land unseen below the fold.
                    if let last = visibleLines.last {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.atSeconds, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 380, alignment: .topLeading)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copilot: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Ко-пилот").font(Typo.label).foregroundStyle(Theme.inkTertiary)

            if suggestionVisible {
                SampleCard(tint: Theme.speakerThem) {
                    Text(sample.preparedSuggestion.title)
                        .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sample.preparedSuggestion.detail)
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let evidence = sample.preparedSuggestion.evidence {
                        Text("“\(evidence)”")
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            .padding(.leading, Space.s)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.speakerThem.opacity(0.5))
                                    .frame(width: 2)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(SampleCall.preparedLabel)
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if decisionVisible {
                SampleCard(tint: Theme.accent) {
                    Text("Кандидат в решения")
                        .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(sample.preparedDecision.text)
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.samplePinnedDecision == nil {
                        Button("📌 Log decision") { state.pinSampleDecision() }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityLabel("Log the sample decision")
                    } else {
                        Label("Logged — sample only. Nothing was written to your ledger.",
                              systemImage: "checkmark.circle.fill")
                            .font(Typo.caption).foregroundStyle(Theme.speakerYou)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !suggestionVisible {
                Text("Blind spots arrive while the call is live — you don't have to ask for them.")
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 256, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            if finished {
                Text("That's the loop. Your turn.")
                    .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
            }
            Spacer(minLength: Space.s)
            if finished {
                Button("Настроить первый звонок", action: finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Настроить первый звонок")
            } else {
                Button("Пропустить", action: finish)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Skip the sample")
            }
        }
    }

    // MARK: Playback

    private func begin() {
        state.startSampleRun()
        // Reduced motion gets the finished transcript instead of an animation it
        // did not ask for. The content is the point; the streaming is not.
        guard !reduceMotion else {
            playback.completeImmediately()
            return
        }
        guard ticker == nil else { return }
        ticker = Task { @MainActor in await playback.play() }
    }

    private func stopTicker() {
        playback.stop()
        ticker?.cancel()
        ticker = nil
    }

    private func finish() {
        stopTicker()
        state.endSampleRun()
        onFinish()
    }
}

/// Card chrome for the sample's co-pilot output.
private struct SampleCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            content()
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}
