import Foundation
import Testing
@testable import OrakulCore

/// Заведение задачи — единственная запись, которую продукт делает в чужой
/// сервис. Ошибиться здесь дороже, чем в поиске: пустая выдача поправима
/// повтором, а «завели» вместо «не завели» человек узнаёт не сразу и уже после
/// звонка. Покрытие этого пути было нулевым — проверялся только поиск.
@Suite("Российские трекеры: заведение задачи")
struct RussianTrackerCreateTests {

    private func stub(status: Int = 200, json: String) -> (RussianTrackers.HTTP, Recorder) {
        let recorder = Recorder()
        let http: RussianTrackers.HTTP = { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        return (http, recorder)
    }

    private func secondary(for service: RussianTrackers.Service) -> String? {
        switch service {
        case .yandexTracker: return "1234567"
        case .kaiten:        return "team.kaiten.ru"
        case .bitrix24:      return "company.bitrix24.ru"
        case .yougile:       return nil
        }
    }

    /// Третье поле значит у каждого своё, и у двух оно обязано быть числом.
    private func destination(for service: RussianTrackers.Service) -> String {
        switch service {
        case .yandexTracker: return "TREK"
        case .kaiten:        return "4"
        case .yougile:       return "col-77"
        case .bitrix24:      return "1"
        }
    }

    private func client(_ service: RussianTrackers.Service,
                        destination: String? = nil,
                        http: @escaping RussianTrackers.HTTP) -> RussianTrackers {
        RussianTrackers(service: service, token: "t0ken",
                        secondary: secondary(for: service),
                        destination: destination ?? self.destination(for: service),
                        http: http)
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data, "запрос ушёл без тела")
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any],
                            "тело запроса — не объект JSON")
    }

    /// `#expect(throws: значение)` ловит «ошибка не брошена», но не «брошена
    /// не та»: с ним мутация «убрать ветку 401» проходила зелёной, потому что
    /// вместо `.unauthorised` летело `.http(401)` и проверка этого не замечала.
    /// Поэтому ошибка ловится руками и сравнивается.
    private func expectError(_ expected: RussianTrackers.TrackerError,
                             sourceLocation: SourceLocation = #_sourceLocation,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("ошибка не брошена вовсе, ждали \(expected)",
                         sourceLocation: sourceLocation)
        } catch let error as RussianTrackers.TrackerError {
            #expect(error == expected, "брошено \(error), ждали \(expected)",
                    sourceLocation: sourceLocation)
        } catch {
            Issue.record("брошена чужая ошибка: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("каждый сервис пишет по своему адресу и методом POST",
          arguments: RussianTrackers.Service.allCases)
    func endpointPerService(service: RussianTrackers.Service) async throws {
        let (http, recorder) = stub(json: #"{"id": 42, "title": "Выкатить биллинг"}"#)
        _ = try await client(service, http: http)
            .createIssue(title: "Выкатить биллинг")

        let request = try #require(recorder.last)
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url?.absoluteString)
        switch service {
        case .yandexTracker: #expect(url == "https://api.tracker.yandex.net/v3/issues/")
        case .kaiten:        #expect(url == "https://team.kaiten.ru/api/latest/cards")
        case .yougile:       #expect(url == "https://yougile.com/api-v2/tasks")
        case .bitrix24:      #expect(url == "https://company.bitrix24.ru/rest/t0ken/tasks.task.add")
        }
    }

    /// Поля именно те, что требует вендор. Если переименовать хоть одно, сервис
    /// ответит 400 посреди звонка — а по-русски об этом никто не расскажет.
    @Test("тело запроса собрано по документации вендора")
    func bodyShape() async throws {
        let (http, recorder) = stub(json: #"{"id": 1}"#)

        _ = try await client(.yandexTracker, http: http)
            .createIssue(title: "Выкатить биллинг", description: "к пятнице")
        var body = try json(recorder.last?.httpBody)
        #expect(body["summary"] as? String == "Выкатить биллинг")
        #expect(body["queue"] as? String == "TREK")
        #expect(body["description"] as? String == "к пятнице")

        _ = try await client(.kaiten, http: http).createIssue(title: "Выкатить биллинг")
        body = try json(recorder.last?.httpBody)
        #expect(body["title"] as? String == "Выкатить биллинг")
        #expect(body["board_id"] as? Int == 4, "номер доски обязан уйти числом, а не строкой")
        #expect(body["description"] == nil, "пустое описание не выдумывается")

        // Пустое описание не выдумывается ни у кого: пустая строка в трекере
        // выглядит как описание, которое кто-то стёр.
        _ = try await client(.yandexTracker, http: http).createIssue(title: "Без описания")
        #expect(try json(recorder.last?.httpBody)["description"] == nil)

        _ = try await client(.yougile, http: http).createIssue(title: "Выкатить биллинг",
                                                               description: "к пятнице")
        body = try json(recorder.last?.httpBody)
        #expect(body["columnId"] as? String == "col-77")
        #expect(body["description"] as? String == "к пятнице")

        _ = try await client(.yougile, http: http).createIssue(title: "Без описания")
        #expect(try json(recorder.last?.httpBody)["description"] == nil)

        _ = try await client(.bitrix24, http: http).createIssue(title: "Без описания")
        let bare = try #require(try json(recorder.last?.httpBody)["fields"] as? [String: Any])
        #expect(bare["DESCRIPTION"] == nil)

        _ = try await client(.bitrix24, http: http).createIssue(title: "Выкатить биллинг")
        body = try json(recorder.last?.httpBody)
        let fields = try #require(body["fields"] as? [String: Any], "Битрикс ждёт вложенный fields")
        #expect(fields["TITLE"] as? String == "Выкатить биллинг")
        #expect(fields["RESPONSIBLE_ID"] as? Int == 1, "ответственный обязан уйти числом")
    }

    /// Главное здесь. Поле доски в настройках — обычная строка с подсказкой
    /// «номер доски, например 4», и человек вписывает туда НАЗВАНИЕ доски.
    /// Подстановка нуля вместо непонятного значения завела бы карточку не там,
    /// где её ждут, и человек узнал бы об этом не сразу.
    @Test("нечисловое место назначения — отказ, а не подстановка нуля",
          arguments: [RussianTrackers.Service.kaiten, .bitrix24])
    func nonNumericDestinationRefuses(service: RussianTrackers.Service) async throws {
        var reached = false
        let http: RussianTrackers.HTTP = { request in
            reached = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id": 1}"#.utf8), response)
        }
        await expectError(.notConfigured(service)) {
            _ = try await self.client(service, destination: "Разработка", http: http)
                .createIssue(title: "Выкатить биллинг")
        }
        #expect(!reached, "запрос всё-таки ушёл — значит доска подменена молча")
    }

    @Test("без токена, без места и без названия запрос не уходит",
          arguments: ["токен", "место", "название"])
    func refusesIncompleteSetup(missing: String) async throws {
        var reached = false
        let http: RussianTrackers.HTTP = { request in
            reached = true
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        let tracker = RussianTrackers(
            service: .yandexTracker,
            token: missing == "токен" ? "" : "t0ken",
            secondary: "1234567",
            destination: missing == "место" ? "" : "TREK",
            http: http)
        await expectError(.notConfigured(.yandexTracker)) {
            _ = try await tracker.createIssue(title: missing == "название" ? "   " : "Задача")
        }
        #expect(!reached, "сеть тронули, хотя настройка неполная")
    }

    @Test("чужой код ответа превращается в свою ошибку, а не в успех",
          arguments: [(401, "unauthorised"), (403, "unauthorised"),
                      (404, "http"), (500, "http")])
    func statusMapping(status: Int, kind: String) async throws {
        let (http, _) = stub(status: status, json: #"{"id": 1}"#)
        let expected: RussianTrackers.TrackerError = kind == "unauthorised"
            ? .unauthorised(.kaiten)
            : .http(.kaiten, status)
        await expectError(expected) {
            _ = try await self.client(.kaiten, http: http).createIssue(title: "Задача")
        }
    }

    /// Ответ 200 с телом, из которого не следует заведённая задача, — не успех.
    /// Здесь нет мягкого разбора: сказать «завёл» без ключа задачи нельзя.
    @Test("непонятный ответ при 200 — ошибка, а не пустая задача",
          arguments: ["не json вовсе", "{}", #"{"id": ""}"#, "[]"])
    func unreadableResponse(json body: String) async throws {
        let (http, _) = stub(json: body)
        await expectError(.unreadable(.yougile)) {
            _ = try await self.client(.yougile, http: http).createIssue(title: "Задача")
        }
    }

    @Test("из ответа берутся ключ, название и ссылка на задачу")
    func parsesCreated() async throws {
        let (yandex, _) = stub(json: #"{"key": "TREK-42", "summary": "Выкатить биллинг"}"#)
        let created = try await client(.yandexTracker, http: yandex).createIssue(title: "Задача")
        #expect(created == RussianTrackers.Issue(
            key: "TREK-42", title: "Выкатить биллинг",
            url: URL(string: "https://tracker.yandex.ru/TREK-42")))

        // У остальных ключ числовой, и ссылка собирается из хоста команды.
        let (kaiten, _) = stub(json: #"{"id": 77, "title": "Карточка"}"#)
        let card = try await client(.kaiten, http: kaiten).createIssue(title: "Задача")
        #expect(card.key == "77")
        #expect(card.url == URL(string: "https://team.kaiten.ru/ticket/77"))

        // Ссылка от самого сервиса важнее собранной нами.
        let (own, _) = stub(json: #"{"id": 5, "url": "https://team.kaiten.ru/space/1/card/5"}"#)
        let byVendor = try await client(.kaiten, http: own).createIssue(title: "Задача")
        #expect(byVendor.url == URL(string: "https://team.kaiten.ru/space/1/card/5"))

        // YouGile ссылку на задачу не отдаёт и собрать её неоткуда: nil честнее
        // выдуманного адреса, который откроет не то.
        let (yougile, _) = stub(json: #"{"id": "abc-1"}"#)
        #expect(try await client(.yougile, http: yougile).createIssue(title: "Задача").url == nil)
    }

    /// Ровно то, что человек читает, когда трекер отказал. Без этого наружу
    /// шло «The operation couldn't be completed» — по-английски и без имени
    /// сервиса, а подключённых может быть четыре.
    @Test("отказ объясняется по-русски и называет сервис")
    func errorsSpeakRussian() throws {
        let cases: [(RussianTrackers.TrackerError, [String])] = [
            (.notConfigured(.kaiten), ["Kaiten", "не подключён", "Настройки"]),
            (.unauthorised(.yandexTracker), ["Яндекс Трекер", "не принял токен", "истёк"]),
            (.http(.yougile, 404), ["YouGile", "404", "404 — проверьте"]),
            (.unreadable(.bitrix24), ["Битрикс24", "разобрать"]),
            (.vendor(.bitrix24, code: "ERROR_CORE", description: "нет права «Задачи»"),
             ["Битрикс24", "нет права «Задачи»", "вебхук"]),
        ]
        for (error, expected) in cases {
            let text = try #require(error.errorDescription)
            for fragment in expected {
                #expect(text.contains(fragment),
                        "в «\(text)» нет «\(fragment)»")
            }
            #expect(!text.contains("MeetGPT"), "наружу вылезло внутреннее имя типа")
            #expect(text.range(of: "[a-zA-Z]{6,}", options: .regularExpression) == nil
                    || text.contains("Kaiten") || text.contains("YouGile"),
                    "в сообщении осталось длинное английское слово: \(text)")
        }
    }
}
