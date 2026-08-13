import Foundation

/// Поиск по рабочим мессенджерам — российским и открытым.
///
/// Зачем отдельно от `RussianTrackers`: у трекера ищут задачу, у мессенджера —
/// сказанное. На звонке это разные вопросы («мы это уже заводили?» и «мы это
/// уже обсуждали?»), и ответ на второй чаще лежит в переписке.
///
/// **Почему эти три.** Каждый адрес взят из документации вендора и сверен с её
/// исходником 2026-08-12, а не угадан:
///
///   * **Пачка** — российская. `GET /search/messages` с параметром `query`,
///     полнотекстовый поиск сразу по всем чатам. Проверено по `openapi.yaml`.
///   * **Mattermost** — открытый, у многих российских команд стоит на своём
///     сервере. `POST /api/v4/teams/{team_id}/posts/search`, тело
///     `{"terms": …, "is_or_search": false}`.
///   * **Zulip** — открытый. `GET /api/v1/messages` с «сужением»
///     `[{"operator":"search",…}]`; авторизация Basic, `почта:ключ`.
///   * **Matrix / Element** — открытый стандарт.
///     `POST /_matrix/client/v3/search`, тело с `search_categories.room_events`.
///   * **Rocket.Chat** — открытый, тоже на своём сервере.
///     `GET /api/v1/chat.search` — но ищет **в одной комнате**, поэтому у него
///     обязательно третье поле. Это не наша прихоть: `roomId` обязателен по
///     документации.
///
/// **Кого здесь нет и почему.** Telegram — Bot API не отдаёт историю чата и не
/// умеет по ней искать (RESEARCH-AND-PLAN §8.1); бот видит только то, что
/// адресовано ему. VK Teams — Bot API той же формы, с тем же ограничением.
/// Обещать поиск по переписке там, где его нет в API, значит показать кнопку,
/// которая не может сработать.
///
/// HTTP приходит снаружи: тест, который ходит в чужой мессенджер, проверяет
/// чужой мессенджер, а не наш код.
public struct WorkMessengers {

    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Настоящая сеть — для приложения. Значение по умолчанию не задано
    /// намеренно: забытый аргумент в тесте молча пошёл бы в чужой сервис.
    public static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public enum Service: String, CaseIterable, Sendable {
        case pachca, mattermost, rocketChat, zulip, matrix

        public var title: String {
            switch self {
            case .pachca:     return "Пачка"
            case .mattermost: return "Mattermost"
            case .rocketChat: return "Rocket.Chat"
            case .zulip:      return "Zulip"
            case .matrix:     return "Matrix / Element"
            }
        }

        /// Что человек должен раздобыть у себя, чтобы подключение заработало.
        public var credentialHint: String {
            switch self {
            case .pachca:
                return "Токен доступа из настроек Пачки, раздел «Интеграции»"
            case .mattermost:
                return "Личный токен доступа из профиля и адрес вашего сервера"
            case .rocketChat:
                return "Токен и идентификатор пользователя из профиля, через двоеточие"
            case .zulip:
                return "Почта и ключ API из настроек, через двоеточие, плюс адрес вашего сервера"
            case .matrix:
                return "Токен доступа из «Настройки → Помощь» в Element и адрес вашего сервера"
            }
        }

        /// Второе поле. У Пачки его нет — облако одно; у сервисов, которые
        /// поднимают сами, адрес свой у каждой команды.
        public var secondaryPrompt: String? {
            switch self {
            case .pachca:     return nil
            case .mattermost: return "адрес сервера, например chat.company.ru"
            case .rocketChat: return "адрес сервера, например chat.company.ru"
            case .zulip:      return "адрес сервера, например zulip.company.ru"
            case .matrix:     return "адрес сервера, например matrix.company.ru"
            }
        }

        public var needsSecondary: Bool { secondaryPrompt != nil }

        /// Третье поле — где искать.
        ///
        /// Mattermost ищет по команде (`team_id`), Rocket.Chat — по одной
        /// комнате (`roomId`); оба параметра обязательны по документации.
        /// Пачка ищет по всем чатам сразу, и спрашивать её не о чем.
        public var scopePrompt: String? {
            switch self {
            case .pachca:     return nil
            case .mattermost: return "идентификатор команды (team_id)"
            case .rocketChat: return "идентификатор комнаты (roomId)"
            // Zulip и Matrix ищут по всему, что видит человек: сужать не нужно.
            case .zulip:      return nil
            case .matrix:     return nil
            }
        }

        public var needsScope: Bool { scopePrompt != nil }

        /// Второе значение внутри поля токена. У Rocket.Chat это
        /// идентификатор пользователя, у Zulip — почта перед ключом; одного
        /// значения сервер не принимает.
        ///
        /// Держать это здесь обязательно: на неполную пару сервер отвечает тем
        /// же 401, что и на протухший ключ, и без проверки orakul советовал
        /// «создайте новый токен» — то есть отправлял человека перевыпускать
        /// исправный ключ вместо того, чтобы дописать вторую половину.
        public var pairedTokenPrompt: String? {
            switch self {
            case .rocketChat: return "токен и идентификатор пользователя через двоеточие"
            case .zulip:      return "почта и ключ API через двоеточие"
            case .pachca, .mattermost, .matrix: return nil
            }
        }

        public var needsPairedToken: Bool { pairedTokenPrompt != nil }

        /// Пачка живёт в облаке; у остальных адрес даёт пользователь.
        func host(secondary: String?) -> String? {
            switch self {
            case .pachca:
                return "https://api.pachca.com"
            case .mattermost, .rocketChat, .zulip, .matrix:
                guard let raw = secondary?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw.hasPrefix("http") ? raw : "https://\(raw)"
            }
        }
    }

