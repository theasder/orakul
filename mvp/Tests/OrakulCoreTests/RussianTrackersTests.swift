import Foundation
import Testing
@testable import OrakulCore

/// Коннекторы к чужим сервисам ломаются у пользователя, а не у нас: чужой токен,
/// чужой формат ответа, чужие коды ошибок. Поэтому проверяется то, что мы
/// действительно контролируем — что уходит в запрос и что мы понимаем в ответе.
/// Настоящая сеть здесь не поднимается: тест, который ходит в Яндекс Трекер,
/// проверяет Яндекс Трекер.
///
/// Форма запроса у каждого сервиса своя и сверена с документацией вендора:
/// у Яндекса поиск — POST с телом, у Kaiten и YouGile — GET с параметрами.
/// Первая версия этого файла проверяла GET у всех и проходила, потому что
/// проверяла мой же вымысел.
@Suite("Российские трекеры")
struct RussianTrackersTests {

    private func stub(status: Int = 200, json: String = "[]")
        -> (RussianTrackers.HTTP, Recorder) {
        let recorder = Recorder()
        let http: RussianTrackers.HTTP = { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        return (http, recorder)
    }

    /// Второе поле значит разное: организация у Яндекса, домен команды у Kaiten.
    private func secondary(for service: RussianTrackers.Service) -> String? {
        switch service {
        case .yandexTracker: return "1234567"
        case .kaiten:        return "team.kaiten.ru"
        case .bitrix24:      return "company.bitrix24.ru"
        case .yougile:       return nil
        }
    }

    private func client(_ service: RussianTrackers.Service,
                        http: @escaping RussianTrackers.HTTP) -> RussianTrackers {
        RussianTrackers(service: service, token: "t0ken",
                        secondary: secondary(for: service), http: http)
    }

    @Test("каждый сервис ходит по своему адресу и со своим токеном")
    func requestShape() async throws {
        for service in RussianTrackers.Service.allCases {
            let (http, recorder) = stub()
            _ = try await client(service, http: http).search("тарифы")

            let request = try #require(recorder.last)
            let url = try #require(request.url?.absoluteString)
            #expect(url.hasPrefix(service.host(secondary: secondary(for: service))),
                    "\(service.title): чужой хост")
            // Ключ обязан уехать — но каждый сервис берёт его по-своему:
            // трое заголовком, Битрикс частью адреса. Требовать заголовок у
            // всех значило бы либо выкинуть Битрикс из проверки, либо
            // придумать ему заголовок, которого вендор не ждёт.
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth.contains("t0ken") || url.contains("t0ken"),
                    "\(service.title): ключ не уехал ни заголовком, ни адресом")
        }
    }

    @Test("у Kaiten нет общего адреса — хост собирается из домена команды")
    func kaitenHostComesFromTheTeamDomain() async throws {
        // Общего api.kaiten.ru не существует: адрес свой у каждой команды.
        // Запрос по общему хосту не «иногда не работает», он не работает
        // никогда.
        // Проверяются те формы, в которых адрес реально приезжает: из строки
        // браузера — со схемой и путём до доски.
        for pasted in ["team.kaiten.ru", "https://team.kaiten.ru/",
                       "https://team.kaiten.ru/space/12/boards/5", " team.kaiten.ru "] {
            let (http, recorder) = stub()
            _ = try await RussianTrackers(service: .kaiten, token: "t",
                                          secondary: pasted, http: http)
                .search("лимиты")
            let url = try #require(recorder.last?.url?.absoluteString)
            #expect(url.hasPrefix("https://team.kaiten.ru/api/latest/cards"),
                    "адрес «\(pasted)» не вычищен: \(url)")
        }
    }

    @Test("у Kaiten и YouGile запрос уезжает в адрес, закодированным")
    func getServicesCarryTheQueryInTheURL() async throws {
        for service in [RussianTrackers.Service.kaiten, .yougile] {
            let (http, recorder) = stub()
            _ = try await client(service, http: http).search("тарифы")
            let request = try #require(recorder.last)
            let url = try #require(request.url?.absoluteString)
            // Кириллица должна уехать в процентном кодировании, иначе URL не
            // соберётся и сервис ответит 400.
            #expect(!url.contains("тарифы"), "\(service.title): запрос не закодирован")
            #expect(url.contains("%D1%82"), "\(service.title): кириллица потерялась")
            #expect(request.httpMethod != "POST")
            #expect(request.httpBody == nil)
        }
    }

    @Test("у Яндекса поиск — POST с телом, а не параметр в адресе")
    func yandexSearchIsAPost() async throws {
        // GET /issues/_search?query= в документации нет: поиск принимает язык
        // запросов в теле. Первый заход отправлял GET и не сработал бы ни разу.
        let (http, recorder) = stub()
        _ = try await client(.yandexTracker, http: http).search("тарифы")

        let request = try #require(recorder.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.contains("_search") == true)
        #expect(request.url?.absoluteString.contains("тарифы") == false)

        let body = try #require(request.httpBody)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try #require(payload["query"] as? String)
        #expect(query.contains("тарифы"))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Яндекс Трекер получает идентификатор организации, остальные — нет")
    func yandexNeedsOrganisation() async throws {
        // Без идентификатора организации Трекер отвечает 403, и это самая
        // частая причина, по которой «токен правильный, а не работает».
        //
        // Заголовка два, и какой уйдёт — решает форма значения: у Яндекс 360
        // это число, у Yandex Cloud Organization — двадцать знаков с «bpf».
        // Поэтому здесь настоящие формы, а не выдуманная «org-1»: на ней
        // проверка молчала бы о том, что вторая ветка вообще есть.
        let (http, recorder) = stub()
        _ = try await client(.yandexTracker, http: http).search("q")
        #expect(recorder.last?.value(forHTTPHeaderField: "X-Org-ID") == "1234567")
        #expect(recorder.last?.value(forHTTPHeaderField: "X-Cloud-Org-ID") == nil)

        let (httpCloud, recorderCloud) = stub()
        _ = try await RussianTrackers(
            service: .yandexTracker, token: "t0ken",
            secondary: "bpf3crucp1v28b74p3rk", http: httpCloud).search("q")
        #expect(recorderCloud.last?.value(forHTTPHeaderField: "X-Cloud-Org-ID")
                == "bpf3crucp1v28b74p3rk")
        #expect(recorderCloud.last?.value(forHTTPHeaderField: "X-Org-ID") == nil)

        let (http2, recorder2) = stub()
        _ = try await client(.yougile, http: http2).search("q")
        #expect(recorder2.last?.value(forHTTPHeaderField: "X-Org-ID") == nil)
        #expect(recorder2.last?.value(forHTTPHeaderField: "X-Cloud-Org-ID") == nil)
    }

    @Test("пустой токен — это «не настроено», а не поход в сеть")
    func emptyTokenNeverCallsOut() async {
        let (http, recorder) = stub()
        let tracker = RussianTrackers(service: .yougile, token: "", http: http)
        await #expect(throws: RussianTrackers.TrackerError.notConfigured(.yougile)) {
            try await tracker.search("q")
        }
        #expect(recorder.count == 0, "запрос ушёл без токена")
    }

    @Test("Kaiten без домена команды не ходит никуда")
    func missingSecondaryNeverCallsOut() async {
        // Иначе адрес собрался бы как https:///api/latest — запрос в пустоту,
        // и ошибка пришла бы из сети, а не из настроек.
        let (http, recorder) = stub()
        let tracker = RussianTrackers(service: .kaiten, token: "t", secondary: "", http: http)
        await #expect(throws: RussianTrackers.TrackerError.notConfigured(.kaiten)) {
            try await tracker.search("q")
        }
        #expect(recorder.count == 0)
    }

    @Test("401 и 403 читаются как «не тот токен», прочее — как код")
    func errorsAreDistinguished() async {
        for status in [401, 403] {
            let (http, _) = stub(status: status)
            await #expect(throws: RussianTrackers.TrackerError.unauthorised(.yougile)) {
                try await client(.yougile, http: http).search("q")
            }
        }
        let (http, _) = stub(status: 500)
        await #expect(throws: RussianTrackers.TrackerError.http(.yougile, 500)) {
            try await client(.yougile, http: http).search("q")
        }
    }

    @Test("разные формы ответа разбираются одинаково")
    func parsesEachShape() async throws {
        // Голый массив (Kaiten, Яндекс) и обёртка content (YouGile).
        let shapes = [
            #"[{"id": 42, "title": "Поднять лимиты"}]"#,
            #"{"content": [{"id": 42, "title": "Поднять лимиты"}]}"#,
            #"{"data": [{"id": 42, "title": "Поднять лимиты"}]}"#,
        ]
        for json in shapes {
            let (http, _) = stub(json: json)
            let issues = try await client(.kaiten, http: http).search("лимиты")
            #expect(issues.count == 1, "форма не разобрана: \(json.prefix(20))")
            #expect(issues.first?.key == "42")
            #expect(issues.first?.title == "Поднять лимиты")
        }
    }

    @Test("задача без заголовка не выбрасывает весь список")
    func partialRowsSurvive() async throws {
        // Одна кривая запись не должна стоить пользователю всей выдачи —
        // тот же принцип, что в архиве созвонов.
        let json = #"[{"key": "TRACK-1"}, {"summary": "нет ключа"}, {"key": "TRACK-2", "summary": "Есть"}]"#
        let (http, _) = stub(json: json)
        let issues = try await client(.yandexTracker, http: http).search("q")
        #expect(issues.map(\.key) == ["TRACK-1", "TRACK-2"], "запись без ключа не отбрасывается")
        #expect(issues.first?.title == "Без названия")
    }

    @Test("не-JSON в ответе — ошибка, а не пустой список")
    func garbageIsAnError() async {
        // Пустой список сказал бы «задач нет», хотя правда — «сервис ответил
        // мусором». Для того, кто ищет свою задачу, это разные вещи.
        let (http, _) = stub(json: "<html>502 Bad Gateway</html>")
        await #expect(throws: RussianTrackers.TrackerError.unreadable(.yougile)) {
            try await client(.yougile, http: http).search("q")
        }
    }

    @Test("у каждого сервиса написано, где взять токен")
    func everyServiceExplainsItsCredential() {
        // «Нужен токен» без указания, какой именно и откуда, — тупик, в котором
        // подключение и умирает. То же и про второе поле: оно значит разное.
        for service in RussianTrackers.Service.allCases {
            #expect(service.credentialHint.count > 20, "\(service.title): подсказка ни о чём")
            #expect(!service.title.isEmpty)
            if service.needsSecondary {
                #expect(service.secondaryPrompt?.isEmpty == false,
                        "\(service.title): второе поле без подписи")
            }
        }
    }

    @Test("запрос не висит дольше бюджета остальных источников")
    func requestHasADeadline() async throws {
        let (http, recorder) = stub()
        _ = try await client(.yougile, http: http).search("q")
        // Восемь секунд — тот же дедлайн, что у MCP-источников: один зависший
        // сервис стоит одного источника, а не всего ответа.
        #expect(recorder.last?.timeoutInterval == 8)
    }
}

