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

    /// Read once per launch, before any probe runs: the question is about the
    /// previous run, so it must not be re-read after the advice is written.
    private let memory = RelaunchMemory()
    @State private var relaunchAlreadyTried = RelaunchMemory().relaunchAlreadyTried

    private var advice: CaptureProbe.Advice {
        guard let verdict = probe.verdict else { return .none }
        return CaptureProbe.advice(
            verdict: verdict,
            systemAudioStarted: probe.systemAudioStarted,
            screenRecordingGranted: state.screenRecordingGranted,
            relaunchAlreadyTried: relaunchAlreadyTried,
            installLocation: CaptureProbe.installLocation(
                bundlePath: Bundle.main.bundleURL.path))
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
        // What lets the NEXT launch know a relaunch was already tried. Written
        // when the advice is actually shown, so the memory never records advice
        // nobody saw; cleared as soon as system audio is heard, because a stale
        // flag would meet a user whose problem was fixed months ago with
        // «relaunching did not help» the first time anything else went quiet.
        .onChange(of: probe.verdict) { _ in
            if advice == .relaunch { memory.noteAdvised() }
            if probe.verdict == .pass || probe.verdict == .systemOnly { memory.clear() }
        }
        // Continue is deliberately enabled during the test, so leaving mid-probe
        // is normal. Cancelling shortens the remaining sleep, which brings the
        // teardown forward — without this, two capture sources stay live (and
        // the macOS recording indicator stays on) after the screen is gone.
        .onDisappear { probeTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("Проверим, что orakul слышит комнату.",
                  systemImage: "waveform")
                .font(Typo.title).foregroundStyle(Theme.ink)
            // Deliberately does NOT restate the duration. The capture-check row
            // says "Six seconds" right next to the button that spends them, and
            // saying it twice two lines apart reads as a mistake, not emphasis.
            Text("Два разрешения и короткая проверка. Бот в звонок не заходит — orakul слушает на этом компьютере.")
                .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(spacing: Space.s) {
            PermissionRow(
                icon: "mic.fill",
                title: "Микрофон",
                detail: "Ваша половина разговора.",
                granted: state.micGranted,
                kind: .microphone,
                alreadyAsked: askedMicrophone,
                action: {
                    askedMicrophone = true
                    Task { await state.requestMicrophonePermission() }
                })

            PermissionRow(
                icon: "rectangle.on.rectangle",
                title: "Запись экрана",
                detail: "Звук собеседников — через ScreenCaptureKit. Снимки экрана не делаются.",
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
            if advice != .none {
                AdviceRow(advice: advice)
            }
        }
    }

    /// Pinned below the scroll. Continue must always be reachable — a first-run
    /// user who cannot find it is stuck on the first screen of the product.
    private var footer: some View {
        HStack(spacing: Space.m) {
            // Было «Вы не вошли — расшифровка на устройстве всё равно без
            // ограничений»: первая строка, которую видит новый человек, начиналась
            // с упоминания входа, которого в orakul нет. Отвечала на вопрос,
            // которого он не задавал, и подсказывала, что где-то есть аккаунт.
            Text("Аккаунта нет и не нужно — расшифровка идёт на этом компьютере, без ограничений.")
                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button("Продолжить", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Продолжить")
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
                Label("Выдано", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption.weight(.medium))
                    .foregroundStyle(Theme.speakerYou)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Разрешено: \(title)")
            case .request:
                Button("Включить", action: action)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Разрешить: \(title)")
            case .openSettings:
                // macOS will not prompt a second time, so pressing Enable again
                // would do nothing at all. Send them where the toggle lives.
                Button("Открыть системные настройки") {
                    if let url = PermissionPrompt.settingsURL(for: kind) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Открыть системные настройки: \(title)")
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
        case .pass:       return ("Слышно оба источника", Theme.speakerYou)
        case .micOnly:    return ("Нет звука собеседников", Theme.amber)
        case .systemOnly: return ("Нет микрофона", Theme.amber)
        case .silent:     return ("Ничего не слышно", Theme.amber)
        case nil:         return (probe.isRunning ? "Слушаю…" : "Проверка не запускалась",
                                  Theme.inkTertiary)
        }
    }

    var body: some View {
        OnboardingRow(
            icon: "waveform.badge.magnifyingglass",
            title: "Проверка захвата",
            detail: probe.isRunning
                ? "Скажите что-нибудь и включите любой звук — видео, песню."
                : "Шесть секунд. Покажет, что оба источника слышны, ещё до первого звонка.",
            trailing: {
                if probe.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(probe.verdict == nil ? "Проверить" : "Ещё раз", action: start)
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("Проверить захват звука")
                }
            },
            footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ProbeMeter(label: "Вы", level: probe.micLevel,
                               peak: probe.micPeak, tint: Theme.speakerYou)
                    ProbeMeter(label: "Собеседники", level: probe.systemLevel,
                               peak: probe.systemPeak, tint: Theme.speakerThem)
                    Text(status.text)
                        .font(Typo.caption.weight(.medium))
                        .foregroundStyle(status.tint)
                        .accessibilityLabel("Проверка захвата: \(status.text)")
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
                // Колонка была 76 pt под английское «System audio». Русская
                // подпись длиннее и переносилась посреди слова: «Звук /
                // собеседнико / в». Ширины мало, поэтому подпись ещё и держится
                // одной строкой — следующий перевод не должен снова ломать
                // слово пополам.
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 104, alignment: .leading)
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

/// The one thing worth saying after a failed check — and only ever one.
///
/// Три разных случая раньше показывались как один: «перезапустите». Двум из них
/// перезапуск не помогает ничем, и человек попадал в круг без выхода.
/// Not `private`: a pure function returning `.regrant` proves nothing if the
/// view still renders the relaunch button, and that gap is where this bug lived.
struct AdviceRow: View {
    let advice: CaptureProbe.Advice

    var body: some View {
        switch advice {
        case .none:
            EmptyView()

        case .relaunch:
            OnboardingRow(
                icon: "arrow.clockwise.circle",
                iconTint: Theme.amber,
                title: "macOS ещё не применила разрешение на запись экрана",
                detail: "Особенность macOS, а не ошибка orakul: разрешение начинает действовать со следующего запуска. Ничего не потеряется."
            ) {
                Button("Выйти и открыть заново") { relaunch() }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .accessibilityLabel("Выйти и открыть orakul заново")
            }

        case .regrant:
            // Перезапуск уже был и не помог — значит дело не в нём. Дальше
            // честнее не угадывать причину, а назвать действие, которое чинит
            // все известные: разрешение записано за старую версию программы и
            // к текущей не применяется. Снять галочку и поставить заново.
            OnboardingRow(
                icon: "exclamationmark.triangle",
                iconTint: Theme.amber,
                title: "Перезапуск не помог — разрешение придётся выдать заново",
                detail: "Так бывает, когда разрешение записано за прежнюю версию orakul: после обновления или когда рядом лежит вторая копия программы. Откройте настройки, снимите галочку у orakul, поставьте её снова — и запустите orakul заново."
            ) {
                Button("Открыть системные настройки") {
                    if let url = PermissionPrompt.settingsURL(for: .screenRecording) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .accessibilityLabel("Открыть системные настройки: запись экрана")
            }

        case .moveToApplications:
            // Самый частый настоящий ответ на «перезапустил, и всё равно
            // просит перезапустить»: приложение запущено из образа или из
            // «Загрузок». macOS в этом случае запускает его из временной копии
            // со случайным адресом, и разрешение, выданное вчерашней копии, к
            // сегодняшней не относится. Перезапуск тут не поможет никогда.
            OnboardingRow(
                icon: "folder.badge.gearshape",
                iconTint: Theme.amber,
                title: "Перенесите orakul в «Программы»",
                detail: "Сейчас orakul запущен из образа или из «Загрузок». macOS запускает такие программы из временной копии со случайным адресом, а разрешение помнит по адресу — поэтому оно и не сохраняется между запусками. Перетащите orakul в «Программы», запустите оттуда и выдайте разрешение заново."
            ) {
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .accessibilityLabel("Показать orakul в Finder")
            }

        case .noSoundPlaying:
            // Захват работает — просто звучать было нечему. Раньше этот случай
            // предлагал перезапуск, хотя перезапускать нечего.
            OnboardingRow(
                icon: "speaker.slash",
                iconTint: Theme.inkTertiary,
                title: "Звука собеседников не было слышно",
                detail: "Запись экрана работает — orakul подключился к системному звуку без ошибок. Похоже, в эти шесть секунд ничего не играло. Включите видео или песню погромче и нажмите «Ещё раз»."
            ) {
                EmptyView()
            }
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
            title: "Модель на устройстве",
            // Size of the model THIS Mac will fetch, not a fixed number: the old
            // "~150 MB" was only true for `base`, while a 16 GB Apple Silicon
            // machine pulls ~480 MB and a Max/Ultra ~1.5 GB. Promising 150 MB and
            // downloading ten times that is how someone abandons onboarding on a
            // tethered connection.
            detail: "Модель распознавания речи (\(LocalWhisperModel.approxDownloadForThisMac(selected: Config.localWhisperModel))) скачается один раз и дальше работает без сети."
        ) {
            switch stateValue {
            case .preparing:
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Готовлю…").font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            case .ready:
                Label("Готово", systemImage: "checkmark.circle.fill")
                    .font(Typo.caption.weight(.medium))
                    .foregroundStyle(Theme.speakerYou)
                    .labelStyle(.titleAndIcon)
            case .failed:
                Button("Повторить", action: retry).buttonStyle(QuietButtonStyle())
            case .idle:
                Button("Скачать", action: retry).buttonStyle(QuietButtonStyle())
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
