import Foundation

/// GitHub: задачи и пулл-реквесты команды как источник для ответа на звонке.
///
/// **Почему не через MCP.** У GitHub есть свой MCP-сервер
/// (`https://api.githubcopilot.com/mcp/`), и он отвечает по спецификации: 401 с
/// `WWW-Authenticate` и адресом метаданных. Но его сервер авторизации
/// (`https://github.com/login/oauth`) в метаданных **не объявляет
/// `registration_endpoint`** — проверено 2026-08-12. Динамической регистрации
/// клиента нет, а весь MCP-каталог в этом приложении построен именно на ней:
/// «подключить в одно нажатие, ничего не заводя заранее».
///
/// Второй путь — заранее зарегистрированное приложение с зашитым секретом (как
/// у HubSpot). Он тоже не работает: в готовые установщики секреты не попадают
/// намеренно, значит в скачанном orakul такой строки просто не будет.
///
/// Остаётся то, что GitHub поддерживает сам и что совпадает с устройством
/// остального продукта: личный токен, который человек вставляет руками. Тот же
/// путь, что у ключей провайдеров и у российских трекеров.
///
/// HTTP приходит снаружи: тест, который ходит в GitHub, проверяет GitHub.
public struct GitHubConnector: Sendable {

    public typealias HTTP = RussianTrackers.HTTP

    static let live: HTTP = RussianTrackers.live

    public enum ConnectorError: Error, Equatable, LocalizedError {
        case notConfigured
        case unauthorised
        case http(Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "GitHub не подключён. Вставьте личный токен в «Настройки → Подключённые приложения» и укажите репозитории."
            case .unauthorised:
                return "GitHub не принял токен: истёк или без права read на нужные репозитории."
            case .http(let status):
                return "GitHub ответил ошибкой \(status). При 404 обычно неверно указан репозиторий."
            case .unreadable:
                return "GitHub вернул ответ, который не удалось разобрать."
            }
        }

    }

    public struct Item: Equatable, Sendable {
        /// `owner/repo#123` — по нему задачу видно, не открывая ссылку.
        public let key: String
        public let title: String
        public let url: URL?
        /// `open` / `closed`. Отдельно от заголовка: «уже закрыто» меняет смысл
        /// находки на противоположный.
        public let state: String
    }

    let token: String
    /// Репозитории через запятую: `owner/name`. Без них поиск идёт по всему
    /// GitHub, и в подсказку попадают чужие задачи — шум, который выглядит как
    /// контекст команды.
    let repositories: [String]
    let http: HTTP

    public init(token: String, repositories: [String], http: @escaping HTTP) {
        self.token = token
        self.repositories = repositories
        self.http = http
    }

    /// Где взять токен. Без адреса подсказка бесполезна.
    public static let credentialHint =
        "github.com → Settings → Developer settings → Personal access tokens; нужен доступ на чтение репозитория"

    public static let repositoriesPrompt = "репозитории через запятую, например myteam/backend"

    // MARK: - Поиск

    public func search(_ query: String, limit: Int = 10) async throws -> [Item] {
        guard !token.isEmpty, !repositories.isEmpty else { throw ConnectorError.notConfigured }

        var request = URLRequest(url: try endpoint(for: query, limit: limit))
        request.timeoutInterval = 8   // тот же бюджет, что у остальных источников
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Версия API фиксируется явно: без неё GitHub вправе поменять формат
        // ответа под нами.
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await http(request)
        switch response.statusCode {
        case 200...299: break
        case 401, 403:  throw ConnectorError.unauthorised
        default:        throw ConnectorError.http(response.statusCode)
        }
        return try parse(data)
    }

    func endpoint(for query: String, limit: Int) throws -> URL {
        // Тип обязателен. Без `is:issue` или `is:pull-request` GitHub отвечает
        // 422 для части токенов — это описано в документации и повторяется на
        // живом API. Ошибка при этом ничего не объясняет пользователю.
        let scope = repositories.map { "repo:\($0)" }.joined(separator: " ")
        let full = "\(scope) is:issue \(query)"
        let escaped = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string:
            "https://api.github.com/search/issues?q=\(escaped)&per_page=\(limit)") else {
            throw ConnectorError.unreadable
        }
        return url
    }

    /// Разбор мягкий: одна кривая запись не должна стоить всей выдачи.
    func parse(_ data: Data) throws -> [Item] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unreadable
        }
        guard let rows = root["items"] as? [[String: Any]] else {
            // `message` без `items` — это ошибка, а не пустая выдача. Вернуть
            // пустой список значило бы сказать «задач нет», когда правда —
            // «запрос не выполнен».
            if root["message"] != nil { throw ConnectorError.unreadable }
            return []
        }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int else { return nil }
            let link = (row["html_url"] as? String).flatMap(URL.init(string:))
            // `owner/repo` вытаскивается из ссылки: в ответе поиска его нет
            // отдельным полем, а без него номер задачи ни о чём не говорит,
            // когда репозиториев несколько.
            let repo = link.map { url -> String in
                let parts = url.pathComponents.filter { $0 != "/" }
                return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : ""
            } ?? ""
            let key = repo.isEmpty ? "#\(number)" : "\(repo)#\(number)"
            return Item(key: key,
                        title: (row["title"] as? String) ?? "Без названия",
                        url: link,
                        state: (row["state"] as? String) ?? "open")
        }
    }
}