/// Запоминает запросы: замыкание помечено `Sendable`, поэтому изменяемое
/// состояние живёт под замком.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

@Suite("Заголовок организации Яндекс Трекера")
struct YandexOrgHeaderTests {
    /// Два заголовка, и перепутанный отвечает отказом, в котором про заголовок
    /// не сказано ни слова — человек идёт перевыпускать исправный токен.
    @Test("числовой идентификатор — Яндекс 360, буквенно-цифровой — Yandex Cloud",
          arguments: [
            ("1234567", "X-Org-ID"),
            ("42", "X-Org-ID"),
            ("bpf3crucp1v28b74p3rk", "X-Cloud-Org-ID"),
            ("bpfaa11bb22cc33dd44e", "X-Cloud-Org-ID"),
          ])
    func headerFollowsShape(organisation: String, expected: String) {
        #expect(RussianTrackers.orgHeader(for: organisation) == expected)
    }

    @Test("пробелы вокруг значения не меняют выбор")
    func trimsBeforeDeciding() {
        #expect(RussianTrackers.orgHeader(for: "  1234567  ") == "X-Org-ID")
        #expect(RussianTrackers.orgHeader(for: " bpf3crucp1v28b74p3rk ") == "X-Cloud-Org-ID")
    }

    @Test("запрос несёт ровно один заголовок организации")
    func exactlyOneOrgHeader() {
        for organisation in ["1234567", "bpf3crucp1v28b74p3rk"] {
            let client = RussianTrackers(
                service: .yandexTracker, token: "y0_test", secondary: organisation,
                http: { _ in (Data(), HTTPURLResponse()) })
            let sent = client.headers().keys.filter { $0.hasSuffix("Org-ID") }
            #expect(sent.count == 1, "заголовков организации \(sent.count): \(sent)")
            #expect(client.headers()[RussianTrackers.orgHeader(for: organisation)]
                    == organisation)
        }
    }
}

