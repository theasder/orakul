import Foundation
import OrakulCore

/// Токены российских трекеров: чтение, запись, удаление.
///
/// Хранилище — Связка ключей, как у остальных секретов приложения. В
/// UserDefaults токен лежал бы открытым файлом на диске.
///
/// Отдельно от `MCPKeychainTokenStorage`: там OAuth-токен со сроком жизни и
/// обновлением, здесь — строка, которую человек скопировал руками и которая не
/// протухает сама. Общий тип для двух этих вещей означал бы поля «истекает» и
/// «обновить», всегда пустые для половины случаев.
struct RussianTrackerStore: Sendable {

    private let store: KeychainStore

    init(store: KeychainStore = SystemKeychain.shared) {
        self.store = store
    }

    private func account(_ service: RussianTrackers.Service) -> String {
        "tracker.\(service.rawValue)"
    }

    private func secondaryAccount(_ service: RussianTrackers.Service) -> String {
        "tracker.\(service.rawValue).secondary"
    }

    private func destinationAccount(_ service: RussianTrackers.Service) -> String {
        "tracker.\(service.rawValue).destination"
    }

    // MARK: - Токен

    func token(for service: RussianTrackers.Service) -> String? {
        guard let data = store.get(account(service)),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    /// Пустая строка — это «убрать», а не «сохранить пустоту»: иначе поле,
    /// очищенное руками, оставляет в Связке ключей мёртвую запись, и
    /// подключение выглядит настроенным, пока не сходит в сеть.
    func setToken(_ token: String, for service: RussianTrackers.Service) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(service) }
        store.set(Data(trimmed.utf8), for: account(service))
    }

    // MARK: - Второе поле (организация у Яндекса, адрес команды у Kaiten)

    func secondary(for service: RussianTrackers.Service) -> String? {
        guard service.needsSecondary,
              let data = store.get(secondaryAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setSecondary(_ value: String, for service: RussianTrackers.Service) {
        guard service.needsSecondary else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return store.delete(secondaryAccount(service))
        }
        store.set(Data(trimmed.utf8), for: secondaryAccount(service))
    }

    // MARK: - Куда заводить задачу

    /// Очередь, доска или колонка. Пусто — значит трекер подключён только на
    /// чтение, и кнопка «Завести задачу» для него не предлагается.
    func destination(for service: RussianTrackers.Service) -> String? {
        guard let data = store.get(destinationAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setDestination(_ value: String, for service: RussianTrackers.Service) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.delete(destinationAccount(service)) }
        store.set(Data(trimmed.utf8), for: destinationAccount(service))
    }

    /// Может ли сервис принять задачу. Отдельно от `isConfigured`: читать можно
    /// и без места назначения, а писать — нет.
    func canFileTasks(_ service: RussianTrackers.Service) -> Bool {
        isConfigured(service) && destination(for: service) != nil
    }

    /// Сервисы, готовые принять задачу.
    var writable: [RussianTrackers.Service] {
        RussianTrackers.Service.allCases.filter(canFileTasks)
    }

    // MARK: - Состояние

    /// Готов ли сервис к запросу. Яндекс Трекер без X-Org-ID отвечает 403, а у
    /// Kaiten без адреса команды нет самого хоста — «токен есть» для них ещё
    /// не значит «подключено».
    func isConfigured(_ service: RussianTrackers.Service) -> Bool {
        guard token(for: service) != nil else { return false }
        return service.needsSecondary ? secondary(for: service) != nil : true
    }

    func remove(_ service: RussianTrackers.Service) {
        store.delete(account(service))
        store.delete(secondaryAccount(service))
        store.delete(destinationAccount(service))
    }

    /// Клиент для сервиса — или nil, если он ещё не настроен. Возвращать
    /// клиент с пустым токеном значило бы отдать ошибку из сети вместо
    /// понятного «не подключено».
    func client(for service: RussianTrackers.Service,
                http: @escaping RussianTrackers.HTTP) -> RussianTrackers? {
        guard let token = token(for: service), isConfigured(service) else { return nil }
        return RussianTrackers(service: service, token: token,
                               secondary: secondary(for: service),
                               destination: destination(for: service), http: http)
    }

    /// Сервисы, готовые отвечать на запрос. Это и есть список, который видит
    /// подбор источников: трекер без токена не должен занимать место среди
    /// источников и тратить бюджет ожидания.
    var configured: [RussianTrackers.Service] {
        RussianTrackers.Service.allCases.filter(isConfigured)
    }

    // MARK: - GitHub

    private var githubTokenAccount: String { "github.token" }
    private var githubReposAccount: String { "github.repos" }

    func githubToken() -> String? {
        guard let data = store.get(githubTokenAccount),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func setGitHubToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.delete(githubTokenAccount) }
        store.set(Data(trimmed.utf8), for: githubTokenAccount)
    }

    /// Репозитории как список. Пробелы и пустые куски выбрасываются: строку
    /// вставляют руками, и «myteam/backend, » — обычный случай.
    func githubRepositories() -> [String] {
        guard let data = store.get(githubReposAccount),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func setGitHubRepositories(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.delete(githubReposAccount) }
        store.set(Data(trimmed.utf8), for: githubReposAccount)
    }

    /// Готов ли GitHub отвечать: токена мало без репозиториев — поиск ушёл бы
    /// по всему GitHub и принёс чужие задачи.
    var isGitHubReady: Bool {
        githubToken() != nil && !githubRepositories().isEmpty
    }

    func removeGitHub() {
        store.delete(githubTokenAccount)
        store.delete(githubReposAccount)
    }

    // MARK: - База знаний (Outline)

    private func notesAccount(_ service: TeamNotes.Service) -> String {
        "notes.\(service.rawValue)"
    }

    private func notesHostAccount(_ service: TeamNotes.Service) -> String {
        "notes.\(service.rawValue).host"
    }

    func notesToken(for service: TeamNotes.Service) -> String? {
        guard let data = store.get(notesAccount(service)),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    func setNotesToken(_ token: String, for service: TeamNotes.Service) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeNotes(service) }
        store.set(Data(trimmed.utf8), for: notesAccount(service))
    }

    func notesHost(for service: TeamNotes.Service) -> String? {
        guard let data = store.get(notesHostAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setNotesHost(_ value: String, for service: TeamNotes.Service) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.delete(notesHostAccount(service)) }
        store.set(Data(trimmed.utf8), for: notesHostAccount(service))
    }

    func removeNotes(_ service: TeamNotes.Service) {
        store.delete(notesAccount(service))
        store.delete(notesHostAccount(service))
    }

    var configuredNotes: [TeamNotes.Service] {
        TeamNotes.Service.allCases.filter {
            notesClient(for: $0, http: { _ in (Data(), HTTPURLResponse()) }) != nil
        }
    }

    func notesClient(for service: TeamNotes.Service,
                     http: @escaping TeamNotes.HTTP) -> TeamNotes? {
        guard let token = notesToken(for: service) else { return nil }
        let client = TeamNotes(service: service, token: token,
                               host: notesHost(for: service), http: http)
        return client.isConfigured ? client : nil
    }

    // MARK: - Открытые трекеры на своём сервере (GitLab, Gitea/Forgejo)

    private func selfHostedAccount(_ service: SelfHostedTrackers.Service) -> String {
        "selfhosted.\(service.rawValue)"
    }

    private func selfHostedHostAccount(_ service: SelfHostedTrackers.Service) -> String {
        "selfhosted.\(service.rawValue).host"
    }

    func selfHostedToken(for service: SelfHostedTrackers.Service) -> String? {
        guard let data = store.get(selfHostedAccount(service)),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    func setSelfHostedToken(_ token: String, for service: SelfHostedTrackers.Service) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeSelfHosted(service) }
        store.set(Data(trimmed.utf8), for: selfHostedAccount(service))
    }

    func selfHostedHost(for service: SelfHostedTrackers.Service) -> String? {
        guard let data = store.get(selfHostedHostAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setSelfHostedHost(_ value: String, for service: SelfHostedTrackers.Service) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.delete(selfHostedHostAccount(service)) }
        store.set(Data(trimmed.utf8), for: selfHostedHostAccount(service))
    }

    func removeSelfHosted(_ service: SelfHostedTrackers.Service) {
        store.delete(selfHostedAccount(service))
        store.delete(selfHostedHostAccount(service))
    }

    var configuredSelfHosted: [SelfHostedTrackers.Service] {
        SelfHostedTrackers.Service.allCases.filter {
            selfHostedClient(for: $0, http: { _ in (Data(), HTTPURLResponse()) }) != nil
        }
    }

    func selfHostedClient(for service: SelfHostedTrackers.Service,
                          http: @escaping SelfHostedTrackers.HTTP) -> SelfHostedTrackers? {
        guard let token = selfHostedToken(for: service) else { return nil }
        let client = SelfHostedTrackers(service: service, token: token,
                                        host: selfHostedHost(for: service), http: http)
        return client.isConfigured ? client : nil
    }

    // MARK: - Рабочие мессенджеры (Пачка, Mattermost, Rocket.Chat)
    //
    // Ключи отдельные от трекеров: сервис может быть подключён и там и там, и
    // общий ключ затёр бы один токен другим.

    private func messengerAccount(_ service: WorkMessengers.Service) -> String {
        "messenger.\(service.rawValue)"
    }

    private func messengerSecondaryAccount(_ service: WorkMessengers.Service) -> String {
        "messenger.\(service.rawValue).secondary"
    }

    private func messengerScopeAccount(_ service: WorkMessengers.Service) -> String {
        "messenger.\(service.rawValue).scope"
    }

    func messengerToken(for service: WorkMessengers.Service) -> String? {
        guard let data = store.get(messengerAccount(service)),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    /// Пустая строка убирает запись, а не сохраняет пустоту — как и у трекеров:
    /// иначе очищенное поле оставляет мёртвую запись, и подключение выглядит
    /// настроенным, пока не сходит в сеть.
    func setMessengerToken(_ token: String, for service: WorkMessengers.Service) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeMessenger(service) }
        store.set(Data(trimmed.utf8), for: messengerAccount(service))
    }

    func messengerSecondary(for service: WorkMessengers.Service) -> String? {
        guard service.needsSecondary,
              let data = store.get(messengerSecondaryAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setMessengerSecondary(_ value: String, for service: WorkMessengers.Service) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return store.delete(messengerSecondaryAccount(service))
        }
        store.set(Data(trimmed.utf8), for: messengerSecondaryAccount(service))
    }

    func messengerScope(for service: WorkMessengers.Service) -> String? {
        guard service.needsScope,
              let data = store.get(messengerScopeAccount(service)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func setMessengerScope(_ value: String, for service: WorkMessengers.Service) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return store.delete(messengerScopeAccount(service))
        }
        store.set(Data(trimmed.utf8), for: messengerScopeAccount(service))
    }

    func removeMessenger(_ service: WorkMessengers.Service) {
        store.delete(messengerAccount(service))
        store.delete(messengerSecondaryAccount(service))
        store.delete(messengerScopeAccount(service))
    }

    /// Мессенджеры, готовые к запросу. Готов — значит есть всё, что сервис
    /// требует: токен, адрес сервера и место поиска, если они нужны.
    var configuredMessengers: [WorkMessengers.Service] {
        WorkMessengers.Service.allCases.filter { messengerClient(for: $0, http: { _ in
            (Data(), HTTPURLResponse())
        }) != nil }
    }

    func messengerClient(for service: WorkMessengers.Service,
                         http: @escaping WorkMessengers.HTTP) -> WorkMessengers? {
        guard let token = messengerToken(for: service) else { return nil }
        let client = WorkMessengers(service: service, token: token,
                                    secondary: messengerSecondary(for: service),
                                    scope: messengerScope(for: service), http: http)
        return client.isConfigured ? client : nil
    }

    // MARK: - Telegram supergroups
    // Telegram differs from the search APIs above: Bot API delivers only new
    // updates, so the app archives and searches them locally. Credentials still
    // belong beside the other messenger credentials in Keychain.

    private var telegramTokenAccount: String { "messenger.telegram.token" }
    private var telegramChatIDsAccount: String { "messenger.telegram.chatIDs" }
    private var telegramBotIDAccount: String { "messenger.telegram.botID" }

    func telegramToken() -> String? {
        guard let data = store.get(telegramTokenAccount),
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    func telegramAllowedChatIDs() -> Set<Int64> {
        guard let data = store.get(telegramChatIDsAccount),
              let value = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseTelegramChatIDs(value) ?? []
    }

    func telegramBotID() -> Int64? {
        guard let data = store.get(telegramBotIDAccount),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return Int64(value)
    }

    static func parseTelegramChatIDs(_ value: String) -> Set<Int64>? {
        let parts = value.split { character in
            character == "," || character == ";" || character.isWhitespace
        }
        guard !parts.isEmpty else { return nil }
        let ids = parts.compactMap { Int64($0) }
        guard ids.count == parts.count else { return nil }
        return Set(ids)
    }

    func setTelegram(token: String, allowedChatIDs: Set<Int64>, botID: Int64) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !allowedChatIDs.isEmpty else {
            return removeTelegram()
        }
        store.set(Data(trimmed.utf8), for: telegramTokenAccount)
        let ids = allowedChatIDs.sorted().map(String.init).joined(separator: ",")
        store.set(Data(ids.utf8), for: telegramChatIDsAccount)
        store.set(Data(String(botID).utf8), for: telegramBotIDAccount)
    }

    var isTelegramConfigured: Bool {
        telegramToken() != nil && !telegramAllowedChatIDs().isEmpty && telegramBotID() != nil
    }

    func removeTelegram() {
        store.delete(telegramTokenAccount)
        store.delete(telegramChatIDsAccount)
        store.delete(telegramBotIDAccount)
    }

    func githubClient(http: @escaping GitHubConnector.HTTP) -> GitHubConnector? {
        guard let token = githubToken(), !githubRepositories().isEmpty else { return nil }
        return GitHubConnector(token: token, repositories: githubRepositories(), http: http)
    }

    /// Найденные задачи одной строкой — в том же виде, в каком в подсказку
    /// попадают остальные коннекторы.
    ///
    /// Ошибка сети или чужой токен дают nil, а не текст об ошибке: подсказка
    /// собирается из нескольких источников, и «Kaiten ответил 401» в ней
    /// вытеснит то, ради чего её собирали. Сломанное подключение видно в
    /// настройках, а не посреди ответа про звонок.
    func searchText(_ service: RussianTrackers.Service, query: String, cap: Int = 3000,
                    http: @escaping RussianTrackers.HTTP = RussianTrackers.live) async -> String? {
        guard let client = client(for: service, http: http) else { return nil }
        guard let issues = try? await client.search(query), !issues.isEmpty else { return nil }
        return issues.prefix(10)
            .map { "[\($0.key)] \($0.title)" }
            .joined(separator: "\n")
            .prefix(cap).description
    }
}
