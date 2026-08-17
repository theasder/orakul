import SwiftUI
import OrakulCore

/// Настройки → «Подключённые приложения», блок рабочих мессенджеров.
///
/// Отдельно от трекеров, потому что вопрос другой: у трекера спрашивают
/// «заводили ли задачу», у мессенджера — «обсуждали ли это». Ответ на второй
/// чаще лежит в переписке.
///
/// Подключение токеном, как у трекеров: MCP-серверов у этих сервисов нет.
/// Рядом с полем написано, где токен взять, — «нужен токен» без адреса это
/// тупик.
struct WorkMessengersSection: View {
    @State private var expanded: WorkMessengers.Service?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(WorkMessengers.Service.allCases, id: \.self) { service in
                WorkMessengerRow(
                    service: service,
                    isExpanded: expanded == service,
                    toggle: { expanded = expanded == service ? nil : service })
            }
            TelegramSupergroupRow()
        }
    }
}

private struct TelegramSupergroupRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    @State private var token = ""
    @State private var chatIDs = ""
    @State private var isExpanded = false
    @State private var isConfigured = false
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label("Telegram — супергруппы",
                      systemImage: isConfigured ? "checkmark.seal.fill" : "paperplane")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isConfigured {
                    Button("Отключить") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do {
                                try await mcp.disconnectTelegram()
                                token = ""; chatIDs = ""; errorText = nil
                                load()
                            } catch {
                                isExpanded = true
                                errorText = "Не удалось удалить локальный архив Telegram. Подключение и токен оставлены; попробуйте ещё раз."
                            }
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isSaving)
                    .accessibilityIdentifier("settings.messenger.telegram.disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isConfigured ? "Изменить" : "Подключить")) {
                    isExpanded.toggle()
                    errorText = nil
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(isSaving)
                .accessibilityIdentifier("settings.messenger.telegram.connect")
            }

            if isExpanded {
                Text("Создайте отдельного бота через BotFather и добавьте его в выбранные супергруппы. Отключите режим приватности или сделайте бота администратором.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("", text: $token, prompt: Text("токен бота"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Токен Telegram-бота")
                    .accessibilityIdentifier("settings.messenger.telegram.token")

                TextField("", text: $chatIDs,
                          prompt: Text("ID супергрупп через запятую, например -100123…"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Разрешённые ID супергрупп Telegram")
                    .accessibilityIdentifier("settings.messenger.telegram.chatIDs")

                Text("История начинается после подключения: Bot API не отдаёт старые сообщения. Orakul только получает и локально ищет новые сообщения из указанных супергрупп; сам ничего в Telegram не отправляет.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorText {
                    Text(errorText)
                        .font(Typo.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.messenger.telegram.error")
                }

                HStack {
                    Button(isSaving ? "Проверяем…" : "Проверить и сохранить") { save() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("settings.messenger.telegram.save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    private var parsedChatIDs: Set<Int64>? {
        RussianTrackerStore.parseTelegramChatIDs(chatIDs)
    }

    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(parsedChatIDs?.isEmpty ?? true)
    }

    private func load() {
        isConfigured = mcp.trackerStore.isTelegramConfigured
        let saved = mcp.trackerStore.telegramAllowedChatIDs()
        if !saved.isEmpty { chatIDs = saved.sorted().map(String.init).joined(separator: ", ") }
    }

    private func save() {
        guard let parsedChatIDs, !parsedChatIDs.isEmpty else {
            errorText = "Укажите числовые ID супергрупп через запятую."
            return
        }
        isSaving = true
        errorText = nil
        let submittedToken = token
        Task {
            do {
                _ = try await mcp.connectTelegram(
                    token: submittedToken, allowedChatIDs: parsedChatIDs)
                token = ""
                isSaving = false
                load()
            } catch {
                isSaving = false
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось проверить подключение Telegram."
            }
        }
    }
}

private struct WorkMessengerRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    let service: WorkMessengers.Service
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var token = ""
    @State private var secondary = ""
    @State private var scope = ""
    @State private var isConfigured = false

    private var store: RussianTrackerStore { mcp.trackerStore }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(service.title,
                      systemImage: isConfigured
                        ? "checkmark.seal.fill" : "bubble.left.and.bubble.right")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isConfigured {
                    Button("Отключить") { disconnect() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.messenger.\(service.rawValue).disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isConfigured ? "Изменить" : "Подключить")) {
                    toggle()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.messenger.\(service.rawValue).connect")
            }

            if isExpanded {
                Text(service.credentialHint)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("", text: $token, prompt: Text("токен"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Токен \(service.title)")
                    .accessibilityIdentifier("settings.messenger.\(service.rawValue).token")

                if service.needsSecondary {
                    // Адрес сервера: Mattermost и Rocket.Chat команды поднимают
                    // сами, общего хоста у них нет.
                    TextField("", text: $secondary, prompt: Text(service.secondaryPrompt ?? ""))
                        .textFieldStyle(.plain)
                        .font(Typo.callout)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceSunken,
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .accessibilityLabel("\(service.secondaryPrompt ?? "") — \(service.title)")
                        .accessibilityIdentifier("settings.messenger.\(service.rawValue).host")
                }

                if service.needsScope {
                    // Где искать. У Mattermost это команда, у Rocket.Chat —
                    // комната; оба параметра обязательны по документации. Без
                    // них сервис отвечает пустым списком, неотличимым от
                    // «ничего не нашлось».
                    TextField("", text: $scope, prompt: Text(service.scopePrompt ?? ""))
                        .textFieldStyle(.plain)
                        .font(Typo.callout)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceSunken,
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .accessibilityLabel("Где искать — \(service.title)")
                        .accessibilityIdentifier("settings.messenger.\(service.rawValue).scope")
                }

                Text(service.needsScope
                     ? "Поиск идёт только там, где указано."
                     : "Поиск идёт по всем вашим чатам.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Сохранить") { save() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canSave)
                        .accessibilityIdentifier("settings.messenger.\(service.rawValue).save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Неполный набор сохранять нельзя: настройка выглядела бы законченной, а
    /// сервис отвечал бы пустотой — то есть «не обсуждали», хотя обсуждали.
    private var canSave: Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if service.needsSecondary,
           secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if service.needsScope,
           scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    private func load() {
        // Токен обратно в поле не поднимаем: показывать секрет незачем, и
        // Связка ключей за него спросит пароль. Хватает отметки «подключено».
        isConfigured = store.messengerToken(for: service) != nil
        secondary = store.messengerSecondary(for: service) ?? ""
        scope = store.messengerScope(for: service) ?? ""
    }

    private func save() {
        store.setMessengerToken(token, for: service)
        store.setMessengerSecondary(secondary, for: service)
        store.setMessengerScope(scope, for: service)
        token = ""
        load()
    }

    private func disconnect() {
        store.removeMessenger(service)
        token = ""; secondary = ""; scope = ""
        load()
    }
}