@Suite("Битрикс24")
struct Bitrix24Tests {
    private func stub(json: String) -> (RussianTrackers.HTTP, () -> URLRequest?) {
        var last: URLRequest?
        let http: RussianTrackers.HTTP = { request in
            last = request
            return (Data(json.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (http, { last })
    }

    private func client(http: @escaping RussianTrackers.HTTP,
                        destination: String? = nil) -> RussianTrackers {
        RussianTrackers(service: .bitrix24, token: "1/abc123",
                        secondary: "company.bitrix24.ru",
                        destination: destination, http: http)
    }

    /// Форма ответа — из документации метода: список лежит на этаж глубже,
    /// под `result.tasks`, а поля прописными.
    private static let listJSON = """
    {"result": {"tasks": [
        {"id": "42", "ID": "42", "TITLE": "Пересчитать тарифы"},
        {"ID": "43", "TITLE": "Выкатить в биллинг"}
    ]}, "total": 2}
    """

    @Test("ключ вебхука уходит в адрес, а не в заголовок")
    func webhookTravelsInThePath() async throws {
        let (http, recorder) = stub(json: Self.listJSON)
        _ = try await client(http: http).search("тарифы")

        let request = try #require(recorder())
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://company.bitrix24.ru/rest/1/abc123/tasks.task.list")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil,
                "ключ ушёл ещё и в заголовок — у Битрикса его там быть не должно")
        #expect(request.httpMethod == "POST")
    }

    @Test("подстановочные знаки стоят в значении, как описано у вендора")
    func patternGoesIntoTheValue() async throws {
        let (http, recorder) = stub(json: Self.listJSON)
        _ = try await client(http: http).search("тарифы")

        let body = try #require(recorder()?.httpBody)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let filter = try #require(payload["filter"] as? [String: Any])
        #expect(filter["TITLE"] as? String == "%тарифы%")
        #expect(filter["%TITLE"] == nil, "приставка к имени поля для этого метода не описана")
        #expect(payload["select"] as? [String] == ["ID", "TITLE", "STATUS"])
    }

    @Test("список достаётся из result.tasks, а поля читаются прописными")
    func readsNestedUppercaseFields() async throws {
        let (http, _) = stub(json: Self.listJSON)
        let issues = try await client(http: http).search("тарифы")

        #expect(issues.map(\.key) == ["42", "43"])
        #expect(issues.map(\.title) == ["Пересчитать тарифы", "Выкатить в биллинг"])
    }

    /// Страница у Битрикса всегда пятьдесят и параметром не задаётся, поэтому
    /// граница держится уже после разбора.
    @Test("выдача урезается до запрошенного размера")
    func trimsToRequestedLimit() async throws {
        let rows = (1...60).map { "{\"ID\": \"\($0)\", \"TITLE\": \"Задача \($0)\"}" }
        let (http, _) = stub(json: "{\"result\": {\"tasks\": [\(rows.joined(separator: ","))]}}")
        let issues = try await client(http: http).search("задача", limit: 10)
        #expect(issues.count == 10)
    }

    /// Портал на кириллице — рабочий случай: Битрикс такие имена выдаёт.
    /// `URL` переводит их в punycode, и это правильно: в сеть уходит именно
    /// такой адрес. Проверка стоит здесь, чтобы «странный» хост в отладке не
    /// приняли за поломку и не начали чинить исправное.
    @Test("кириллический портал уходит в punycode, а не ломается")
    func cyrillicPortalBecomesPunycode() async throws {
        let (http, recorder) = stub(json: Self.listJSON)
        _ = try await RussianTrackers(service: .bitrix24, token: "1/abc123",
                                      secondary: "фирма.bitrix24.ru",
                                      http: http).search("тарифы")
        let url = try #require(recorder()?.url?.absoluteString)
        #expect(url.hasPrefix("https://xn--"), "адрес не собрался вовсе: \(url)")
        #expect(url.hasSuffix("/rest/1/abc123/tasks.task.list"))
    }

    @Test("задача без числового ответственного не заводится вовсе")
    func refusesNonNumericResponsible() async {
        let (http, recorder) = stub(json: "{}")
        await #expect(throws: RussianTrackers.TrackerError.notConfigured(.bitrix24)) {
            _ = try await client(http: http, destination: "Иванов")
                .createIssue(title: "Проверить", description: nil)
        }
        #expect(recorder() == nil, "запрос ушёл с подменённым ответственным")
    }
}

@Suite("Вебхук Битрикса вставляют целиком")
struct BitrixWebhookPasteTests {
    private func stub() -> (RussianTrackers.HTTP, () -> URLRequest?) {
        var last: URLRequest?
        let http: RussianTrackers.HTTP = { request in
            last = request
            return (Data("{\"result\": {\"tasks\": []}}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (http, { last })
    }

    /// Битрикс показывает вебхук одной строкой. Требовать вырезать середину и
    /// отдельно вписать портал — значит закладывать самый вероятный способ
    /// ошибиться прямо в форму.
    @Test("вставленная целиком ссылка даёт и портал, и учётную часть",
          arguments: [
            "https://company.bitrix24.ru/rest/1/abc123/",
            "https://company.bitrix24.ru/rest/1/abc123",
            "company.bitrix24.ru/rest/1/abc123/",
            // Со скопированным именем метода на конце — так тоже копируют.
            "https://company.bitrix24.ru/rest/1/abc123/tasks.task.list",
          ])
    func pastedWebhookIsSplit(pasted: String) async throws {
        let (http, recorder) = stub()
        _ = try await RussianTrackers(service: .bitrix24, token: pasted,
                                      http: http).search("тарифы")
        let url = try #require(recorder()?.url?.absoluteString)
        #expect(url == "https://company.bitrix24.ru/rest/1/abc123/tasks.task.list",
                "разбор дал: \(url)")
    }

    @Test("вписанная руками середина по-прежнему работает")
    func manualHalvesStillWork() async throws {
        let (http, recorder) = stub()
        _ = try await RussianTrackers(service: .bitrix24, token: "1/abc123",
                                      secondary: "company.bitrix24.ru",
                                      http: http).search("тарифы")
        let url = try #require(recorder()?.url?.absoluteString)
        #expect(url == "https://company.bitrix24.ru/rest/1/abc123/tasks.task.list")
    }

    /// У остальных трёх токен — обычная строка, и разбор её не касается.
    @Test("токены других сервисов не трогаются",
          arguments: [RussianTrackers.Service.yandexTracker, .kaiten, .yougile])
    func otherServicesUntouched(service: RussianTrackers.Service) {
        // Строка нарочно похожа на вебхук Битрикса. Без проверки на сервис
        // разбор откусил бы у чужого токена половину, и первая версия этой
        // проверки такого не ловила: в ней не было отрезка `rest`, поэтому
        // разбор и так возвращал исходное значение.
        let odd = "https://host.example/rest/1/abc123/"
        let parsed = RussianTrackers.splitBitrixWebhook(service: service, token: odd)
        #expect(parsed.token == odd, "чужой токен разобрали как вебхук")
        #expect(parsed.host == nil, "у чужого сервиса появился портал из токена")
    }

    @Test("не ссылка — значит середина, разбирать нечего")
    func plainCredentialsAreNotParsed() {
        let parsed = RussianTrackers.splitBitrixWebhook(service: .bitrix24, token: "1/abc123")
        #expect(parsed.token == "1/abc123")
        #expect(parsed.host == nil, "портал взялся из ниоткуда")
    }
}

@Suite("Отказ, приехавший с кодом 200")
struct VendorErrorInsideSuccessTests {
    private func client(json: String) -> RussianTrackers {
        RussianTrackers(service: .bitrix24, token: "1/abc123",
                        secondary: "company.bitrix24.ru") { request in
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Битрикс отвечает 200 и кладёт отказ в тело. Пока разбор шёл сразу к
    /// списку задач, отозванный вебхук давал пустую выдачу — то есть
    /// «в трекере ничего не нашлось» вместо «трекер нас не пустил».
    @Test("отозванный вебхук — это ошибка, а не пустая выдача")
    func revokedWebhookIsAnError() async {
        let json = """
        {"error": "INVALID_CREDENTIALS", "error_description": "Invalid request credentials"}
        """
        await #expect(throws: RussianTrackers.TrackerError.vendor(
            .bitrix24, code: "INVALID_CREDENTIALS",
            description: "Invalid request credentials")) {
            _ = try await client(json: json).search("тарифы")
        }
    }

    @Test("в тексте видно, что сказал сам сервис, и что проверить")
    func messageCarriesVendorWords() async throws {
        let json = """
        {"error": "ACCESS_DENIED", "error_description": "Method not allowed for this webhook"}
        """
        do {
            _ = try await client(json: json).search("тарифы")
            Issue.record("ожидался отказ")
        } catch let error as RussianTrackers.TrackerError {
            let text = try #require(error.errorDescription)
            #expect(text.contains("Method not allowed for this webhook"),
                    "слова сервиса потерялись: \(text)")
            #expect(text.contains("Задачи"), "не сказано, какое право проверить")
        }
    }

    /// Без описания показывается код: пустая строка сообщила бы ещё меньше.
    @Test("код показывается, если описания нет")
    func codeShownWhenDescriptionMissing() async throws {
        do {
            _ = try await client(json: "{\"error\": \"QUERY_LIMIT_EXCEEDED\"}").search("q")
            Issue.record("ожидался отказ")
        } catch let error as RussianTrackers.TrackerError {
            #expect(try #require(error.errorDescription).contains("QUERY_LIMIT_EXCEEDED"))
        }
    }

    @Test("исправный ответ по-прежнему разбирается")
    func healthyResponseStillParses() async throws {
        let json = """
        {"result": {"tasks": [{"ID": "7", "TITLE": "Проверить лимиты"}]}, "total": 1}
        """
        let issues = try await client(json: json).search("лимиты")
        #expect(issues.map(\.key) == ["7"])
    }
}
