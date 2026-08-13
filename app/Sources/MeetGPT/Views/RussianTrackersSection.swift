import SwiftUI
import OrakulCore

/// Настройки → «Подключённые приложения», первый блок: российские трекеры.
///
/// Наверху, потому что это первое, что человек здесь ищет. Список,
/// начинающийся с Notion и Linear, читается как «нашего трекера тут нет», и
/// дальше третьей строки его не листают.
///
/// Подключение не через OAuth: MCP-серверов у этих сервисов нет, поэтому здесь
/// токен, который человек создаёт у себя в трекере. Рядом с полем написано,
/// где именно, — «нужен токен» без адреса это тупик.
struct RussianTrackersSection: View {
    @State private var expanded: RussianTrackers.Service?
    @State private var githubExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(RussianTrackers.Service.allCases, id: \.self) { service in
                RussianTrackerRow(
                    service: service,
                    isExpanded: expanded == service,
                    toggle: { expanded = expanded == service ? nil : service })
            }
            // GitHub стоит здесь же: для разработчика это тот же вопрос —
            // «где лежат задачи». Подключается так же, токеном.
            GitHubRow(isExpanded: githubExpanded,
                      toggle: { githubExpanded.toggle() })
        }
    }
}

/// GitHub подключается личным токеном: динамической регистрации клиента у него
/// нет, а секреты в установщик не кладут — см. `GitHubConnector`.
private struct GitHubRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var token = ""
    @State private var repositories = ""
    @State private var isReady = false

    private var store: RussianTrackerStore { mcp.trackerStore }

    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repositories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label("GitHub", systemImage: isReady ? "checkmark.seal.fill" : "chevron.left.forwardslash.chevron.right")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isReady {
                    Button("Отключить") {
                        store.removeGitHub()
                        token = ""; repositories = ""
                        load()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("settings.github.disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isReady ? "Изменить" : "Подключить")) { toggle() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("settings.github.connect")
            }

            if isExpanded {
                Text(GitHubConnector.credentialHint)
                    .font(Typo.caption).foregroundStyle(Theme.inkTertiary)

                SecureField("", text: $token, prompt: Text("токен"))
                    .textFieldStyle(.plain).font(Typo.callout)
                    .padding(.horizontal, Space.s).padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Токен GitHub")
                    .accessibilityIdentifier("settings.github.token")

                // Без репозиториев поиск ушёл бы по всему GitHub и принёс чужие
                // задачи — шум, неотличимый от контекста команды.
                TextField("", text: $repositories,
                          prompt: Text(GitHubConnector.repositoriesPrompt))
                    .textFieldStyle(.plain).font(Typo.callout)
                    .padding(.horizontal, Space.s).padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Репозитории GitHub")
                    .accessibilityIdentifier("settings.github.repos")

                HStack {
                    Button("Сохранить") {
                        store.setGitHubToken(token)
                        store.setGitHubRepositories(repositories)
                        token = ""
                        load()
                        toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!canSave)
                    .accessibilityIdentifier("settings.github.save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        isReady = store.isGitHubReady
        repositories = store.githubRepositories().joined(separator: ", ")
    }
}

private struct RussianTrackerRow: View {
    /// Хранилище берётся у менеджера подключений, а не создаётся здесь: у него
    /// оно построено на том же `KeychainStore`, что и остальные токены, и в
    /// тестах это фальшивая Связка ключей — иначе проверка настроек лезла бы
    /// в настоящие токены пользователя.
    @EnvironmentObject private var mcp: MCPConnectionManager
    let service: RussianTrackers.Service
    let isExpanded: Bool
    let toggle: () -> Void

    private var store: RussianTrackerStore { mcp.trackerStore }
    @State private var token = ""
    @State private var secondary = ""
    @State private var destination = ""
    @State private var isConfigured = false
    @State private var canFileTasks = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(service.title,
                      systemImage: canFileTasks ? "checkmark.seal.fill"
                                 : (isConfigured ? "arrow.down.circle" : "tray.full"))
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isConfigured {
                    Button("Отключить") { disconnect() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.tracker.\(service.rawValue).disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isConfigured ? "Изменить" : "Подключить")) {
                    toggle()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.tracker.\(service.rawValue).connect")
            }

            if isExpanded {
                Text(service.credentialHint)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)

                SecureField("", text: $token, prompt: Text("токен"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Токен \(service.title)")
                    .accessibilityIdentifier("settings.tracker.\(service.rawValue).token")

                if service.needsSecondary {
                    // У Яндекса без X-Org-ID это 403, у Kaiten без адреса команды
                    // нет самого хоста. Не украшение, а вторая половина ключа.
                    TextField("", text: $secondary, prompt: Text(service.secondaryPrompt ?? ""))
                        .textFieldStyle(.plain)
                        .font(Typo.callout)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceSunken,
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .accessibilityLabel("\(service.secondaryPrompt ?? "") — \(service.title)")
                        .accessibilityIdentifier("settings.tracker.\(service.rawValue).org")
                }

                // Третье поле — куда класть заведённую задачу. Пустое поле
                // это не ошибка: трекер можно подключить только на чтение, и
                // тогда кнопка «Завести задачу» для него просто не появится.
                TextField("", text: $destination,
                          prompt: Text(service.destinationPrompt ?? ""))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Куда заводить задачи — \(service.title)")
                    .accessibilityIdentifier("settings.tracker.\(service.rawValue).destination")

                Text(destination.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Без этого поля трекер подключится только на чтение."
                     : "Задачи со звонка будут заводиться сюда.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)

                HStack {
                    Button("Сохранить") { save() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canSave)
                        .accessibilityIdentifier("settings.tracker.\(service.rawValue).save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Сохранять половину ключа нельзя: настройка будет выглядеть законченной и
    /// падать с 403 при первом же запросе.
    private var canSave: Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard service.needsSecondary else { return true }
        return !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        // Сам токен обратно в поле не поднимаем: показывать секрет незачем,
        // и Связка ключей за него спросит пароль. Хватает отметки «подключено».
        isConfigured = store.isConfigured(service)
        canFileTasks = store.canFileTasks(service)
        secondary = store.secondary(for: service) ?? ""
        destination = store.destination(for: service) ?? ""
    }

    private func save() {
        store.setToken(token, for: service)
        store.setSecondary(secondary, for: service)
        store.setDestination(destination, for: service)
        token = ""
        load()
    }

    private func disconnect() {
        store.remove(service)
        token = ""
        secondary = ""
        destination = ""
        load()
    }
}
