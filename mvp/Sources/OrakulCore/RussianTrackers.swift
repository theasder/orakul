import Foundation

/// Коннекторы к российским трекерам — не через MCP.
///
/// MCP-каталог в этом приложении подключается по OAuth 2.1 с динамической
/// регистрацией клиента, и это работает только там, где вендор поднял
/// MCP-сервер. Ни у одного российского трекера его нет. Завести для них строки
/// в MCP-каталоге с выдуманным адресом означало бы показать кнопку
/// «Подключить», которая не может сработать, — ровно та ошибка, за которую
/// пришлось править лендинг.
///
/// Поэтому здесь прямой REST по документации вендора: токен пользователь
/// заводит сам, токен лежит в Связке ключей.
///
/// **Почему сервисов три, а не пять.** Первый заход описывал ещё WEEEK и Pyrus,
/// и оба адреса были выдуманы. По документации: у Pyrus нет поиска задач по
/// тексту вообще — только реестр конкретной формы (`GET /forms/{id}/register`),
/// то есть коннектор такого вида там невозможен; у WEEEK параметры выдачи задач
/// публично не описаны, и «скорее всего `search`» означало бы фильтр, который
/// сервис вправе проигнорировать и вернуть первые попавшиеся задачи — а
/// подсказка из случайных задач хуже пустой. Осталось то, что проверено.
///
/// HTTP приходит снаружи: тест, который ходит в чужой трекер, проверяет чужой
/// трекер, а не наш код.
public struct RussianTrackers {

    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Настоящая сеть — для приложения. Тесты передают своё замыкание, поэтому
    /// сюда они не попадают: значение по умолчанию тут не задано намеренно,
    /// иначе забытый аргумент в тесте молча пошёл бы в чужой сервис.
    public static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public enum Service: String, CaseIterable, Sendable {
        case yandexTracker, kaiten, yougile, bitrix24

        public var title: String {
            switch self {
            case .yandexTracker: return "Яндекс Трекер"
            case .kaiten:        return "Kaiten"
            case .yougile:       return "YouGile"
            case .bitrix24:      return "Битрикс24"
            }
        }

        /// Что человек должен получить в своём сервисе, чтобы подключение
        /// заработало. Показывается рядом с полем ввода: «нужен токен» без
        /// уточнения, какой именно, — это тупик.
        public var credentialHint: String {
            switch self {
            case .yandexTracker: return "OAuth-токен и идентификатор организации: «Администрирование» → «Организации», поле ID"
            case .kaiten:        return "API-токен из профиля, раздел «API», и адрес вашей команды"
            case .yougile:       return "Ключ компании из раздела «Интеграции»"
            case .bitrix24:
                // Вебхук показывают одной строкой вида
                // https://фирма.bitrix24.ru/rest/1/abc.../ — сюда идёт
                // середина, «1/abc...», а адрес портала в поле ниже.
                return "Входящий вебхук: «Разработчикам» → «Другое» → «Входящий вебхук», право «Задачи». Вставьте ссылку целиком — адрес портала возьмётся из неё"
            }
        }

        /// Второе поле, если одного токена мало. У двух сервисов оно значит
        /// разное — организацию у Яндекса, адрес команды у Kaiten, — поэтому
        /// подпись хранится здесь, а не в интерфейсе: там она разъедется с тем,
        /// как значение используется.
        public var secondaryPrompt: String? {
            switch self {
            // Один токен обслуживает несколько организаций; без X-Org-ID
            // запрос уходит в никуда с 403.
            case .yandexTracker: return "идентификатор организации"
            // У Kaiten нет общего адреса API: он свой у каждой команды.
            case .kaiten:        return "адрес команды, например team.kaiten.ru"
            // Портал у каждой фирмы свой, общего адреса API нет.
            // Заполнять не нужно, если вебхук вставлен целиком: адрес
            // возьмётся из ссылки. Поле остаётся для тех, кто вписывает
            // середину руками, и для порталов на своём домене.
            case .bitrix24:      return "адрес портала, если вставили не ссылку целиком"
            case .yougile:       return nil
            }
        }

        public var needsSecondary: Bool { secondaryPrompt != nil }

        /// Куда класть заведённую задачу. Третье поле, и без него завести
        /// задачу нельзя ни в одном из трёх сервисов: у каждого своё
        /// обязательное «место» и своё для него слово.
        ///
        /// Проверено по документации вендоров: Яндекс требует `queue`, Kaiten —
        /// `board_id`, YouGile ставит задачу в колонку. У YouGile документация
        /// расходится, обязательна ли колонка; требуем всё равно — задача без
        /// колонки не попадает на доску, то есть для человека пропадает, а
        /// лишний верный параметр никогда не ошибка.
        public var destinationPrompt: String? {
            switch self {
            case .yandexTracker: return "ключ очереди, например TREK"
            case .kaiten:        return "номер доски, например 4"
            case .yougile:       return "идентификатор колонки"
            case .bitrix24:      return "номер ответственного, например 1"
            }
        }

        var needsDestination: Bool { destinationPrompt != nil }

        /// Адрес API. У Kaiten он собирается из домена команды — общего хоста
        /// у сервиса нет.
        func host(secondary: String?) -> String {
            switch self {
            case .yandexTracker: return "https://api.tracker.yandex.net/v3"
            case .kaiten:
                // Люди вставляют адрес из строки браузера целиком, вместе со
                // схемой и путём до доски. Берём только хост: остальное дало бы
                // .../boards/5/api/latest и 404, который нечем объяснить.
                let domain = (secondary ?? "")
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .split(separator: "/").first
                    .map(String.init) ?? ""
                return "https://\(domain.trimmingCharacters(in: .whitespaces))/api/latest"
            case .yougile:       return "https://yougile.com/api-v2"
            case .bitrix24:
                // Тот же случай, что у Kaiten: адрес копируют из строки
                // браузера вместе со схемой и путём до раздела.
                let domain = (secondary ?? "")
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .split(separator: "/").first
                    .map(String.init) ?? ""
                return "https://\(domain.trimmingCharacters(in: .whitespaces))/rest"
            }
        }
    }

