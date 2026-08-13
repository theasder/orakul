import Foundation

/// Спросить подключённый сервис из терминала.
///
/// Коннекторы переехали в ядро вместе со словарём — они знают только
/// Foundation. Раз так, ими может пользоваться не только приложение: вопрос
/// «мы это уже заводили?» одинаково нужен и на звонке, и в терминале, где
/// разработчик и так сидит.
///
/// Токен берётся из окружения и никуда не пишется — как в `LiveConnectorProbe`.
/// HTTP приходит снаружи: тест, который ходит в чужой сервис, проверяет чужой
/// сервис, а не наш код.
public enum ConnectorQuery {

    /// Что можно спросить. Имена те же, что у `ORAKUL_PROBE_SERVICE`.
    ///
    /// Российские трекеры стоят первыми не по алфавиту: с них начинали, и
    /// человек, пришедший за Яндекс Трекером, не должен искать его в конце
    /// списка из тринадцати строк.
    public static let services: [String] =
        RussianTrackers.Service.allCases.map(\.rawValue)
        + ["pachca", "mattermost", "rocketChat", "zulip",
           "matrix", "gitlab", "gitea", "redmine", "outline", "github"]

    public struct Settings {
        public let service: String
        public let token: String
        public let host: String?
        public let scope: String?

        public init(service: String, token: String, host: String?, scope: String?) {
            self.service = service
            self.token = token
            self.host = host
            self.scope = scope
        }
    }

    /// Ответ и признак того, что спросить не удалось.
    ///
    /// Признак нужен ради кода возврата: раньше `спросить` завершался нулём
    /// всегда, и `orakul спросить … && развернуть` продолжал работу после
    /// «нет токена». Текст об ошибке в терминале это не спасает — его читает
    /// человек, а условие проверяет оболочка.
    public struct Answer: Equatable, Sendable {
        public let text: String
        public let failed: Bool

        public init(text: String, failed: Bool) {
            self.text = text
            self.failed = failed
        }
    }

    /// Ответ сервиса словами, готовый к печати.
    ///
    /// Пустая выдача — это ответ, а не сбой: слова могло и не быть. Отказ —
    /// это ошибка коннектора, и она приходит уже по-русски.
    public static func ask(_ settings: Settings,
                           query: String,
                           messengerHTTP: @escaping WorkMessengers.HTTP = WorkMessengers.live,
                           trackerHTTP: @escaping SelfHostedTrackers.HTTP = SelfHostedTrackers.live,
                           notesHTTP: @escaping TeamNotes.HTTP = TeamNotes.live,
                           trackerRUHTTP: @escaping RussianTrackers.HTTP = RussianTrackers.live,
                           githubHTTP: @escaping GitHubConnector.HTTP = RussianTrackers.live) async -> Answer {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .init(text: "Пустой вопрос — спрашивать нечего.", failed: true) }
        guard !settings.token.isEmpty else {
            return .init(text: "Нет токена. Положите его в ORAKUL_TOKEN — он никуда не пишется.",
                         failed: true)
        }

        do {
            if let service = RussianTrackers.Service(rawValue: settings.service) {
                // Второе поле у каждого своё: у Яндекса — организация, у
                // Kaiten — адрес команды. Без него запрос уходит и возвращает
                // 403, из которого не видно, чего не хватало. Поэтому
                // спрашиваем словами самого сервиса, до сети.
                if let prompt = service.secondaryPrompt, (settings.host ?? "").isEmpty {
                    return .init(text: "\(service.title): нужен \(prompt) — положите его в ORAKUL_HOST.",
                                 failed: true)
                }
                let issues = try await RussianTrackers(
                    service: service, token: settings.token, secondary: settings.host,
                    http: trackerRUHTTP).search(trimmed)
                return render(service.title, issues.map { "[\($0.key)] \($0.title)" })
            }
            if settings.service == "github" {
                // Поиск без списка репозиториев уходит по всему GitHub и
                // возвращает чужие задачи — это не «шире», а мусор.
                let repositories = (settings.scope ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !repositories.isEmpty else {
                    return .init(text: "GitHub: нужны \(GitHubConnector.repositoriesPrompt) — в ORAKUL_SCOPE.",
                                 failed: true)
                }
                let items = try await GitHubConnector(
                    token: settings.token, repositories: repositories,
                    http: githubHTTP).search(trimmed)
                return render("GitHub", items.map { "\(IssueLabel.render(key: $0.key, state: $0.state)) \($0.title)" })
            }
            if let service = WorkMessengers.Service(rawValue: settings.service) {
                let hits = try await WorkMessengers(
                    service: service, token: settings.token,
                    secondary: settings.host, scope: settings.scope,
                    http: messengerHTTP).search(trimmed)
                return render(service.title, hits.map { $0.text })
            }
            if let service = SelfHostedTrackers.Service(rawValue: settings.service) {
                let items = try await SelfHostedTrackers(
                    service: service, token: settings.token, host: settings.host,
                    http: trackerHTTP).search(trimmed)
                return render(service.title, items.map { "\(IssueLabel.render(key: $0.key, state: $0.state)) \($0.title)" })
            }
            if let service = TeamNotes.Service(rawValue: settings.service) {
                let hits = try await TeamNotes(
                    service: service, token: settings.token, host: settings.host,
                    http: notesHTTP).search(trimmed)
                return render(service.title, hits.map { "\($0.title): \($0.context)" })
            }
        } catch {
            return .init(text: explain(error), failed: true)
        }
        return .init(text: "Не знаю сервис «\(settings.service)». Есть: \(services.joined(separator: ", ")).",
                     failed: true)
    }

    /// Отказ словами.
    ///
    /// Ошибки самих коннекторов уже по-русски. А до коннектора дело может и не
    /// дойти: сеть отвечает через Foundation, и её `localizedDescription` —
    /// это «Could not connect to the server.» на языке системы. В продукте,
    /// который обещает русский интерфейс, английская строка про сервер — это
    /// не мелочь: именно её увидит человек, у которого опечатка в адресе.
    private static func explain(_ error: Error) -> String {
        guard let url = error as? URLError else { return error.localizedDescription }
        let host = url.failingURL?.host.map { " (\($0))" } ?? ""
        switch url.code {
        case .notConnectedToInternet:
            return "Нет сети. Проверьте подключение."
        case .timedOut:
            return "Сервис\(host) не ответил вовремя. Попробуйте ещё раз."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Не достучались до сервиса\(host). Проверьте адрес в ORAKUL_HOST."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "Сервис\(host) отвечает по недоверенному сертификату."
        default:
            return "Не получилось спросить сервис\(host): \(url.localizedDescription)"
        }
    }

    private static func render(_ service: String, _ lines: [String]) -> Answer {
        guard !lines.isEmpty else {
            // Пустая выдача — ответ, а не сбой: слова могло и не быть сказано.
            return .init(text: "\(service): по этим словам ничего не нашлось.", failed: false)
        }
        return .init(text: ([service + ":"] + lines.prefix(10).map { "    " + $0 })
                        .joined(separator: "\n"),
                     failed: false)
    }
}
