import Foundation

/// Открытые трекеры задач, которые команда поднимает у себя.
///
/// Отдельно от `GitHubConnector`: тот ходит только на `api.github.com`, адрес у
/// него зашит. Самостоятельно поднятый GitLab или Gitea живёт на своём домене,
/// и без поля «адрес сервера» подключить его некуда.
///
/// Отдельно от `RussianTrackers`: у тех облако вендора, здесь — сервер команды.
/// Разница видна и пользователю (появляется поле адреса), и в коде (общего
/// хоста нет), так что один общий тип только запутал бы.
///
/// Адреса сверены с документацией 2026-08-12:
///
///   * **GitLab** — `GET /api/v4/search?scope=issues&search=…`, заголовок
///     `PRIVATE-TOKEN`. Ищет по всему, что видит токен; сузить до проекта можно
///     через `/projects/{id}/search`, но на вопрос «мы это уже заводили?» шире
///     полезнее.
///   * **Gitea / Forgejo** — `GET /api/v1/repos/issues/search?q=…`, заголовок
///     `Authorization: token …` — именно слово `token`, а не `Bearer`: так в
///     их `swagger.v1.json`. Forgejo — форк Gitea с тем же API, поэтому
///     отдельной строкой не идёт.
///   * **Redmine** — `GET /search.json?q=…&issues=1`, заголовок
///     `X-Redmine-API-Key`. Единственный из трёх, кто оборачивает выдачу в
///     объект (`{"results": […]}`), а не отдаёт массив; и единственный, кто без
///     `issues=1` ищет заодно по вики, форуму и новостям.
///
/// HTTP приходит снаружи: тест, который ходит в чужой трекер, проверяет чужой
/// трекер, а не наш код.
public struct SelfHostedTrackers {

    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public enum Service: String, CaseIterable, Sendable {
        case gitlab, gitea, redmine

        public var title: String {
            switch self {
            case .gitlab: return "GitLab"
            case .gitea:  return "Gitea / Forgejo"
            case .redmine: return "Redmine"
            }
        }

        public var credentialHint: String {
            switch self {
            case .gitlab:
                return "Токен доступа с правом read_api и адрес вашего GitLab"
            case .gitea:
                return "Токен из настроек профиля и адрес вашего Gitea или Forgejo"
            case .redmine:
                return "Ключ API со страницы «Моя учётная запись» и адрес вашего Redmine"
            }
        }

        public var hostPrompt: String {
            switch self {
            case .gitlab: return "адрес сервера, например gitlab.company.ru"
            case .gitea:  return "адрес сервера, например git.company.ru"
            case .redmine: return "адрес сервера, например redmine.company.ru"
            }
        }

        func host(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value.hasPrefix("http") ? value : "https://\(value)"
        }
    }

    public enum ConnectorError: Error, Equatable, LocalizedError {
        case notConfigured
        case unauthorised
        /// Сервер ответил, но ошибкой. Отдельно от `unreadable`:
        /// 502 от обратного прокси — это живой сервер и внятный
        /// ответ, а прежний текст советовал проверить ВЕРСИЮ, то
        /// есть отправлял человека не туда.
        case http(Int)
        case unreadable

        /// По-русски и с действием.
        ///
        /// Без `LocalizedError` Swift печатает «The operation couldn’t be
        /// completed. (MeetGPT.SelfHostedTrackers.ConnectorError error 1.)» — по-английски, с внутренним
        /// путём типа и номером случая. В приложении, где всё остальное
        /// по-русски, это видно ровно тогда, когда человеку нужна помощь.
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Трекер не подключён. Откройте «Настройки → Подключённые приложения» и вставьте токен."
            case .unauthorised:
                return "Трекер не принял токен. Обычно он истёк или у него не тех прав — создайте новый в самом сервисе."
            case .http(let status):
                return "Трекер ответил ошибкой \(status). Сервер на месте — проверьте адрес и права токена, а если это 5xx, то сам сервер или прокси перед ним."
            case .unreadable:
                return "Трекер ответил непонятным образом. Если у вас свой сервер, проверьте адрес и версию."
            }
        }

    }

    public struct Item: Equatable, Sendable {
        public let key: String
        public let title: String
        public let state: String
        public let service: Service
    }

    let service: Service
    let token: String
    let hostValue: String?
    let http: HTTP

    public init(service: Service, token: String, host: String?, http: @escaping HTTP) {
        self.service = service
        self.token = token
        self.hostValue = host
        self.http = http
    }

    public var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && service.host(hostValue) != nil
    }

    public func search(_ query: String) async throws -> [Item] {
        guard isConfigured, let host = service.host(hostValue) else {
            throw ConnectorError.notConfigured
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request: URLRequest
        switch service {
        case .gitlab:
            var components = URLComponents(string: "\(host)/api/v4/search")
            components?.queryItems = [
                URLQueryItem(name: "scope", value: "issues"),
                URLQueryItem(name: "search", value: trimmed),
                URLQueryItem(name: "per_page", value: "10"),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")

        case .redmine:
            var components = URLComponents(string: "\(host)/search.json")
            components?.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                // Только задачи: Redmine по умолчанию ищет ещё по вики, форуму
                // и новостям, и подсказка тонет в чужом.
                URLQueryItem(name: "issues", value: "1"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-Redmine-API-Key")

        case .gitea:
            var components = URLComponents(string: "\(host)/api/v1/repos/issues/search")
            components?.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                // Без этого в выдачу попадают и пулл-реквесты: на вопрос «мы
                // это уже заводили?» они отвечают о другом.
                URLQueryItem(name: "type", value: "issues"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            request = URLRequest(url: url)
            // Именно «token», а не «Bearer»: так в их спецификации.
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 8

        let (data, response) = try await http(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ConnectorError.unauthorised
        }
        // Всё прочее, кроме успеха, — ошибка сервера, а не мусор в
        // ответе. Раньше сюда проваливались 404, 500 и 502, и разбор
        // JSON объявлял их «непонятным ответом».
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.http(response.statusCode)
        }
        // GitLab и Gitea отдают массив верхним уровнем, Redmine — объект с
        // `results`. В обоих случаях неожиданная форма это тело ошибки, и
        // выдать его за пустую выдачу значит сказать «не заводили» там, где мы
        // просто не смогли спросить.
        let rows: [[String: Any]]
        if service == .redmine {
            // Redmine оборачивает выдачу: `{ "results": [...], "total_count": N }`.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            rows = results
        } else {
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            rows = array
        }
        return rows.compactMap { row in
            guard let title = row["title"] as? String, !title.isEmpty else { return nil }
            // GitLab зовёт номер `iid`, Gitea — `number`, Redmine — `id`.
            let number = (row["iid"] as? Int) ?? (row["number"] as? Int)
                ?? (service == .redmine ? row["id"] as? Int : nil)
            let key = number.map { "#\($0)" } ?? "—"
            // Пусто, а не «unknown»: поиск Redmine состояния не отдаёт вовсе, и
            // строка `[#314, unknown]` сообщает человеку, что что-то неизвестно
            // ЕМУ. Неизвестно оно не ему — его просто не спрашивали.
            let state = (row["state"] as? String) ?? ""
            return Item(key: key, title: title, state: state, service: service)
        }
    }
}
