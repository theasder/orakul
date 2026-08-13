import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OnboardingGate {
    static func shouldPresent(completed: Bool,
                              microphoneGranted: Bool,
                              screenRecordingGranted: Bool) -> Bool {
        !completed || !microphoneGranted || !screenRecordingGranted
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    /// Which act to open on. Resolved once permissions have been re-checked, so
    /// a revoked permission reopens the capture check even mid-flow.
    @State private var onboardingStep: OnboardingStep? = OnboardingGate.step(
        lastCompleted: Config.onboardingStep,
        microphoneGranted: true,
        screenRecordingGranted: true)
    /// Derived from the same gate as everything else. Spelling the rule out a
    /// second time here (`!= .sample`) meant adding a third step would silently
    /// stop presenting the sheet.
    @State private var showOnboarding = OnboardingGate.step(
        lastCompleted: Config.onboardingStep,
        microphoneGranted: true,
        screenRecordingGranted: true) != nil

    @ObservedObject private var panes = PaneLayoutStore.shared

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            // Backlog item 3: each pane shows or hides independently (View
            // menu, ⌥⌘1-3), so the window can be a transcript-only reading
            // pane or an assistant-only answer pane. The store guarantees at
            // least one pane is always visible, and the toggles live in the
            // menu bar — a place no pane can hide.
            // Every pane pins to the window height. Without maxHeight the
            // HStack CENTRES a column whose content outgrows a short window,
            // clipping both ends at once — the brand rose under the traffic
            // lights while the sidebar footer and the composer fell off the
            // bottom, and the internal ScrollViews never got the chance to
            // absorb the difference.
            HStack(spacing: 0) {
                if panes.layout.sidebar {
                    Sidebar()
                        // Гибкая ширина, а не жёсткая — по той же причине, что
                        // и `maxHeight` ниже, только по горизонтали.
                        //
                        // Было `.frame(width: 264)`. Когда окно уже суммы
                        // минимумов трёх колонок (264 + 360 + 340), HStack
                        // сжимает эту колонку, а её содержимое всё равно
                        // раскладывается на 264 и ЦЕНТРИРУЕТСЯ в том, что
                        // осталось. Вылезает сразу за оба края, и у каждой
                        // строки пропадает первая буква: «АСТРОЙКА» вместо
                        // «НАСТРОЙКА», «о-пилот» вместо «Ко-пилот». Чем шире
                        // ставили колонку, тем больше букв съедало — на 400
                        // пропадало уже «НАСТ».
                        //
                        // Гибкая ширина оказалась лечением симптома и своей
                        // ценой: колонка проседала до минимума (у панели
                        // ассистента idealWidth 392, и она перетягивала), а в
                        // 216 уже не помещался ряд «Добавить источник ·
                        // Наборы» — подпись вылезала за иконку.
                        //
                        // Настоящая причина была не в ширине колонки, а в том,
                        // что ScrollView не навязывал ширину содержимому: это
                        // чинится в Sidebar через GeometryReader. Здесь снова
                        // 264 — ширина, выбранная под макет. `alignment:
                        // .leading` остаётся: если содержимое когда-нибудь всё
                        // же окажется шире, пусть режет хвост, а не начало.
                        .frame(width: 264, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.sidebar)
                        .overlay(alignment: .trailing) { Hairline(vertical: true) }
                }

                if panes.layout.transcript {
                    MeetingColumn()
                        .frame(minWidth: 360, maxWidth: .infinity)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                if panes.layout.assistant {
                    if panes.layout.transcript { Hairline(vertical: true) }
                    AIStudioView()
                        // maxWidth .infinity when it is the reading surface:
                        // an assistant-only window should use the window.
                        .frame(minWidth: 340, idealWidth: 392,
                               maxWidth: panes.layout.transcript ? 460 : .infinity)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.canvas)
                }
            }
            .animation(Motion.smooth, value: panes.layout)
        }
        // OVERLAY, not safeAreaInset. As an inset the toast RESERVED its own
        // height, so every column — sidebar, transcript, assistant composer —
        // shifted up the moment an error appeared, and a 4-line error (a long
        // provider payload, say) visibly broke the footers. Floating it leaves
        // the layout untouched.
        .overlay(alignment: .bottom) { ErrorToast() }
        .animation(Motion.smooth, value: state.lastError)
        .overlay {
            if let notice = state.liveTestMandatoryNotice {
                MandatoryInformationOverlay(notice: notice)
            }
        }
        .animation(Motion.smooth, value: state.liveTestMandatoryNotice)
        .background {
            if #available(macOS 14.0, *), Config.isDevBuild {
                LiveTestSettingsBridge()
            }
        }
        .task {
            // A rename/re-sign can invalidate TCC while the old onboarding flag
            // remains true. Re-check effective permissions every launch and
            // restore the pre-flight sheet whenever either capture source is
            // unavailable.
            await state.refreshPermissionStatus()
            onboardingStep = OnboardingGate.step(
                lastCompleted: Config.onboardingStep,
                microphoneGranted: state.micGranted,
                screenRecordingGranted: state.screenRecordingGranted)
            showOnboarding = onboardingStep != nil

            // Keychain XPC can wait on a stale signing ACL. Restore connection
            // badges only after the first window exists, and never on the main
            // actor that drives layout, recording controls, and accessibility.
            async let accounts: Void = state.loadPersistedConnectionState()
            async let apps: Void = mcp.loadPersistedAuthorization()
            // Attached folders are re-resolved from their security-scoped
            // bookmarks and rescanned here, so a folder attached last session is
            // current rather than serving the contents it had when it was picked.
            // Dismissed calendar rows are re-read here: the calendar is polled
            // constantly, so a dismissal that did not survive relaunch would
            // reappear on the next refresh.
            state.loadDismissedMeetings()
            async let folders: Void = state.restoreContextFolders()
            _ = await (accounts, apps, folders)
        }
        // Settings ▸ General ▸ "Показать настройку заново". Settings is its own
        // window, so the request arrives through the shared AppState rather than
        // a notification. The gate is re-run rather than forcing the first step:
        // a user who already granted both permissions should land on the sample
        // call, not sit through a capture check with nothing left to ask for.
        .onChange(of: state.onboardingReplayToken) { _ in
            onboardingStep = OnboardingGate.step(
                lastCompleted: Config.onboardingStep,
                microphoneGranted: state.micGranted,
                screenRecordingGranted: state.screenRecordingGranted)
                ?? OnboardingStep.allCases.first
            showOnboarding = true
        }
        .sheet(isPresented: $state.showRecordingConsent) { RecordingConsentSheet() }
        // Raised by stopRecording() when the first real meeting ends.
        // FirstMeetingPrompt has already recorded that it was asked by the time
        // this presents, so dismissing without answering closes it for good.
        .sheet(isPresented: $state.showFirstMeetingFeedback) { FirstMeetingFeedbackSheet() }
        // First-run pre-flight takes precedence — the paywall never fires
        // before a value moment, so there is no sheet contention here.
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(startingAt: onboardingStep)
        }
    }

}