    public struct Issue: Equatable, Sendable {
        public let key: String
        public let title: String
        public let url: URL?
    }

    public enum TrackerError: Error, Equatable, LocalizedError {
        case notConfigured(Service)
        case unauthorised(Service)
        case http(Service, Int)
        /// Сервис ответил успехом, а внутри — отказ.
        ///
        /// Битрикс так и работает: HTTP 200 и `{"error": …,
        /// "error_description": …}` в теле. Без этой ветки отозванный вебхук
        /// или нехватка права «Задачи» выглядели бы как «ничего не нашлось» —
        /// то есть продукт уверенно сообщал бы об исходе поиска, которого не
        /// было.
        case vendor(Service, code: String, description: String)
        case unreadable(Service)

        /// По-русски, с названием сервиса и с действием.
        ///
        /// Без `LocalizedError` наружу шло «The operation couldn’t be
        /// completed. (MeetGPT.RussianTrackers.TrackerError error 1.)»:
        /// по-английски и без единого намёка, какой из подключённых трекеров
        /// отказал. При трёх подключённых это делает сообщение бесполезным.
        public var errorDescription: String? {
            switch self {
            case .notConfigured(let service):
                return "\(service.title) не подключён. Вставьте токен в «Настройки → Подключённые приложения»."
            case .unauthorised(let service):
                return "\(service.title) не принял токен: истёк или не хватает прав. Создайте новый в самом сервисе."
            case .vendor(let service, let code, let description):
                let detail = description.isEmpty ? code : description
                return "\(service.title) отказал: \(detail). Если это Битрикс24 — проверьте, что вебхук не удалён и у него есть право «Задачи»."
            case .http(let service, let status):
                return "\(service.title) ответил ошибкой \(status). Если это 404 — проверьте очередь или доску в настройках."
            case .unreadable(let service):
                return "\(service.title) вернул ответ, который не удалось разобрать."
            }
        }

    }

    let service: Service
    let token: String
    let secondary: String?
    /// Куда класть заведённую задачу: очередь, доска или колонка. Для чтения не
    /// нужна, поэтому необязательна — трекер можно подключить только на чтение.
    let destination: String?
    let http: HTTP

    public init(service: Service, token: String, secondary: String? = nil,
                destination: String? = nil, http: @escaping HTTP) {
        self.service = service
        // Битрикс показывает вебхук одной строкой целиком. Человек копирует её
        // целиком — это нормальное поведение, а не ошибка ввода. Требовать
        // вырезать середину и отдельно вписать портал значит закладывать самый
        // вероятный способ ошибиться в саму форму.
        let parsed = Self.splitBitrixWebhook(service: service, token: token)
        self.token = parsed.token
        self.secondary = parsed.host ?? secondary
        self.destination = destination
        self.http = http
    }

