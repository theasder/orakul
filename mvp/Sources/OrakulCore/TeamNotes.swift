import Foundation

/// Поиск по базе знаний команды.
///
/// Третий вопрос, отличный от двух других: у трекера спрашивают «заводили ли
/// задачу», у мессенджера — «обсуждали ли это», у базы знаний — «мы это уже
/// описывали». Разница видна на звонке сразу: решение, записанное в вики
/// полгода назад, не найдётся ни в задачах, ни в переписке.
///
/// **Почему это вообще появилось.** `RESEARCH-AND-PLAN` §2.1 закрывал раздел
/// заметок как невозможный: у Яндекс Вики в открытой документации есть выдача
/// страницы по адресу, но не поиск по тексту, а у Teamly публичного описания
/// API мы не нашли. Оба вывода в силе — но они про российские облака, а не про
/// открытые вики, которые команда поднимает у себя. Там поиск есть.
///
/// **Outline** — `POST /api/documents.search`, тело `{"query": …}`, заголовок
/// `Authorization: Bearer`. Проверено по их `spec3.yml` 2026-08-12. В ответе
/// приходит `context` — готовый кусок текста вокруг совпадения: ровно то, что
/// нужно подсказке. Ссылку на документ на звонке никто не откроет, а слова
/// прочитает.
///
/// HTTP приходит снаружи: тест, который ходит в чужую вики, проверяет чужую
/// вики, а не наш код.
public struct TeamNotes {

    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public enum Service: String, CaseIterable, Sendable {
        case outline

        public var title: String {
            switch self {
            case .outline: return "Outline"
            }
        }

        public var credentialHint: String {
            switch self {
            case .outline:
                return "Токен из «Settings → API tokens». Адрес нужен, только если вики поднята у вас; для облака оставьте поле пустым"
            }
        }

        public var hostPrompt: String {
            switch self {
            case .outline: return "адрес, если сервер свой — например wiki.company.ru"
            }
        }

        /// Пустой адрес — это облако сервиса, а не ошибка: Outline бывает и
        /// облачным, и поднятым у себя, и оба случая рабочие.
        func host(_ raw: String?) -> String {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return "https://app.getoutline.com" }
            return value.hasPrefix("http") ? value : "https://\(value)"
        }
    }

    public enum ConnectorError: Error, Equatable, LocalizedError {
        case notConfigured
        case unauthorised
        case unreadable

        /// По-русски и с действием.
        ///
        /// Без `LocalizedError` Swift печатает «The operation couldn’t be
        /// completed. (MeetGPT.TeamNotes.ConnectorError error 1.)» — по-английски, с внутренним
        /// путём типа и номером случая. В приложении, где всё остальное
        /// по-русски, это видно ровно тогда, когда человеку нужна помощь.
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "База знаний не подключён. Откройте «Настройки → Подключённые приложения» и вставьте токен."
            case .unauthorised:
                return "База знаний не принял токен. Обычно он истёк или у него не тех прав — создайте новый в самом сервисе."
            case .unreadable:
                return "База знаний ответил непонятным образом. Если у вас свой сервер, проверьте адрес и версию."
            }
        }

    }

    /// Один найденный кусок текста.
    public struct Hit: Equatable, Sendable {
        public let title: String
        /// Слова вокруг совпадения — они и попадают в подсказку.
        public let context: String
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

    /// Адрес не обязателен — в отличие от GitLab и Gitea. Требовать его значило
    /// бы не пускать тех, у кого Outline облачный.
    public var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func search(_ query: String) async throws -> [Hit] {
        guard isConfigured else { throw ConnectorError.notConfigured }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let host = service.host(hostValue)
        guard let url = URL(string: "\(host)/api/documents.search") else {
            throw ConnectorError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["query": trimmed, "limit": 10])
        request.timeoutInterval = 8

        let (data, response) = try await http(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ConnectorError.unauthorised
        }
        // `{ "data": [ { "context": …, "document": { "title": … } } ] }`.
        // Объект без `data` — это тело ошибки, и выдать его за пустую выдачу
        // значит сказать «не описывали» там, где мы не смогли спросить.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw ConnectorError.unreadable
        }
        return rows.compactMap { row in
            let context = (row["context"] as? String) ?? ""
            let title = ((row["document"] as? [String: Any])?["title"] as? String) ?? ""
            guard !context.isEmpty || !title.isEmpty else { return nil }
            return Hit(title: title.isEmpty ? "Без названия" : title,
                       context: context, service: service)
        }
    }
}