/// Gives the nonce-gated live suite the same SwiftUI `openSettings` action as
/// the real SettingsLink. AppKit's legacy selector is a silent no-op on macOS
/// 14, so using it would produce a false test of a window that never opened.
@available(macOS 14.0, *)
private struct LiveTestSettingsBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                LiveTestHooks.registerSettingsOpener { openSettings() }
            }
            .onDisappear {
                LiveTestHooks.registerSettingsOpener(nil)
            }
    }
}

/// A true blocking information surface for the dev live-test fixture. It is
/// identified and must be acknowledged (or instance-cleared by the harness),
/// so it exercises modal overlap without borrowing production quota state.
private struct MandatoryInformationOverlay: View {
    @EnvironmentObject var state: AppState
    let notice: AppState.LiveTestMandatoryNotice

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Space.m) {
                Label("Нужны данные", systemImage: "exclamationmark.shield.fill")
                    .font(Typo.headline)
                    .foregroundStyle(Theme.ink)
                Text(notice.message)
                    .font(Typo.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Понятно") {
                        state.debugClearMandatoryNotice(id: notice.id)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Space.xl)
            .frame(width: 420)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
            .softShadow()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Обязательные сведения")
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Center column: meeting header + notes-first transcript

private struct MeetingColumn: View {
    @EnvironmentObject var state: AppState

    private static let dateFormatter: DateFormatter =
        // Было "EEEE, MMM d · h:mm a" без локали: на английской macOS шапка
        // русского приложения читалась как «Wednesday, Aug 12 · 1:16 AM».
        // AM/PM в русском не используется — часы двадцатичетырёхчасовые.
        DisplayFormatting.displayFormatter("EEEE, d MMMM · HH:mm")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: Space.s) {
                SectionLabel("Транскрипт")
                Spacer()
                downloadTranscriptButton
                diarizeControl
                livePill
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.s)

            if let notice = state.transcriptionPerformanceNotice {
                TranscriptionPerformanceBanner(notice: notice)
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.s)
            }

            TranscriptView()
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            MeetingTitleField(title: $state.meetingTitle)
            // 5 minutes in and still untitled → a proposed name, never
            // silently applied (mirrors the co-pilot goal chip).
            if let suggested = state.suggestedMeetingTitle {
                HStack(spacing: Space.xs) {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("“\(suggested)”")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button("Использовать") { state.acceptSuggestedMeetingTitle() }
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .help("Назвать звонок предложенным заголовком")
                    Button { state.dismissSuggestedMeetingTitle() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Скрыть")
                }
            }
            HStack(spacing: Space.s) {
                Text(Self.dateFormatter.string(from: state.sessionDate))
                if state.totalContextSources > 0 {
                    Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                    Text(contextLabel(state.totalContextSources))
                }
            }
            .font(Typo.caption)
            .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xl)
        .padding(.top, kContentTopInset)
        .padding(.bottom, Space.l)
    }

    private func contextLabel(_ n: Int) -> String {
        "\(n) context source\(n == 1 ? "" : "s")"
    }

    /// Download the current transcript as a plain-text file. Hidden until
    /// there's something to save; disabled while diarization/enhancement is
    /// still rewriting entries so the file reflects the finished transcript.
    @ViewBuilder
    private var downloadTranscriptButton: some View {
        if !state.transcript.isEmpty {
            Button { downloadTranscript() } label: {
                Image(systemName: "arrow.down.doc")
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .disabled(state.diarizing || state.enhancingTranscript)
            .help("Скачать транскрипт текстовым файлом")
            .accessibilityLabel("Скачать транскрипт")
        }
    }

    private func downloadTranscript() {
        let text = TranscriptExporter.plainText(
            title: state.meetingTitle,
            date: state.sessionDate,
            entries: state.transcript)
        let panel = NSSavePanel()
        panel.title = "Скачать транскрипт"
        panel.prompt = "Сохранить"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let txt = UTType(filenameExtension: "txt") {
            panel.allowedContentTypes = [txt]
        }
        panel.nameFieldStringValue = TranscriptExporter.suggestedFilename(
            title: state.meetingTitle, date: state.sessionDate)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            state.lastError = "Не удалось сохранить транскрипт: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var diarizeControl: some View {
        if state.enhancingTranscript {
            HStack(spacing: Space.xs) {
                BreathingDots(tint: Theme.accent)
                Text("Дополняю из Fireflies…")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else if state.diarizing {
            HStack(spacing: Space.xs) {
                BreathingDots(tint: Theme.accent)
                Text("Определяю говорящих…")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else {
            HStack(spacing: Space.s) {
                if state.canEnhanceWithFireflies {
                    Button { state.enhanceTranscriptWithFirefliesNow() } label: {
                        Label("Дополнить из Fireflies", systemImage: "flame")
                    }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .help("Свести локальную расшифровку с транскриптом Fireflies и вычистить моделью")
                }
                if state.canRetranscribeLocally {
                    Button { state.retranscribeLocallyNow() } label: {
                        Label(state.localRetranscribing ? "Re-transcribing…" : "Расшифровать заново на устройстве",
                              systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(QuietButtonStyle(prominent: false))
                    .disabled(state.localRetranscribing)
                    // Free and offline, so it is offered without the cost
                    // warning the cloud pass carries.
                    .help("""
                    Читает запись целиком одним проходом, а не шестисекундными \
                    кусками, как во время звонка. На настоящих звонках вышло на 32% \
                    точнее. Работает на этом компьютере — ничего не уходит наружу — \
                    и занимает около минуты на восемь минут записи.
                    """)
                    .accessibilityIdentifier("postcall.retranscribeLocal")
                }
                if state.canDiarize {
                    Button { state.diarizeNow() } label: {
                        // Named for the larger of the two things it does. It
                        // was "Diarize in cloud", which gave nobody who did not
                        // want speaker labels a reason to press it — while
                        // measured against human references this replaces the
                        // remote-side transcript with one 57% more accurate on
                        // work calls, and more on accented speech.
                        Label("Улучшить транскрипт", systemImage: "wand.and.stars")
                    }
                    // Not prominent while a free Fireflies merge is pending:
                    // Fireflies recorded the same meeting and its merge is
                    // automatic and already paid for, so this would charge for
                    // work already in progress.
                    .buttonStyle(QuietButtonStyle(prominent: !state.firefliesEnhancePending))
                    .help(state.firefliesEnhancePending
                          ? """
                          Fireflies уже подмешивает свою расшифровку этого звонка, \
                          сам и без доплаты. Это нужно, только если ждать не хочется: \
                          запись уйдёт повторно в \(state.diarizeDestination) и \
                          израсходует там минуты расшифровки.
                          """
                          : """
                          Расшифровывает вторую сторону звонка в облаке и подписывает \
                          говорящих. Заметно точнее расшифровки на компьютере, особенно \
                          на речи с акцентом. Сохранённый звук собеседника уйдёт в \
                          \(state.diarizeDestination) и израсходует там минуты расшифровки.
                          """)
                }
                if let note = state.transcriptEnhanceNote, !note.isEmpty {
                    Text(note)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var livePill: some View {
        switch state.status {
        case .recording:
            // Just the live dot — the elapsed timer was removed (operator
            // request); the menu bar and overlay still show the full clock.
            StatusDot(color: Theme.recordRed, live: true, size: 6)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.dangerSoft))
        case .starting, .stopping:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(state.status == .starting ? "Starting" : "Stopping")
                    .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
            }
        default:
            EmptyView()
        }
    }
}

private struct TranscriptionPerformanceBanner: View {
    @EnvironmentObject var state: AppState
    let notice: TranscriptionPerformanceNotice

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "speedometer")
                .foregroundStyle(Theme.accent)
            Text(notice.message)
                .font(Typo.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if notice.action == .useDeepgram {
                Button("Использовать Deepgram в следующей записи") {
                    state.useRecommendedDeepgramForNextRecording()
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
            }
            Button {
                state.dismissTranscriptionPerformanceNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityLabel("Скрыть совет о производительности")
        }
        .padding(Space.m)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

// MARK: - Editable title

private struct MeetingTitleField: View {
    @Binding var title: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $title, prompt: Text("Звонок без названия").foregroundColor(Theme.inkTertiary))
            .textFieldStyle(.plain)
            .font(Typo.displayL)
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(title.isEmpty ? "" : title)
    }
}

// MARK: - Error toast

private struct ErrorToast: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let err = state.lastError {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .font(.system(size: 13))
                Text(err)
                    .font(Typo.callout)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .help(err)
                Spacer(minLength: Space.s)
                Button {
                    state.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .accessibilityLabel("Скрыть ошибку")
                .help("Скрыть ошибку")
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.25), lineWidth: 1)
            )
            .softShadow()
            .padding(.bottom, Space.xl)
            .padding(.horizontal, Space.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