    /// Разбирает вставленную целиком ссылку вебхука на портал и учётную часть.
    ///
    /// Возвращает исходный токен, если это не Битрикс или если вставлена не
    /// ссылка: у остальных трёх сервисов токен — обычная строка, и трогать её
    /// нельзя.
    static func splitBitrixWebhook(service: Service,
                                   token: String) -> (token: String, host: String?) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service == .bitrix24, trimmed.contains("/rest/") else { return (token, nil) }

        let withoutScheme = trimmed
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let parts = withoutScheme.split(separator: "/", omittingEmptySubsequences: true)
        guard let host = parts.first, let restIndex = parts.firstIndex(of: "rest") else {
            return (token, nil)
        }
        // После `rest` идут номер пользователя и код. Дальше может стоять имя
        // метода — его отбрасываем: адрес метода orakul подставляет сам.
        let credentials = parts[parts.index(after: restIndex)...]
            .prefix(2)
            .joined(separator: "/")
        guard credentials.contains("/") else { return (token, nil) }
        return (credentials, String(host))
    }

    // MARK: - Запросы

    /// Задачи по тексту: ключ, заголовок и ссылка, по которой человек откроет
    /// задачу сам.
    public func search(_ query: String, limit: Int = 10) async throws -> [Issue] {
        guard !token.isEmpty, !(service.needsSecondary && (secondary ?? "").isEmpty) else {
            throw TrackerError.notConfigured(service)
        }
        var request = URLRequest(url: try endpoint(for: query, limit: limit))
        request.timeoutInterval = 8   // тот же бюджет, что у остальных источников
        for (field, value) in headers() { request.setValue(value, forHTTPHeaderField: field) }
        if let body = try body(for: query, limit: limit) {
            request.httpMethod = "POST"
            request.httpBody = body
        }

        let (data, response) = try await http(request)
        switch response.statusCode {
        case 200...299: break
        case 401, 403:  throw TrackerError.unauthorised(service)
        default:        throw TrackerError.http(service, response.statusCode)
        }
        // Верхняя граница ещё раз, уже после разбора: у трёх сервисов размер
        // задаётся параметром и это ничего не меняет, а у Битрикса страница
        // всегда пятьдесят и урезать выдачу больше негде.
        return Array(try parse(data).prefix(limit))
    }

    public func headers() -> [String: String] {
        switch service {
        case .yandexTracker:
            var fields = ["Authorization": "OAuth \(token)",
                          "Content-Type": "application/json"]
            if let secondary { fields[Self.orgHeader(for: secondary)] = secondary }
            return fields
        case .kaiten, .yougile:
            return ["Authorization": "Bearer \(token)"]
        // У Битрикса ключа в заголовке нет вовсе: вебхук — это адрес, и права
        // проверяются по нему. Заголовок остаётся один, про формат тела.
        case .bitrix24:
            return ["Content-Type": "application/json"]
        }
    }

    /// Заголовков организации у Трекера два, и они не взаимозаменяемы:
    /// `X-Org-ID` — организация в Яндекс 360, `X-Cloud-Org-ID` — в Yandex
    /// Cloud Organization. Отправленный не тот даёт отказ, по которому не
    /// догадаться, что дело в заголовке, а не в токене.
    ///
    /// Спрашивать тип организации у человека незачем: идентификаторы разной
    /// формы. У Яндекс 360 это число, у Cloud — двадцать знаков, начинающихся
    /// с `bpf` (`bpf3crucp1v28b74p3rk`). По форме и выбираем.
    static func orgHeader(for organisation: String) -> String {
        let value = organisation.trimmingCharacters(in: .whitespaces)
        let isNumeric = !value.isEmpty && value.allSatisfy(\.isNumber)
        return isNumeric ? "X-Org-ID" : "X-Cloud-Org-ID"
    }

    func endpoint(for query: String, limit: Int) throws -> URL {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let path: String
        switch service {
        // Поиск у Яндекса — POST с телом; в адресе остаётся только размер
        // страницы. Строка запроса уезжает в body, см. body(for:limit:).
        case .yandexTracker: path = "/issues/_search?perPage=\(limit)"
        case .kaiten:        path = "/cards?query=\(escaped)&limit=\(limit)"
        case .yougile:       path = "/tasks?title=\(escaped)&limit=\(limit)"
        // У Битрикса ключ едет в адресе, а не в заголовке: вебхук — это
        // и есть номер пользователя с кодом внутри пути. Размер страницы
        // всегда пятьдесят и не настраивается, поэтому limit урезает
        // выдачу уже здесь, после разбора.
        case .bitrix24:      path = "/\(token)/tasks.task.list"
        }
        guard let url = URL(string: service.host(secondary: secondary) + path) else {
            throw TrackerError.unreadable(service)
        }
        return url
    }

    // MARK: - Завести задачу

    /// Заводит задачу в трекере и возвращает её — с ключом и ссылкой, чтобы
    /// человек мог сразу открыть, что получилось.
    ///
    /// Отдельно от `search`: чтение можно повторить, запись — нет. Поэтому тут
    /// нет мягкого разбора «ну хоть что-то»: если ответ непонятен, это ошибка,
    /// а не пустой результат. Молча «завести» задачу, которой нет, — худшее,
    /// что может сделать кнопка после звонка.
    public func createIssue(title: String, description: String? = nil) async throws -> Issue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              !(service.needsSecondary && (secondary ?? "").isEmpty),
              !(service.needsDestination && (destination ?? "").isEmpty),
              !trimmed.isEmpty
        else { throw TrackerError.notConfigured(service) }

        var request = URLRequest(url: try createEndpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        for (field, value) in headers() { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try createBody(title: trimmed, description: description)

        let (data, response) = try await http(request)
        switch response.statusCode {
        case 200...299: break
        case 401, 403:  throw TrackerError.unauthorised(service)
        default:        throw TrackerError.http(service, response.statusCode)
        }
        guard let created = parseCreated(data) else { throw TrackerError.unreadable(service) }
        return created
    }

    func createEndpoint() throws -> URL {
        let path: String
        switch service {
        case .yandexTracker: path = "/issues/"
        case .kaiten:        path = "/cards"
        case .yougile:       path = "/tasks"
        case .bitrix24:      path = "/\(token)/tasks.task.add"
        }
        guard let url = URL(string: service.host(secondary: secondary) + path) else {
            throw TrackerError.unreadable(service)
        }
        return url
    }

    /// Тело — по документации вендора, с обязательными полями и без лишних.
    func createBody(title: String, description: String?) throws -> Data {
        let place = destination ?? ""
        var payload: [String: Any]
        switch service {
        case .yandexTracker:
            payload = ["summary": title, "queue": place]
            if let description { payload["description"] = description }
        case .kaiten:
            // board_id — целое. Строка тут даёт 400, а сообщение об этом
            // приходит на английском и посреди звонка.
            //
            // Раньше стояло `Int(place) ?? 0`, и это была тихая подмена: поле
            // доски в настройках — обычная строка, подсказка «номер доски,
            // например 4» ничего не проверяет, и человек, вписавший НАЗВАНИЕ
            // доски, отправлял в чужой трекер запись с доской номер ноль. Для
            // чтения такая подмена стоила бы пустой выдачи, для записи — 400
            // посреди звонка или карточки не там, где ждали.
            guard let board = Int(place.trimmingCharacters(in: .whitespaces)) else {
                throw TrackerError.notConfigured(service)
            }
            payload = ["title": title, "board_id": board]
            if let description { payload["description"] = description }
        case .yougile:
            payload = ["title": title, "columnId": place]
            if let description { payload["description"] = description }
        case .bitrix24:
            // Задача без ответственного в Битриксе не заводится, поэтому
            // третье поле здесь — номер человека, а не доски или колонки.
            // Строка вместо номера даёт ту же тихую подмену, что стоила
            // Kaiten доски номер ноль, — отсюда та же проверка.
            guard let responsible = Int(place.trimmingCharacters(in: .whitespaces)) else {
                throw TrackerError.notConfigured(service)
            }
            var fields: [String: Any] = ["TITLE": title, "RESPONSIBLE_ID": responsible]
            if let description { fields["DESCRIPTION"] = description }
            payload = ["fields": fields]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw TrackerError.unreadable(service)
        }
        return data
    }

    /// Ответ на создание: ключ и ссылка. У Яндекса это `key` (`TREK-42`), у
    /// остальных числовой `id`.
    func parseCreated(_ data: Data) -> Issue? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let key = (object["key"] as? String) ?? (object["id"].map { "\($0)" }) ?? ""
        guard !key.isEmpty else { return nil }
        let title = (object["summary"] as? String) ?? (object["title"] as? String) ?? ""
        return Issue(key: key, title: title, url: issueURL(key: key, raw: object))
    }

    private func issueURL(key: String, raw: [String: Any]) -> URL? {
        if let direct = raw["url"] as? String, let url = URL(string: direct) { return url }
        switch service {
        case .yandexTracker: return URL(string: "https://tracker.yandex.ru/\(key)")
        case .kaiten:
            let host = service.host(secondary: secondary)
                .replacingOccurrences(of: "/api/latest", with: "")
            return URL(string: "\(host)/ticket/\(key)")
        case .yougile: return nil
        case .bitrix24:
            let portal = service.host(secondary: secondary)
                .replacingOccurrences(of: "/rest", with: "")
            return URL(string: "\(portal)/company/personal/user/1/tasks/task/view/\(key)/")
        }
    }

    /// Тело запроса — только там, где вендор требует POST. nil значит GET.
    func body(for query: String, limit: Int) throws -> Data? {
        switch service {
        case .yandexTracker:
            // `query` — язык запросов Трекера; текст в кавычках ищется по
            // сводке и описанию.
            let escaped = query.replacingOccurrences(of: "\"", with: "'")
            let payload = ["query": "Summary: \"\(escaped)\""]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                throw TrackerError.unreadable(service)
            }
            return data
        case .kaiten, .yougile:
            return nil
        case .bitrix24:
            // Документация метода: TITLE ищется по шаблону, где `%` и `_` —
            // подстановочные знаки, и они ставятся В ЗНАЧЕНИЕ, а не приставкой
            // к имени поля. Приставка `%TITLE` — общий приём Битрикса, но для
            // этого метода он в документации не показан, поэтому здесь ровно
            // то, что описано.
            //
            // Размер страницы всегда пятьдесят и параметром не задаётся —
            // `limit` поэтому применяется после разбора, а не тут.
            let payload: [String: Any] = [
                "filter": ["TITLE": "%\(query)%"],
                "select": ["ID", "TITLE", "STATUS"],
                "start": 0,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                throw TrackerError.unreadable(service)
            }
            return data
        }
    }

    /// Разбор ответа. У каждого сервиса свои имена полей, поэтому разбираем
    /// мягко: задача без заголовка — это задача без заголовка, а не сбой всего
    /// списка. Тот же принцип, что в архиве: один битый элемент не уносит
    /// остальные.
    func parse(_ data: Data) throws -> [Issue] {
        let root = try? JSONSerialization.jsonObject(with: data)
        // Проверяется до разбора списка: у Битрикса отказ приезжает с кодом
        // 200, и если сначала искать задачи, отказ станет пустой выдачей.
        if let object = root as? [String: Any], let code = object["error"] as? String {
            throw TrackerError.vendor(
                service, code: code,
                description: (object["error_description"] as? String) ?? "")
        }
        let rows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rows = array
        } else if let object = root as? [String: Any] {
            // Битрикс кладёт список на этаж глубже: {"result": {"tasks": []}}.
            // Разворачиваем `result` до поиска ключей, иначе выдача пустая, а
            // ответ при этом совершенно исправный.
            let unwrapped = (object["result"] as? [String: Any]) ?? object
            // YouGile отдаёт список под "content", Яндекс — массивом,
            // Kaiten — массивом; "tasks"/"data" оставлены на случай смены формы.
            rows = (unwrapped["content"] as? [[String: Any]])
                ?? (unwrapped["tasks"] as? [[String: Any]])
                ?? (unwrapped["data"] as? [[String: Any]])
                ?? (object["result"] as? [[String: Any]])
                ?? []
        } else {
            throw TrackerError.unreadable(service)
        }

        return rows.compactMap { row in
            // Битрикс отдаёт поля прописными: ID, TITLE. Строчные варианты
            // остаются первыми — у трёх остальных сервисов они и приходят.
            let key = (row["key"] as? String)
                ?? (row["id"].map { "\($0)" })
                ?? (row["ID"].map { "\($0)" })
                ?? ""
            let title = (row["summary"] as? String)
                ?? (row["title"] as? String)
                ?? (row["name"] as? String)
                ?? (row["TITLE"] as? String)
                ?? "Без названия"
            guard !key.isEmpty else { return nil }
            return Issue(key: key, title: title, url: URL(string: (row["url"] as? String) ?? ""))
        }
    }
}