    public enum ConnectorError: Error, Equatable, LocalizedError {
        case notConfigured
        case unauthorised
        /// Пара значений в одном поле, а вписано одно. Отдельно от
        /// `unauthorised`: сервер отвечает на это тем же 401, и общий текст
        /// советовал перевыпустить исправный токен.
        case incompleteToken(String)
        /// Сервер ответил, но ошибкой. Отдельно от `unreadable`:
        /// 502 от обратного прокси — это живой сервер и внятный
        /// ответ, а прежний текст советовал проверить ВЕРСИЮ, то
        /// есть отправлял человека не туда.
        case http(Int)
        case unreadable

        /// По-русски и с действием.
        ///
        /// Без `LocalizedError` Swift печатает «The operation couldn’t be
        /// completed. (MeetGPT.WorkMessengers.ConnectorError error 1.)» — по-английски, с внутренним
        /// путём типа и номером случая. В приложении, где всё остальное
        /// по-русски, это видно ровно тогда, когда человеку нужна помощь.
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Мессенджер не подключён. Откройте «Настройки → Подключённые приложения» и вставьте токен."
            case .unauthorised:
                return "Мессенджер не принял токен. Обычно он истёк или у него не тех прав — создайте новый в самом сервисе."
            case .incompleteToken(let expected):
                return "В поле токена нужны два значения: \(expected). Сейчас там одно — сервис откажет, сколько бы раз токен ни перевыпускали."
            case .http(let status):
                return "Мессенджер ответил ошибкой \(status). Сервер на месте — проверьте адрес и права токена, а если это 5xx, то сам сервер или прокси перед ним."
            case .unreadable:
                return "Мессенджер ответил непонятным образом. Если у вас свой сервер, проверьте адрес и версию."
            }
        }

    }

    /// Одно найденное сообщение.
    public struct Hit: Equatable, Sendable {
        /// Кто написал. Сервисы отдают идентификатор, а не имя, — показываем
        /// то, что пришло, и не выдумываем.
        public let author: String?
        public let text: String
        public let service: Service
    }

    let service: Service
    let token: String
    let secondary: String?
    let scope: String?
    let http: HTTP

    public init(service: Service, token: String, secondary: String? = nil,
                scope: String? = nil, http: @escaping HTTP) {
        self.service = service
        self.token = token
        self.secondary = secondary
        self.scope = scope
        self.http = http
    }

    public var isConfigured: Bool { basicsFilled && hasBothTokenHalves }

    /// Всё, кроме второй половины токена: сам токен, адрес сервера и место
    /// поиска. Отдельно от `isConfigured`, чтобы `search` мог сказать
    /// «не подключён» тому, кто ничего не вписал, и назвать недостающую
    /// половину тому, кто вписал одно значение из двух.
    var basicsFilled: Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              service.host(secondary: secondary) != nil else { return false }
        guard service.needsScope else { return true }
        return !(scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// Обе половины на месте — или пара этому сервису не нужна.
    var hasBothTokenHalves: Bool {
        guard service.needsPairedToken else { return true }
        let parts = token.split(separator: ":", maxSplits: 1)
        return parts.count == 2 && parts.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func search(_ query: String) async throws -> [Hit] {
        guard basicsFilled, let host = service.host(secondary: secondary) else {
            throw ConnectorError.notConfigured
        }
        guard hasBothTokenHalves else {
            throw ConnectorError.incompleteToken(service.pairedTokenPrompt ?? "")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = try makeRequest(host: host, query: trimmed)
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
        return try parse(data)
    }

    private func makeRequest(host: String, query: String) throws -> URLRequest {
        let place = scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch service {
        case .pachca:
            var components = URLComponents(string: "\(host)/api/shared/v1/search/messages")
            components?.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request

        case .mattermost:
            guard let url = URL(string: "\(host)/api/v4/teams/\(place)/posts/search") else {
                throw ConnectorError.notConfigured
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // `is_or_search: false` — это И, а не ИЛИ. При ИЛИ выдача забивается
            // сообщениями, где совпало одно случайное слово, а подсказка из
            // случайных сообщений хуже пустой.
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["terms": query, "is_or_search": false])
            return request

        case .zulip:
            // Zulip ищет через «сужение» — список фильтров в JSON. Оператор
            // `search` и есть полнотекстовый поиск по содержимому сообщений.
            let narrow = #"[{"operator":"search","operand":"\#(query)"}]"#
            var components = URLComponents(string: "\(host)/api/v1/messages")
            components?.queryItems = [
                URLQueryItem(name: "anchor", value: "newest"),
                URLQueryItem(name: "num_before", value: "10"),
                URLQueryItem(name: "num_after", value: "0"),
                URLQueryItem(name: "narrow", value: narrow),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            var request = URLRequest(url: url)
            // Basic-авторизация: почта и ключ API через двоеточие — так у Zulip.
            let credentials = Data(token.utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            return request

        case .matrix:
            // Полнотекстовый поиск по событиям комнат. Тело вложенное: сервер
            // умеет искать в нескольких «категориях», нам нужна одна.
            guard let url = URL(string: "\(host)/_matrix/client/v3/search") else {
                throw ConnectorError.notConfigured
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "search_categories": [
                    "room_events": [
                        "search_term": query,
                        // По свежести, а не по релевантности: на звонке важнее
                        // «когда решили», чем «где слово встретилось чаще».
                        "order_by": "recent",
                    ],
                ],
            ])
            return request

        case .rocketChat:
            var components = URLComponents(string: "\(host)/api/v1/chat.search")
            components?.queryItems = [
                URLQueryItem(name: "roomId", value: place),
                URLQueryItem(name: "searchText", value: query),
                URLQueryItem(name: "count", value: "10"),
            ]
            guard let url = components?.url else { throw ConnectorError.notConfigured }
            var request = URLRequest(url: url)
            // Единственный из трёх, кому нужны ДВА значения: токен и
            // идентификатор пользователя. Одного токена мало, поэтому они
            // хранятся в одном поле через двоеточие — четвёртая строка в
            // настройках гарантированно осталась бы незаполненной.
            let parts = token.split(separator: ":", maxSplits: 1)
            request.setValue(String(parts.first ?? ""), forHTTPHeaderField: "X-Auth-Token")
            request.setValue(parts.count == 2 ? String(parts[1]) : "",
                             forHTTPHeaderField: "X-User-Id")
            return request
        }
    }

    private func parse(_ data: Data) throws -> [Hit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unreadable
        }
        switch service {
        case .pachca:
            // `{ "data": [Message], "meta": … }`. Поля Message обязательны по
            // спецификации: id, chat_id, content, user_id, created_at.
            guard let rows = root["data"] as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            return rows.compactMap { row in
                guard let text = row["content"] as? String, !text.isEmpty else { return nil }
                let author = (row["user_id"] as? Int).map(String.init)
                return Hit(author: author, text: text, service: .pachca)
            }

        case .mattermost:
            // `{ "order": [id], "posts": { id: Post } }`. Порядок берётся из
            // `order`: словарь `posts` неупорядочен, и без него выдача каждый
            // раз приходила бы в новом порядке.
            guard let posts = root["posts"] as? [String: Any] else {
                throw ConnectorError.unreadable
            }
            let order = (root["order"] as? [String]) ?? Array(posts.keys)
            return order.compactMap { id in
                guard let post = posts[id] as? [String: Any],
                      let text = post["message"] as? String, !text.isEmpty else { return nil }
                return Hit(author: post["user_id"] as? String, text: text, service: .mattermost)
            }

        case .zulip:
            // `{ "messages": [ { content, sender_full_name } ], "result": "success" }`.
            guard let rows = root["messages"] as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            return rows.compactMap { row in
                guard let text = row["content"] as? String, !text.isEmpty else { return nil }
                return Hit(author: row["sender_full_name"] as? String,
                           text: text, service: .zulip)
            }

        case .matrix:
            // `{ search_categories: { room_events: { results: [ { result: {
            //    content: { body }, sender } } ] } } }` — вложенность родная,
            // не наша: сервер умеет искать в нескольких категориях сразу.
            guard let categories = root["search_categories"] as? [String: Any],
                  let events = categories["room_events"] as? [String: Any],
                  let rows = events["results"] as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            return rows.compactMap { row in
                guard let result = row["result"] as? [String: Any],
                      let content = result["content"] as? [String: Any],
                      let text = content["body"] as? String, !text.isEmpty else { return nil }
                return Hit(author: result["sender"] as? String, text: text, service: .matrix)
            }

        case .rocketChat:
            // `{ "messages": [ { msg, u: { username } } ], "success": true }`.
            guard let rows = root["messages"] as? [[String: Any]] else {
                throw ConnectorError.unreadable
            }
            return rows.compactMap { row in
                guard let text = row["msg"] as? String, !text.isEmpty else { return nil }
                let author = (row["u"] as? [String: Any])?["username"] as? String
                return Hit(author: author, text: text, service: .rocketChat)
            }
        }
    }
}
