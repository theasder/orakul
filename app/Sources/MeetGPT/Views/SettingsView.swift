import SwiftUI
import OrakulCore

enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case transcription
    case ai
    case connectedApps
    case accountPrivacy
}

/// Settings, restructured from a single 820pt scroll into macOS-idiomatic tabs
/// (see docs/ui-audit IA): General (app behavior) · Transcription · AI (models
/// + co-pilot) · Connected Apps (Google, MCP, team sources) · Account &
/// Privacy (sign-in, deletion, consent, data routing). Each tab sizes itself;
/// the window adapts per tab as macOS users expect.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.settings)
    }

    @ViewBuilder private var trackedBody: some View {
        TabView(selection: $state.selectedSettingsTab) {
            GeneralSettingsTab()
                .tabItem { Label("Общее", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionSettingsTab()
                .tabItem { Label("Расшифровка", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            AISettingsTab()
                .tabItem { Label("ИИ", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            ConnectedAppsTab()
                .tabItem { Label("Рабочие приложения", systemImage: "app.connected.to.app.below.fill") }
                .tag(SettingsTab.connectedApps)
            AccountPrivacyTab()
                .tabItem { Label("Аккаунт и приватность", systemImage: "person.badge.key") }
                .tag(SettingsTab.accountPrivacy)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Tab 1 · General (set-once app behavior)

private struct GeneralSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var appearance: AppAppearance = Config.appAppearance
    @State private var readingScale: Double = Config.readingTextScale
    @State private var callDetection: Bool = Config.callDetectionEnabled
    @State private var ignoreMedia: Bool = Config.ignoreMediaApps
    @State private var reminders: Bool = Config.meetingRemindersEnabled
    @State private var blindSpotBanners: Bool = Config.blindSpotTextNotificationsEnabled
    @State private var reminderMinutes: Int = Config.meetingReminderMinutes
    @State private var customRole: String = Config.userCustomRole

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            SettingsSection(title: "Оформление",
                            caption: "«Авто» следует за системой; «Светлое» и «Тёмное» переопределяют её.") {
                SettingsRow {
                    Label("Оформление", systemImage: "circle.lefthalf.filled")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Picker("", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .onChange(of: appearance) { state.setAppearance($0) }
                    .accessibilityLabel("Оформление")
                    .accessibilityIdentifier("settings.general.theme")
                }
                SettingsRow {
                    Label("Размер текста", systemImage: "textformat.size")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    // Applies to the transcript and the assistant answer only.
                    // Scaling the chrome as well would collide the controls at
                    // the smallest supported window, and prose is what people
                    // mean by "bigger text".
                    Picker("", selection: $readingScale) {
                        ForEach(ReadingTextScale.steps, id: \.self) { step in
                            Text(ReadingTextScale.label(for: step)).tag(step)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .onChange(of: readingScale) { state.readingTextScale = $0 }
                    .accessibilityLabel("Размер текста")
                    .accessibilityIdentifier("settings.general.readingTextSize")
                }
            }

            // The setup guide runs once and never returns, because the gate
            // records the last step FINISHED. Someone who clicked past the
            // capture check had no way back to it — and no way to re-run the
            // six-second test that proves both audio sources are audible, which
            // is the check that answers "why is the other side silent?" before a
            // real call does.
            SettingsSection(title: "Первая настройка",
                            caption: "Заново пройдёт проверку разрешений, проверку захвата звука и показ на примере. Ничего, кроме самой настройки, не сбрасывается.") {
                SettingsRow {
                    Label("Показать настройку заново", systemImage: "arrow.counterclockwise")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Button("Показать") { state.replayOnboarding() }
                        .accessibilityIdentifier("settings.general.replayOnboarding")
                }
            }

            SettingsSection(title: "Профиль",
                            caption: "Роль меняет способ, которым ИИ разбирает звонок: у менеджера продукта и у основателя итог получается разный. Выберите из списка или напишите свою. Роль переключается и в боковой панели.") {
                SettingsRow {
                    Label("Ваша роль", systemImage: "person.text.rectangle")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Picker("", selection: $state.userRoleID) {
                        Text("Не задано").tag(String?.none)
                        Divider()
                        ForEach(RoleSkillMatrix.positions) { position in
                            Text(position.label).tag(String?.some(position.id))
                        }
                        Divider()
                        Text("Написать своё…").tag(String?.some(RoleSkillMatrix.customRoleID))
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Ваша роль")
                    .accessibilityIdentifier("settings.general.role")
                }
                if state.userRoleID == RoleSkillMatrix.customRoleID {
                    SettingsRow {
                        TextField("например, руководитель роста в финтех-стартапе",
                                  text: $customRole)
                            .textFieldStyle(.plain)
                            .font(Typo.callout)
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Space.m)
                            .frame(height: 30)
                            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1))
                            .onChange(of: customRole) { Config.userCustomRole = $0 }
                            .accessibilityLabel("Своя роль")
                            .accessibilityIdentifier("settings.general.custom-role")
                    }
                }
            }

            SettingsSection(title: "Во время звонка",
                            caption: "orakul замечает, что открылось приложение для звонков, и предлагает начать запись.") {
                SettingsRow {
                    Label("Сообщать о звонках", systemImage: "bell.badge")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $callDetection)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: callDetection) { Config.callDetectionEnabled = $0; state.applyCallDetectionSettings() }
                        .accessibilityLabel("Сообщать о звонках")
                        .accessibilityIdentifier("settings.general.call-detection")
                }
                SettingsRow {
                    Label("Игнорировать музыку и видео", systemImage: "music.note.tv")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $ignoreMedia)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!callDetection)
                        .onChange(of: ignoreMedia) { Config.ignoreMediaApps = $0 }
                        .accessibilityLabel("Игнорировать музыку и видео")
                        .accessibilityIdentifier("settings.general.ignore-media")
                }
            }

            SettingsSection(title: "Во время звонка",
                            caption: "Тихий баннер, когда найдена новая слепая зона, а orakul свёрнут — только текст, без звука.") {
                SettingsRow {
                    Label("Плашки слепых зон", systemImage: "bell.badge")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $blindSpotBanners)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: blindSpotBanners) { Config.blindSpotTextNotificationsEnabled = $0 }
                        .accessibilityLabel("Плашки слепых зон")
                        .accessibilityIdentifier("settings.general.blindSpotBanners")
                }
            }

            SettingsSection(title: "Перед встречей",
                            caption: state.googleConnected
                                ? "Напоминания приходят заранее — перед встречей в календаре."
                                : "Напоминаниям нужен Google Календарь — подключите его во вкладке «Подключённые приложения».") {
                SettingsRow {
                    Label("Напоминать перед встречами", systemImage: "bell.and.waves.left.and.right")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $reminders)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: reminders) { Config.meetingRemindersEnabled = $0; state.applyReminderSettings() }
                        .accessibilityLabel("Напоминать перед встречами")
                        .accessibilityIdentifier("settings.general.reminders")
                }
                SettingsRow {
                    Label("Время до встречи", systemImage: "clock")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Picker("", selection: $reminderMinutes) {
                        Text("за 1 минуту").tag(1)
                        Text("за 5 минут").tag(5)
                        Text("за 10 минут").tag(10)
                        Text("1за 5 минут").tag(15)
                        Text("за 30 минут").tag(30)
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .disabled(!reminders)
                    .onChange(of: reminderMinutes) { Config.meetingReminderMinutes = $0; state.applyReminderSettings() }
                    .accessibilityLabel("За сколько напоминать")
                    .accessibilityIdentifier("settings.general.reminder-lead-time")
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onAppear {
            appearance = Config.appAppearance
            callDetection = Config.callDetectionEnabled
            ignoreMedia = Config.ignoreMediaApps
            reminders = Config.meetingRemindersEnabled
            blindSpotBanners = Config.blindSpotTextNotificationsEnabled
            reminderMinutes = Config.meetingReminderMinutes
            customRole = Config.userCustomRole
        }
    }
}

// MARK: - Tab 2 · Transcription

private struct TranscriptionSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var transcriptionLanguage: String = Config.transcriptionLanguage
    @State private var glossary: String = Config.transcriptionGlossary
    @State private var localModel: String = Config.localWhisperModel
    @State private var micNoiseSuppression: Bool = Config.micNoiseSuppressionEnabled
    @State private var adaptiveLocal: Bool = Config.adaptiveLocalWhisperEnabled
    @State private var postStopFinalPass: Bool = Config.transcriptionPostStopFinalPassEnabled
    @State private var assemblyDiarization: Bool = Config.assemblyAIDiarizationEnabled
    @State private var firefliesEnhance: Bool = Config.firefliesTranscriptEnhanceEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                SettingsSection(title: "Движок",
                                caption: "«Локально» оставляет звук звонка на этом компьютере. Deepgram или Whisper — значит, звук уходит к этому облачному провайдеру. Смена движка по ходу звонка действует сразу.") {
                    ForEach(TranscriptionEngine.selectableCases) { option in
                        EngineChoiceRow(engine: option,
                                        selected: state.selectedTranscriptionEngine == option,
                                        available: Config.engineAvailable(option)) {
                            // AppState owns the selected row because a WebSocket
                            // handoff can still fail asynchronously after this
                            // closure returns and must visibly roll back.
                            state.selectTranscriptionEngine(option)
                        }
                    }
                }

                SettingsSection(title: "Язык",
                                caption: "«Авто» переопределяет язык по ходу разговора. Если звонок целиком по-русски, выберите русский: на коротких и шумных кусках «Авто» ошибается. «Авто» нужен там, где в разговоре и правда два языка. Действует со следующей записи.") {
                    SettingsRow {
                        Label("Язык", systemImage: "globe")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Picker("", selection: $transcriptionLanguage) {
                            ForEach(Config.transcriptionLanguageOptions, id: \.code) { option in
                                Text(option.label).tag(option.code)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .frame(maxWidth: 220)
                        .onChange(of: transcriptionLanguage) { Config.transcriptionLanguage = $0 }
                        .accessibilityLabel("Язык расшифровки")
                        .accessibilityIdentifier("settings.transcription.language")
                    }
                }

                SettingsSection(title: "Микрофон",
                                caption: "Необязательная обработка Apple убирает эхо и фоновый шум, но при записи может приглушить звук из колонок. Оставьте выключенной, чтобы громкость не менялась; в наушниках этой платы нет. Действует со следующей записи.") {
                    SettingsRow {
                        Label("Шумоподавление Apple", systemImage: "waveform.badge.mic")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Toggle("", isOn: $micNoiseSuppression)
                            .labelsHidden().toggleStyle(.switch)
                            .onChange(of: micNoiseSuppression) { Config.micNoiseSuppressionEnabled = $0 }
                            .accessibilityLabel("Шумоподавление Apple")
                            .accessibilityIdentifier("settings.transcription.aec")
                    }
                }

                SettingsSection(title: "Дополнить из Fireflies",
                                caption: "Если Fireflies подключён, его расшифровка сводится с локальной после звонка (и при импорте из Fireflies). Имена и термины проекта модель уточняет по подключённым приложениям — Notion, CRM, трекерам: тайминг от Whisper, говорящие от Fireflies, написание из коннекторов.") {
                    SettingsRow {
                        Label("Дополнять транскрипт из Fireflies", systemImage: "flame")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Toggle("", isOn: $firefliesEnhance)
                            .labelsHidden().toggleStyle(.switch)
                            .onChange(of: firefliesEnhance) { Config.firefliesTranscriptEnhanceEnabled = $0 }
                            .accessibilityLabel("Дополнять транскрипт из Fireflies")
                            .accessibilityIdentifier("settings.transcription.fireflies-enhance")
                    }
                }

                if state.selectedTranscriptionEngine == .local {
                    SettingsSection(title: "Модель на устройстве",
                                    caption: "Модель побольше обычно точнее, но дольше качается и тяжелее работает. Смена действует со следующей записи.") {
                    Picker("", selection: $localModel) {
                        ForEach(LocalWhisperModel.options) { option in
                            Text("\(option.title) — \(option.id)").tag(option.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    .onChange(of: localModel) {
                        // An explicit pick is never rewritten by the default
                        // correction that downgrades over-provisioned machines.
                        Config.localModelChosenByUser = true
                        Config.localWhisperModel = $0
                    }
                    .accessibilityLabel("Модель распознавания на устройстве")
                    .accessibilityIdentifier("settings.transcription.local-model")
                    if let picked = LocalWhisperModel.options.first(where: { $0.id == localModel }) {
                        Text(picked.caption)
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsRow {
                        Label("Подстройка под машину", systemImage: "speedometer")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Toggle("", isOn: $adaptiveLocal)
                            .labelsHidden().toggleStyle(.switch)
                            .onChange(of: adaptiveLocal) { Config.adaptiveLocalWhisperEnabled = $0 }
                            .accessibilityLabel("Подстройка распознавания")
                            .accessibilityIdentifier("settings.transcription.adaptive")
                    }
                    Text("Если расшифровка раз за разом отстаёт, orakul возьмёт для следующей записи модель полегче. На Base предложит Deepgram, но в облако сам не уйдёт.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsSection(
                        title: "Уточнение после звонка",
                        caption: "Выключено по умолчанию. Если включить, orakul повторно прочитает сохранённый звук на этом Mac после остановки. Живая расшифровка останется, если новый результат неполный или потерял содержание.") {
                        SettingsRow {
                            Label("Уточнять после остановки", systemImage: "waveform.badge.checkmark")
                                .labelStyle(SettingLabelStyle())
                            Spacer()
                            Toggle("", isOn: $postStopFinalPass)
                                .labelsHidden().toggleStyle(.switch)
                                .onChange(of: postStopFinalPass) {
                                    Config.transcriptionPostStopFinalPassEnabled = $0
                                }
                                .accessibilityLabel("Уточнять локальную расшифровку после остановки")
                                .accessibilityIdentifier("settings.transcription.post-stop-final-pass")
                        }
                    }
                }

                if !Config.assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsSection(title: "Кто говорил — после звонка",
                                    caption: "Необязательная обработка через AssemblyAI. Действует со следующей записи: orakul сохраняет дорожку собеседников и отправляет её только после нажатия «Определить говорящих» — никогда сам по ходу звонка.") {
                        SettingsRow {
                            Label("Разрешить облачное определение говорящих", systemImage: "person.2.wave.2")
                                .labelStyle(SettingLabelStyle())
                            Spacer()
                            Toggle("", isOn: $assemblyDiarization)
                                .labelsHidden().toggleStyle(.switch)
                                .onChange(of: assemblyDiarization) { Config.assemblyAIDiarizationEnabled = $0 }
                                .accessibilityLabel("Разрешить облачное определение говорящих")
                                .accessibilityIdentifier("settings.transcription.assembly-diarization")
                        }
                    }
                }

                SettingsSection(title: "Свой словарь",
                                caption: "Названия продуктов, сокращения, имена — по одному в строке или через запятую. Подсказывает любому движку правильное написание. Термины из подключённых приложений сначала показываются на проверку; принятые действуют со следующей записи, даже если вы приняли их посреди звонка.") {
                    TextEditor(text: $glossary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .padding(Space.s)
                        .frame(height: 96)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if glossary.isEmpty {
                                Text("orakul, RICE, ARR, Kubernetes…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .padding(.horizontal, Space.s + 4).padding(.vertical, Space.s + 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: glossary) {
                            Config.transcriptionGlossary = $0
                            state.noteConnectedGlossaryManualEdit($0)
                        }
                        .accessibilityLabel("Свой словарь распознавания")
                        .accessibilityIdentifier("settings.transcription.glossary")
                    if !glossary.isEmpty {
                        // Русский счёт, а не «term/terms»: 1 термин, 2 термина,
                        // 5 терминов. Английское «-s» на числе — та мелочь, по
                        // которой сразу видно переведённый продукт.
                        Text("Активно \(Config.glossaryTerms.count) \(DisplayFormatting.termsWord(Config.glossaryTerms.count))")
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    }

                    Divider().overlay(Theme.hairline)

                    SettingsRow {
                        Label("Брать подсказки из рабочих приложений", systemImage: "app.connected.to.app.below.fill")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Toggle("", isOn: $state.useConnectedAppsInPrompts)
                            .labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Брать подсказки для расшифровки из рабочих приложений")
                            .accessibilityIdentifier("settings.transcription.glossary-suggestions.enabled")
                    }

                    SettingsRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Найти имена и термины")
                                .font(Typo.callout).foregroundStyle(Theme.ink)
                            Text(connectedGlossaryCostCaption)
                                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if state.connectedGlossarySuggestionStatus == .loading {
                            ProgressView().controlSize(.small)
                        }
                        Button("Найти термины") {
                            Task { await state.generateConnectedGlossarySuggestions() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!state.canGenerateConnectedGlossarySuggestions)
                        .accessibilityIdentifier("settings.transcription.glossary-suggestions.generate")
                    }

                    if state.connectedGlossarySourceCount == 0 {
                        HStack {
                            Text("Сначала подключите приложение, которое можно читать.")
                                .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            Spacer()
                            Button("Рабочие приложения") { state.selectedSettingsTab = .connectedApps }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("settings.transcription.glossary-suggestions.open-apps")
                        }
                    }

                    if let message = connectedGlossaryStatusMessage {
                        Text(message)
                            .font(Typo.caption)
                            .foregroundStyle(connectedGlossaryStatusIsError
                                ? Theme.danger : Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.transcription.glossary-suggestions.status")
                    }

                    if !state.connectedGlossarySuggestions.isEmpty {
                        ForEach(state.connectedGlossarySuggestions) { suggestion in
                            HStack(alignment: .top, spacing: Space.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.term)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.ink)
                                    Text(suggestion.reason + sourceSuffix(suggestion.sources))
                                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: Space.s)
                                Button("Скрыть") {
                                    state.rejectConnectedGlossarySuggestion(id: suggestion.id)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Скрыть \(suggestion.term)")
                                Button("Добавить") {
                                    if state.acceptConnectedGlossarySuggestion(id: suggestion.id) {
                                        glossary = Config.transcriptionGlossary
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityLabel("Добавить \(suggestion.term) в словарь расшифровки")
                            }
                            .padding(.vertical, 3)
                        }
                        HStack {
                            if let metrics = state.connectedGlossarySuggestionMetrics {
                                Text("\(metrics.sourceCount) source\(metrics.sourceCount == 1 ? "" : "s") · \(metrics.estimatedInputTokens) input tokens · ~\(metrics.estimatedComputeCredits) compute credits\(metrics.cached ? " · cached" : "")")
                                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer()
                            Button("Скрыть все") {
                                state.rejectAllConnectedGlossarySuggestions()
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("settings.transcription.glossary-suggestions.dismiss-all")
                        }
                    }
                }
            }
            .padding(Space.xl)
        }
        .frame(width: 520, height: 620)
        .onAppear {
            transcriptionLanguage = Config.transcriptionLanguage
            glossary = Config.transcriptionGlossary
            localModel = Config.localWhisperModel
            micNoiseSuppression = Config.micNoiseSuppressionEnabled
            adaptiveLocal = Config.adaptiveLocalWhisperEnabled
            postStopFinalPass = Config.transcriptionPostStopFinalPassEnabled
            assemblyDiarization = Config.assemblyAIDiarizationEnabled
            firefliesEnhance = Config.firefliesTranscriptEnhanceEnabled
        }
    }

    private var connectedGlossaryCostCaption: String {
        let model = LLMCatalog.background(for: Config.selectedModel)
        let credits = CreditCostEstimate.credits(model: model.id, inputTokens: 0)
        return "Прочитает не больше \(ConnectedGlossarySuggestionService.maxSources) коротких выдержек из приложений и отранжирует найденные термины моделью \(model.label). Транскрипт звонка при этом никуда не уходит."
    }

    private var connectedGlossaryStatusMessage: String? {
        if let message = state.connectedGlossarySuggestionMessage { return message }
        switch state.connectedGlossarySuggestionStatus {
        case .idle, .loading, .ready: return nil
        case .empty: return "Новых терминов из подключённых приложений нет."
        case .unavailable(let message), .failed(let message): return message
        }
    }

    private var connectedGlossaryStatusIsError: Bool {
        switch state.connectedGlossarySuggestionStatus {
        case .unavailable, .failed: return true
        default: return false
        }
    }

    private func sourceSuffix(_ sources: [String]) -> String {
        sources.isEmpty ? "" : " · " + sources.joined(separator: ", ")
    }
}

// MARK: - Tab 3 · AI (plan, model, co-pilot)

private struct AISettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // Блока «Тариф» здесь нет и не будет. Значок кредитной карты,
            // бейдж плана и кнопка «Управление…» — это интерфейс продукта, за
            // который платят; orakul бесплатен целиком, и строка про план
            // означала бы, что где-то есть другой.

            // Выше выбора модели: модель без ключа не отвечает, а в готовом
            // установщике ключей нет ни одного.
            SettingsSection(title: "Ключи провайдеров",
                            caption: "Ключ вводится один раз и лежит в Связке ключей. Расход идёт по вашему договору с провайдером — orakul не посредник и денег не берёт. Без ключа модель не ответит: в готовые установщики ключи не зашиваются намеренно.") {
                ProviderKeysSection()
            }

            SettingsSection(title: "Модель",
                            caption: "Выберите провайдера и версию — или оставьте «Авто», и orakul выберет под запрос. Доступны все модели: закрытых нет.") {
                ModelSelectionRows()
            }

            SettingsSection(title: "Ко-пилот",
                            caption: "По ходу записи ищет слепые зоны — по вашей цели и расшифровке. Подключённые приложения он тоже спрашивает, российские трекеры в том числе. Наблюдения делят один часовой бюджет: выключите одно — остальные обновляются чаще. Кредитов и лимитов по тарифу нет.") {
                SettingsRow {
                    Label("Мозговой штурм на звонке", systemImage: "lightbulb")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.blindSpotsEnabled },
                        set: { state.setBlindSpotsEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Мозговой штурм на звонке")
                        .accessibilityIdentifier("settings.ai.brainstorm")
                }
                SettingsRow {
                    Label("Повестка и рамка", systemImage: "scope")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.agendaCheckingEnabled },
                        set: { state.setAgendaCheckingEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Повестка и рамка")
                        .accessibilityIdentifier("settings.ai.agenda")
                }
                SettingsRow {
                    Label("Проверка фактов на звонке", systemImage: "checkmark.seal")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.liveFactCheckingEnabled },
                        set: { state.setFactCheckDuringCallsEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Проверка фактов на звонке")
                        .accessibilityIdentifier("settings.ai.fact-check")
                }
                SettingsRow {
                    Label("Слежу за риторикой", systemImage: "text.badge.xmark")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.rhetoricWatchEnabled },
                        set: { state.setRhetoricDuringCallsEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Слежу за риторикой")
                        .accessibilityIdentifier("settings.ai.rhetoric")
                }
                SettingsRow {
                    Label("Слежу за ходом звонка", systemImage: "location.north.line")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { state.facilitationWatchEnabled },
                        set: { state.setFacilitationDuringCallsEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Слежу за ходом звонка")
                        .accessibilityIdentifier("settings.ai.facilitation")
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
    }
}

// MARK: - Tab 4 · Connected Apps (Google · MCP · team sources)

private struct ConnectedAppsTab: View {
    @EnvironmentObject var state: AppState
    @State private var teamSourcesExpanded = !TeamConnectors.configured.isEmpty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                // Первым блоком, а не по алфавиту: человек, у которого задачи
                // в Яндекс Трекере, ищет здесь именно его. Список, начатый с
                // Notion, читается как «нашего нет» — и дальше не листается.
                SettingsSection(title: "Российские трекеры",
                                caption: "MCP-серверов у этих сервисов нет, поэтому подключение по токену: создаёте его у себя в трекере и вставляете сюда. Токен лежит в Связке ключей, запросы уходят прямо в сервис.") {
                    RussianTrackersSection()
                }

                // Сразу за трекерами: вопрос соседний, но другой — не
                // «заводили ли задачу», а «обсуждали ли это». Ответ на второй
                // чаще лежит в переписке, чем в трекере.
                SettingsSection(title: "Рабочие мессенджеры",
                                caption: "Пачка, Mattermost и Rocket.Chat умеют искать по сообщениям, и orakul спрашивает их по ходу звонка. Подключение по токену, как у трекеров. Telegram и VK Teams сюда добавить нельзя: их Bot API не отдаёт историю чата и не ищет по ней.") {
                    WorkMessengersSection()
                }

                SettingsSection(title: "Открытые трекеры на своём сервере",
                                caption: "GitLab и Gitea (а также Forgejo — это форк Gitea с тем же API) команда поднимает у себя, поэтому кроме токена нужен адрес сервера. GitHub подключается выше: у него адрес один и тот же.") {
                    SelfHostedTrackersSection()
                }

                SettingsSection(title: "База знаний",
                                caption: "Outline умеет искать по документам, и orakul спрашивает его по ходу звонка: решение, записанное в вики полгода назад, не найдётся ни в задачах, ни в переписке. Яндекс Вики и Teamly подключить нельзя — у первой в открытой документации нет поиска по тексту, у второй нет публичного описания API.") {
                    TeamNotesSection()
                }

                SettingsSection(title: "Google",  // имя сервиса, не переводится
                                caption: "Календарь, Документы, Таблицы и Диск подключаются отдельными правами, которыми управляете вы. Поиск — только чтение; при экспорте orakul создаёт и меняет лишь те файлы, которые создал сам.") {
                    GoogleSignInRow()
                }

                SettingsSection(title: "Рабочие приложения",
                                caption: "MCP-серверы подключаются в одно нажатие: обычный OAuth в браузере, без ключей. Токены остаются в Связке ключей. Salesforce, Affinity и тысячи других — через Zapier.") {
                    MCPAppsSection()
                }

                SettingsSection(title: "Звонки — в ваш ИИ-инструмент",
                                caption: "orakul сам работает как MCP-сервер: ваши звонки и журнал решений доступны внутри Claude, ChatGPT, Cursor — любого инструмента с поддержкой MCP.") {
                    OwnMCPCard()
                }

                // Expanding block: collapsed by default unless connectors are
                // configured — most users never need this section.
                DisclosureGroup(isExpanded: $teamSourcesExpanded) {
                    TeamSourcesView()
                        .padding(.top, Space.s)
                } label: {
                    HStack(spacing: Space.s) {
                        SectionLabel("Источники команды")
                        if !TeamConnectors.configured.isEmpty {
                            Text("\(TeamConnectors.configured.count) configured")
                                .font(Typo.caption)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                .disclosureGroupStyle(.automatic)
            }
            .padding(Space.xl)
        }
        .frame(width: 560, height: 620)
    }
}

/// The Granola-style "public MCP URL + three steps" card. The URL is the
/// backend's /mcp endpoint; auth happens in the AI tool's own browser flow.
private struct OwnMCPCard: View {
    @State private var copied = false

    private var mcpURL: String {
        Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/mcp"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text(mcpURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .padding(.horizontal, Space.m)
                    .frame(height: 30)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpURL, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Typo.caption.weight(.medium))
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Скопировать адрес MCP")
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                setupStep(1, "В своём ИИ-инструменте добавьте orakul как коннектор по адресу выше.")
                setupStep(2, "Подтвердите вход в браузере — той же почтой, что и в orakul.")
                setupStep(3, "Переписка, поиск и работа с контекстом звонков в любом инструменте.")
            }
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Text("\(number)")
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Theme.accentSoft.opacity(0.5)))
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tab 5 · Account & Privacy

private struct AccountPrivacyTab: View {
    @State private var outboundRedaction: Bool = Config.outboundRedactionEnabled
    @State private var redactionTerms: String = Config.redactionTermsRaw
    @ObservedObject private var redactionLog = OutboundRedactionLog.shared
    @EnvironmentObject var state: AppState
    @State private var showSignIn = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var shareAnalytics: Bool = !Config.funnelOptOut
    @State private var devTierPreview: String = Config.devTierOverride?.rawValue ?? "off"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // Раздел показывается, только когда есть куда входить.
            //
            // Он единственный из четырёх мест со входом не был ничем закрыт —
            // остальные смотрят на `wheesprAvailable`, и после того как адрес
            // сервера перестал зашиваться, они исчезли сами. А этот оставался
            // на экране и обещал ровно то, чего у orakul нет: «модели без своих
            // ключей» (нет сервера) и синхронизацию журнала решений (тоже нет).
            // Ключ провайдера вводится ниже, в разделе «ИИ», и вход для него не
            // нужен.
            if !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SettingsSection(title: "Аккаунт",
                                caption: "Вход нужен, чтобы пользоваться моделями без своих ключей и синхронизировать журнал решений.") {
                    WheesprAccountRow(showSheet: $showSignIn)

                    if state.wheesprConnected {
                        SettingsRow {
                            Label("Удалить аккаунт", systemImage: "trash")
                                .labelStyle(SettingLabelStyle())
                            Spacer()
                            Button(deleting ? "Удаление…" : "Удалить…", role: .destructive) {
                                confirmDelete = true
                            }
                            .disabled(deleting)
                            .accessibilityIdentifier("settings.account.delete")
                        }
                    }
                }
            }

            SettingsSection(title: "Согласие на запись",
                            caption: "Перед первой записью вы подтвердили, что отвечаете за согласие участников. Если отозвать, экран согласия покажется снова.") {
                SettingsRow {
                    Label(Config.recordingConsentAccepted ? "Согласие подтверждено" : "Ещё не подтверждено",
                          systemImage: Config.recordingConsentAccepted ? "checkmark.shield" : "shield")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    if Config.recordingConsentAccepted {
                        Button("Отозвать") { Config.recordingConsentAccepted = false }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("settings.privacy.revoke-recording-consent")
                    }
                }
            }

            SettingsSection(title: "Убирать секреты перед отправкой",
                            caption: "Номера карт, ключи API, номера документов и подписанные учётные данные вырезаются из всего, что уходит провайдеру ИИ. Распознаются по структуре: у карты сходится контрольная сумма, у ключа есть известный префикс — поэтому обычные числа со звонка (даты, цены, номер переговорки) остаются на месте. Запрос при этом не блокируется: секрет убирается, остальное уходит.") {
                SettingsRow {
                    Label("Фильтровать исходящие запросы", systemImage: "eye.slash")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $outboundRedaction)
                        .labelsHidden()
                        .onChange(of: outboundRedaction) { Config.outboundRedactionEnabled = $0 }
                        .accessibilityLabel("Фильтровать исходящие запросы")
                        .accessibilityIdentifier("settings.privacy.outbound-redaction")
                }
                SettingsRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Убрать и эти термины", systemImage: "text.badge.minus")
                            .labelStyle(SettingLabelStyle())
                        Text("Кодовые названия проектов, имена клиентов — по одному в строке. Вырезаются везде, где встретятся.")
                            .font(Typo.caption)
                            .foregroundStyle(Theme.inkTertiary)
                        TextEditor(text: $redactionTerms)
                            .font(Typo.mono)
                            .frame(height: 64)
                            .onChange(of: redactionTerms) { Config.redactionTermsRaw = $0 }
                            .accessibilityIdentifier("settings.privacy.redaction-terms")
                    }
                }
                // Only when something was actually removed. A marker on every
                // session would train people to ignore it.
                if let summary = redactionLog.summary {
                    SettingsRow {
                        Label(summary, systemImage: "checkmark.shield")
                            .labelStyle(SettingLabelStyle())
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                    }
                }
            }

            SettingsSection(title: "Куда уходят ваши данные",
                            caption: "Расшифровка по умолчанию идёт на этом компьютере. Куски расшифровки уходят провайдеру выбранной модели только когда вы сами запускаете действие ИИ — чей это провайдер, видно в списке моделей. Ничего не продаётся и не используется для рекламы.") {
                EmptyView()
            }

            SettingsSection(title: "Аналитика использования",
                            caption: "Обезличенные события без cookie: какие экраны открывали, какие действия запускали. Без аккаунта, без содержимого звонков, без слежки между приложениями. Помогает понять, где приложение помогает, а где мешает. Выключите — не уйдёт ничего.") {
                SettingsRow {
                    Label("Отправлять обезличенную статистику", systemImage: "chart.bar.xaxis")
                        .labelStyle(SettingLabelStyle())
                    Spacer()
                    Toggle("", isOn: $shareAnalytics)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: shareAnalytics) { Config.funnelOptOut = !$0 }
                        .accessibilityLabel("Отправлять обезличенную статистику")
                        .accessibilityIdentifier("settings.privacy.analytics")
                }
            }

            if Config.isDevBuild {
                SettingsSection(title: "Для разработчика",
                                caption: "Только для сборок разработчика — в собранном приложении этого раздела нет. Превью переключает те же ограничения, что видит пользователь на этом плане. «Реальный доступ» возвращает как есть.") {
                    SettingsRow {
                        Label("Посмотреть тариф", systemImage: "wrench.and.screwdriver")
                            .labelStyle(SettingLabelStyle())
                        Spacer()
                        Picker("", selection: $devTierPreview) {
                            Text("Реальный доступ").tag("off")
                            ForEach(Tier.allCases) { tier in
                                Text(tier.label).tag(tier.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .onChange(of: devTierPreview) { state.setDevTierOverride(Tier(rawValue: $0)) }
                        .accessibilityLabel("Посмотреть тариф")
                        .accessibilityIdentifier("settings.developer.preview-plan")
                    }
                    if let preview = Tier(rawValue: devTierPreview) {
                        SettingsRow {
                            Label("В этот тариф входит", systemImage: "checklist")
                                .labelStyle(SettingLabelStyle())
                            Spacer()
                            Text(Self.devTierSummary(preview))
                                .font(Typo.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onAppear {
            shareAnalytics = !Config.funnelOptOut
            devTierPreview = Config.devTierOverride?.rawValue ?? "off"
        }
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .confirmationDialog("Удалить аккаунт?", isPresented: $confirmDelete) {
            Button("Удалить аккаунт и все данные", role: .destructive) {
                deleting = true
                Task {
                    _ = await state.deleteAccount()
                    deleting = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Учётная запись и сессии будут удалены с сервера навсегда. Звонков, сохранённых на этом компьютере, это не касается.")
        }
    }

    /// What the previewed plan grants, in the same units the app enforces.
    private static func devTierSummary(_ tier: Tier) -> String {
        let allowance = TariffAllowance.forTier(tier)
        let models = LLMCatalog.all.filter { $0.isAvailable(for: tier) }.count
        return "\(models) models · \(allowance.copilotHours) h co-pilot · "
            + "\(allowance.computeCredits) credits · \(allowance.groundedCycles) grounded cycles / mo"
    }
}

// MARK: - Shared building blocks

struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Space.m) { content }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: Space.s) { content }
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.top, Space.xxs)
        }
    }
}

/// One selectable transcription engine, presented by its core advantage.
private struct EngineChoiceRow: View {
    let engine: TranscriptionEngine
    let selected: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.inkTertiary)
                    .padding(.top, 1)
                Image(systemName: engine.advantageSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.advantageTitle)
                        .font(Typo.callout.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text(engine.advantageCaption)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !available {
                    Text("Нет в этой сборке")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(selected ? Theme.accentSoft.opacity(0.4) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
        .accessibilityLabel("\(engine.advantageTitle) transcription engine")
        .accessibilityValue(selected ? "Selected" : "Не выбрано")
        .accessibilityIdentifier("settings.transcription.engine.\(engine.rawValue)")
    }
}

// MARK: - Plan badge

private struct PlanBadge: View {
    let tier: Tier
    var body: some View {
        Text(tier.label.uppercased())
            .font(Typo.label)
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentSoft))
    }
}

// MARK: - Google sign-in

private struct GoogleSignInRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Label(state.googleConnected ? "Google Календарь подключён" : "Google Calendar",
                          systemImage: state.googleConnected ? "checkmark.seal.fill" : "calendar")
                        .labelStyle(SettingLabelStyle())
                    if state.googleConnected {
                        let count = state.promptWorkflowCount(usingSourcePrefix: "google:")
                        Text("\(count) prompt workflow\(count == 1 ? "" : "s") ready")
                            .font(Typo.caption)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer()
                if state.googleConnecting {
                    ProgressView().controlSize(.small)
                    Text("Подключаюсь…")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Button("Отмена") { state.cancelGoogleConnection() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.connected.google.cancel")
                } else if state.googleConnected {
                    Button("Отключить") { state.disconnectGoogle() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.connected.google.disconnect")
                } else {
                    GoogleSignInButton(enabled: state.hasGoogleSignInClient) {
                        Task { await state.connectGoogle() }
                    }
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

            // Granular authorization: each service is a separate scope in the
            // OAuth grant — disabled ones are excluded from the token itself.
            GoogleServiceToggles()

            if !state.hasGoogleClientID {
                Text("Добавьте GOOGLE_CLIENT_ID в mac/.env и пересоберите orakul.")
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
            } else if !state.hasGoogleClientSecret {
                Text("Добавьте GOOGLE_CLIENT_SECRET для того же клиента Google Desktop OAuth и пересоберите orakul.")
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
            } else if let error = state.googleConnectionError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.googleConnected,
                      Config.googleScopeVersion < GoogleAuth.scopeVersion
                        || Config.googleGrantedServices != Config.googleEnabledServices {
                HStack(spacing: Space.s) {
                    Text("Доступ или поиск изменились — переподключите, чтобы применить.")
                        .font(Typo.caption).foregroundStyle(Theme.accentText)
                    Button("Переподключить") { Task { await state.connectGoogle() } }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(state.googleConnecting)
                        .accessibilityIdentifier("settings.connected.google.reconnect")
                }
            }
        }
    }
}

/// Per-service switches controlling what the Google grant may cover.
private struct GoogleServiceToggles: View {
    @State private var enabled = Config.googleEnabledServices

    var body: some View {
        HStack(spacing: Space.l) {
            ForEach(GoogleService.requestable) { service in
                Toggle(service.label, isOn: Binding(
                    get: { enabled.contains(service.rawValue) },
                    set: { on in
                        if on { enabled.insert(service.rawValue) }
                        else { enabled.remove(service.rawValue) }
                        Config.googleEnabledServices = enabled
                    }
                ))
                .toggleStyle(.checkbox)
                .font(Typo.caption)
                .accessibilityIdentifier("settings.connected.google.service.\(service.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 6)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }
}

/// Google-styled sign-in button (white surface, colored "G", clear label).
private struct GoogleSignInButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text("G").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(enabled ? Theme.accent : Theme.inkTertiary)
                Text("Подключить Google Календарь")
                    .font(Typo.callout.weight(.semibold))
                    .foregroundStyle(enabled ? Theme.ink : Theme.inkTertiary)
            }
            .padding(.horizontal, Space.m).padding(.vertical, 7)
            .background(Capsule().fill(hovering && enabled ? Theme.surfaceHover : Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(enabled ? "Подключить Google Календарь (и, если нужно, Документы и Таблицы)" : "Google Календарь в этой сборке недоступен")
        .accessibilityIdentifier("settings.connected.google.connect")
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Account row (sign in / out)

private struct WheesprAccountRow: View {
    @EnvironmentObject var state: AppState
    @Binding var showSheet: Bool

    private var title: String {
        guard state.wheesprConnected else { return "Аккаунт" }
        if let email = state.wheesprEmail, !email.isEmpty { return "Вход выполнен · \(email)" }
        return "Вход выполнен"
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Label(title, systemImage: state.wheesprConnected ? "checkmark.seal.fill" : "person.crop.circle")
                .labelStyle(SettingLabelStyle())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !state.wheesprAvailable {
                Text("Недоступно в этой сборке")
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
            } else if state.wheesprConnected {
                Button("Выйти") { state.signOutWheespr() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("settings.account.sign-out")
            } else {
                Button("Войти") { showSheet = true }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .accessibilityIdentifier("settings.account.sign-in")
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Account sign-in: optional social (Apple / Google account) when the feature
/// flag is on, plus first-party Email code / Password / Phone.
struct SignInSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    // Additional providers (password / phone)
    @State private var method = "code"
    @State private var password = ""
    @State private var registering = false
    @State private var phone = ""
    @State private var phoneCodeSent = false
    @State private var working = false
    @State private var providerError: String?

    private var codeStep: Bool { state.pendingAuthEmail != nil }
    /// Judged per provider: Apple waits on App Store Connect verification,
    /// Google only needs a configured client.
    private var showsApple: Bool { SocialSignIn.showsApple() }
    private var showsGoogle: Bool {
        SocialSignIn.showsGoogle(hasClient: state.hasGoogleSignInClient)
    }
    private var socialEnabled: Bool {
        SocialSignIn.showsDivider(apple: showsApple, google: showsGoogle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Войти", systemImage: "person.crop.circle").font(Typo.title).foregroundStyle(Theme.ink)

            if socialEnabled {
                socialButtons
                HStack {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Text("or").font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }

            Picker("", selection: $method) {
                Text("Код из письма").tag("code")
                Text("Пароль").tag("password")
                Text("Телефон").tag("phone")
            }
            .pickerStyle(.segmented).labelsHidden()

            if method == "password" {
                passwordFlow
            } else if method == "phone" {
                phoneFlow
            } else if !codeStep {
                Text("Пришлём код из шести цифр на почту — пароль не нужен.")
                    .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                field($email, prompt: "you@company.com")
                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }.buttonStyle(QuietButtonStyle())
                    Button(state.authWorking ? "Sending…" : "Отправить код") {
                        Task { await state.requestSignInCode(email: email) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.authWorking)
                }
            } else {
                Text("Введите код, отправленный на \(state.pendingAuthEmail ?? "").")
                    .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                field($code, prompt: "123456")
                HStack {
                    Button("Назад") { state.cancelSignIn(); code = "" }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button(state.authWorking ? "Verifying…" : "Verify") {
                        Task { await state.verifySignIn(code: code) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.authWorking)
                }
            }
        }
        .padding(Space.xl).frame(width: 420).background(Theme.canvas)
        .onChange(of: state.wheesprConnected) { if $0 { dismiss() } }
    }

    // MARK: Social account login (equal prominence when enabled)

    private var socialButtons: some View {
        VStack(spacing: Space.s) {
            if showsApple {
                Button {
                    Task { await state.signInWithApple() }
                } label: {
                    Label("Войти через Apple", systemImage: "apple.logo")
                        .font(Typo.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.authWorking)
            }

            if showsGoogle {
            Button {
                Task { await state.signInWithGoogleAccount() }
            } label: {
                HStack(spacing: Space.s) {
                    Text("G").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(state.authWorking ? "Начать вход через Google заново" : "Продолжить через Google")
                        .font(Typo.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            // The flow signs in with googleSignInClientID/Secret, so that is the
            // credential the button's enabled state must reflect. Checking the
            // connector client instead could offer a button that cannot run, or
            // grey out one that can.
            //
            // Deliberately NOT disabled while authWorking: an abandoned browser
            // window keeps the flow alive for two minutes, and a greyed-out
            // button during that window was exactly the reported "wanted to
            // sign in with a different account and the button was disabled".
            // A click during a live flow cancels it and starts fresh (the
            // Google picker then offers every Chrome profile again).
            .buttonStyle(QuietButtonStyle(prominent: true))
            .disabled(!state.hasGoogleSignInClient)
            .help(state.authWorking
                  ? "Окно входа уже открыто — нажмите, чтобы начать заново"
                  : "Войти в orakul через Google")
            }

            Text("Вход в аккаунт — не то же самое, что подключение Google Календаря в «Рабочих приложениях».")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Password provider

    private var passwordFlow: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            field($email, prompt: "you@company.com")
            SecureField("", text: $password, prompt: Text("пароль (минимум 8 символов)"))
                .textFieldStyle(.plain).padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            Toggle("Создать аккаунт", isOn: $registering)
                .toggleStyle(.checkbox).font(Typo.caption)
            if let providerError {
                Text(providerError).font(Typo.caption).foregroundStyle(Theme.recordRed)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(working ? "Working…" : (registering ? "Создать аккаунт" : "Войти")) {
                    Task { await runProvider {
                        registering
                            ? try await WheesprAuth.registerPassword(email: email, password: password)
                            : try await WheesprAuth.loginPassword(email: email, password: password)
                    } }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working || email.isEmpty || password.count < 8)
            }
        }
    }

    // MARK: Phone provider (Код из SMS)

    private var phoneFlow: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            field($phone, prompt: "+15551234567")
                .disabled(phoneCodeSent)
            if phoneCodeSent { field($code, prompt: "Код из SMS") }
            if let providerError {
                Text(providerError).font(Typo.caption).foregroundStyle(Theme.recordRed)
            }
            HStack {
                if phoneCodeSent {
                    Button("Назад") { phoneCodeSent = false; code = "" }.buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(working ? "Отправляю…" : (phoneCodeSent ? "Проверить" : "Отправить код по SMS")) {
                    Task {
                        if phoneCodeSent {
                            await runProvider { try await WheesprAuth.verifyPhone(phone: phone, code: code) }
                        } else {
                            working = true; providerError = nil
                            defer { working = false }
                            do { try await WheesprAuth.requestPhoneCode(phone: phone); phoneCodeSent = true }
                            catch { providerError = error.localizedDescription }
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working || phone.isEmpty || (phoneCodeSent && code.isEmpty))
            }
        }
    }

    /// Run a provider sign-in through the shared `applySession` path.
    private func runProvider(_ signIn: @escaping () async throws -> WheesprSession) async {
        working = true
        providerError = nil
        defer { working = false }
        do {
            let session = try await signIn()
            state.applySession(session)
        } catch {
            providerError = error.localizedDescription
        }
    }

    private func field(_ text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.plain).padding(Space.m)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct SettingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            configuration.title
                .font(Typo.callout.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
