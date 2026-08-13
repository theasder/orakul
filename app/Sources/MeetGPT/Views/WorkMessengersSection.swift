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
