import Foundation
import Testing
@testable import OrakulCore

/// Вопрос сервису из терминала.
///
/// Коннекторы переехали в ядро вместе со словарём — они знают только
/// Foundation. Значит, ими может пользоваться не только приложение: вопрос
/// «мы это уже заводили?» одинаково нужен и на звонке, и в терминале.
///
/// Логика живёт здесь, а не в `main.swift`, именно чтобы её можно было
/// проверить: точка входа исполняемого файла тестом не запускается.
@Suite("Вопрос сервису из терминала")
struct ConnectorQueryTests {

    private func stub(_ json: String) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            (Data(json.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        }
    }

    private let settings = ConnectorQuery.Settings(
        service: "mattermost", token: "tok", host: "chat.company.ru", scope: "team-1")

    @Test("находка печатается словами, а не структурой")
    func hitsRenderAsText() async {
        let json = #"{"order":["p1"],"posts":{"p1":{"message":"обсудили тарифы","user_id":"u1"}}}"#
        let answer = await ConnectorQuery.ask(settings, query: "тарифы",
                                              messengerHTTP: stub(json))
        #expect(answer.text.contains("Mattermost"), "не сказано, какой сервис отвечал")
        #expect(answer.text.contains("обсудили тарифы"), "сама находка потерялась")
    }

    @Test("пустая выдача — это ответ, а не сбой")
    func emptyResultIsAnAnswer() async {
        let answer = await ConnectorQuery.ask(settings, query: "корпоратив",
                                              messengerHTTP: stub(#"{"order":[],"posts":{}}"#))
        #expect(answer.text.contains("ничего не нашлось"),
                "пустая выдача выглядит как ошибка: «\(answer.text)»")
    }

    @Test("отказ сервиса объясняется по-русски")
    func refusalIsRussian() async {
        let unauthorised: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401,
                                     httpVersion: nil, headerFields: nil)!)
        }
        let answer = await ConnectorQuery.ask(settings, query: "тарифы",
                                              messengerHTTP: unauthorised)
        #expect(answer.text.contains("токен"), "не сказано, что дело в токене: «\(answer.text)»")
        #expect(!answer.text.contains("ConnectorError"), "наружу вышли внутренности")
    }

    @Test("без токена сказано, куда его положить")
    func missingTokenExplainsItself() async {
        let empty = ConnectorQuery.Settings(service: "mattermost", token: "",
                                            host: nil, scope: nil)
        let answer = await ConnectorQuery.ask(empty, query: "тарифы")
        #expect(answer.text.contains("ORAKUL_TOKEN"))
    }

    @Test("незнакомый сервис перечисляет знакомые")
    func unknownServiceListsTheKnownOnes() async {
        let wrong = ConnectorQuery.Settings(service: "нетакого", token: "tok",
                                            host: nil, scope: nil)
        let answer = await ConnectorQuery.ask(wrong, query: "тарифы")
        #expect(answer.text.contains("mattermost") && answer.text.contains("outline"),
                "не перечислены доступные сервисы: «\(answer.text)»")
    }

    @Test("список сервисов совпадает с тем, что реально есть")
    func advertisedServicesExist() {
        // Тот же разрыв, что уже ловили у `LiveConnectorProbe`: список пишется
        // руками и устаревает от первого переименования.
        let real = Set(WorkMessengers.Service.allCases.map(\.rawValue))
            .union(SelfHostedTrackers.Service.allCases.map(\.rawValue))
            .union(TeamNotes.Service.allCases.map(\.rawValue))
            .union(RussianTrackers.Service.allCases.map(\.rawValue))
            .union(["github"])
        #expect(Set(ConnectorQuery.services) == real,
                "список в подсказке разошёлся с коннекторами")
    }

    @Test("российские трекеры стоят в начале списка")
    func russianTrackersComeFirst() {
        // Продукт делается для российской команды: сервис, ради которого сюда
        // пришли, не должен стоять десятым.
        let head = Set(ConnectorQuery.services.prefix(RussianTrackers.Service.allCases.count))
        #expect(head == Set(RussianTrackers.Service.allCases.map(\.rawValue)),
                "порядок: \(ConnectorQuery.services)")
    }

    // MARK: - Российские трекеры

    @Test("Яндекс Трекер отвечает задачами, а не структурой")
    func yandexTrackerRendersIssues() async {
        let settings = ConnectorQuery.Settings(service: "yandexTracker", token: "tok",
                                               host: "org-42", scope: nil)
        let json = #"[{"key": "TRACK-7", "summary": "Поднять лимиты выгрузки"}]"#
        let answer = await ConnectorQuery.ask(settings, query: "лимиты",
                                              trackerRUHTTP: stub(json))
        #expect(answer.text.contains("Яндекс Трекер"), "не сказано, кто отвечал: «\(answer.text)»")
        #expect(answer.text.contains("TRACK-7"), "ключ задачи потерян — по нему её и ищут")
        #expect(answer.text.contains("Поднять лимиты выгрузки"))
    }

    @Test("без организации сказано, чего не хватает, и запрос не уходит")
    func missingSecondaryIsNamedBeforeTheRequest() async {
        // Раньше это был 403 от Яндекса: по нему не видно, что не хватало
        // именно X-Org-ID, а не прав токена.
        let settings = ConnectorQuery.Settings(service: "yandexTracker", token: "tok",
                                               host: nil, scope: nil)
        let calls = Counter()
        let answer = await ConnectorQuery.ask(settings, query: "лимиты",
                                              trackerRUHTTP: { request in
            await calls.bump()
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil)!)
        })
        #expect(answer.text.contains("организации"), "не названо, чего не хватает: «\(answer.text)»")
        #expect(answer.text.contains("ORAKUL_HOST"), "не сказано, куда это положить")
        #expect(await calls.value == 0, "запрос ушёл, хотя отправлять было нечего")
    }

    @Test("YouGile второго поля не требует")
    func yougileNeedsNoSecondary() async {
        // Обратная сторона предыдущей проверки: если спрашивать организацию у
        // всех подряд, рабочий сервис перестанет отвечать вовсе.
        let settings = ConnectorQuery.Settings(service: "yougile", token: "tok",
                                               host: nil, scope: nil)
        let answer = await ConnectorQuery.ask(
            settings, query: "лимиты",
            trackerRUHTTP: stub(#"[{"key": "YG-3", "summary": "Готово"}]"#))
        #expect(answer.text.contains("YG-3"), "YouGile попросил лишнего: «\(answer.text)»")
    }

    // MARK: - GitHub

    @Test("GitHub показывает состояние задачи, а не только заголовок")
    func githubKeepsIssueState() async {
        // Закрытая задача меняет смысл находки на противоположный: «это уже
        // обсуждали и закрыли» — не то же, что «это открыто и висит».
        let settings = ConnectorQuery.Settings(service: "github", token: "ghp_x",
                                               host: nil, scope: "myteam/backend")
        let json = """
        {"total_count": 1, "items": [
          {"number": 42, "title": "Поднять лимиты", "state": "closed",
           "html_url": "https://github.com/myteam/backend/issues/42"}]}
        """
        let answer = await ConnectorQuery.ask(settings, query: "лимиты", githubHTTP: stub(json))
        #expect(answer.text.contains("myteam/backend#42"), "по ключу задачу должно быть видно")
        #expect(answer.text.contains("closed"), "состояние потеряно: «\(answer.text)»")
    }

    @Test("без списка репозиториев запрос не уходит по всему GitHub")
    func githubWithoutRepositoriesRefuses() async {
        let settings = ConnectorQuery.Settings(service: "github", token: "ghp_x",
                                               host: nil, scope: nil)
        let calls = Counter()
        let answer = await ConnectorQuery.ask(settings, query: "лимиты", githubHTTP: { request in
            await calls.bump()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                            httpVersion: nil, headerFields: nil)!)
        })
        #expect(answer.text.contains("ORAKUL_SCOPE"), "не сказано, куда класть репозитории")
        #expect(await calls.value == 0, "поиск ушёл по всему GitHub — вернулись бы чужие задачи")
    }

    @Test("пустой и мусорный ORAKUL_SCOPE — это отсутствие репозиториев")
    func githubIgnoresBlankRepositoryEntries() async {
        // `,,` и пробелы получаются сами собой, когда список правят руками.
        let settings = ConnectorQuery.Settings(service: "github", token: "ghp_x",
                                               host: nil, scope: " , ,, ")
        let answer = await ConnectorQuery.ask(settings, query: "лимиты")
        #expect(answer.text.contains("ORAKUL_SCOPE"), "пустой список сошёл за настоящий: «\(answer.text)»")
    }
}

/// Счётчик обращений к сети. Замыкание `Sendable`, поэтому актор.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Что видит и что получает оболочка.
///
/// Оба случая найдены не чтением кода, а запуском собранной команды: `orakul
/// спросить kaiten` с недоступным адресом ответил «Could not connect to the
/// server.» и завершился нулём. Ни то, ни другое ни один тест выше не ловил —
/// они все ходят через подставной HTTP и смотрят только на текст.
@Suite("Отказ в терминале")
struct ConnectorQueryFailureTests {

    private func failing(_ code: URLError.Code, host: String) -> ConnectorQuery.Settings {
        ConnectorQuery.Settings(service: "kaiten", token: "tok", host: host, scope: nil)
    }

    private func thrower(_ code: URLError.Code, url: String)
        -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { _ in throw URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: url)!]) }
    }

    @Test("сеть не отвечает — объяснение по-русски, а не системной строкой",
          arguments: [URLError.Code.cannotConnectToHost, .cannotFindHost,
                      .dnsLookupFailed, .timedOut, .notConnectedToInternet])
    func transportFailuresSpeakRussian(code: URLError.Code) async {
        let answer = await ConnectorQuery.ask(
            failing(code, host: "team.kaiten.ru"), query: "лимиты",
            trackerRUHTTP: thrower(code, url: "https://team.kaiten.ru/api/latest"))

        // Кириллица обязана быть: `localizedDescription` у URLError приходит
        // на языке системы, и на английской macOS это ровно та строка, из-за
        // которой всё это и написано.
        #expect(answer.text.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil,
                "ответ не по-русски: «\(answer.text)»")
        #expect(!answer.text.contains("Could not connect"),
                "наружу вышла системная строка: «\(answer.text)»")
        #expect(answer.failed, "сбой сети выдан за успех")
    }

    @Test("в сообщении назван адрес, по которому не достучались")
    func failureNamesTheHost() async {
        let answer = await ConnectorQuery.ask(
            failing(.cannotConnectToHost, host: "team.kaiten.ru"), query: "лимиты",
            trackerRUHTTP: thrower(.cannotConnectToHost, url: "https://team.kaiten.ru/api/latest"))
        #expect(answer.text.contains("team.kaiten.ru"),
                "по какому адресу не прошло — не сказано: «\(answer.text)»")
        #expect(answer.text.contains("ORAKUL_HOST"), "не сказано, где исправить адрес")
    }

    @Test("каждый отказ поднимает код возврата, а находка — нет")
    func failuresRaiseTheExitStatus() async {
        // Ради `orakul спросить … && развернуть`: раньше здесь всегда стоял
        // ноль, и цепочка продолжалась после «нет токена».
        let noToken = ConnectorQuery.Settings(service: "kaiten", token: "",
                                              host: "team.kaiten.ru", scope: nil)
        #expect(await ConnectorQuery.ask(noToken, query: "лимиты").failed)

        let unknown = ConnectorQuery.Settings(service: "нетакого", token: "tok",
                                              host: nil, scope: nil)
        #expect(await ConnectorQuery.ask(unknown, query: "лимиты").failed)

        let blank = ConnectorQuery.Settings(service: "kaiten", token: "tok",
                                            host: "team.kaiten.ru", scope: nil)
        #expect(await ConnectorQuery.ask(blank, query: "   ").failed, "пустой вопрос — тоже отказ")
    }

    @Test("пустая выдача кодом возврата не считается сбоем")
    func emptyResultIsNotAFailure() async {
        // Граница нужна именно здесь: если считать «ничего не нашлось» сбоем,
        // любой скрипт с `&&` будет вставать на нормальном пустом ответе.
        let settings = ConnectorQuery.Settings(service: "kaiten", token: "tok",
                                               host: "team.kaiten.ru", scope: nil)
        let answer = await ConnectorQuery.ask(settings, query: "лимиты",
                                              trackerRUHTTP: { request in
            (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
        })
        #expect(answer.text.contains("ничего не нашлось"))
        #expect(!answer.failed, "пустой ответ выдан за сбой — скрипты встанут на ровном месте")
    }

    /// Порядок проверок — это порядок, в котором человек узнаёт о своих
    /// ошибках. Опечатка в имени сервиса раньше давала «нет токена»: человек
    /// шёл заводить токен для сервиса, которого нет.
    @Test("опечатка в имени сервиса называется опечаткой, а не отсутствием токена")
    func unknownServiceBeatsMissingToken() async {
        let answer = await ConnectorQuery.ask(
            .init(service: "нетакого", token: "", host: nil, scope: nil),
            query: "лимиты")
        #expect(answer.failed)
        #expect(answer.text.contains("Не знаю сервис «нетакого»"))
        #expect(!answer.text.contains("Нет токена"), "продукт послал заводить токен впустую")
        // И список настоящих сервисов рядом — иначе непонятно, что печатать.
        #expect(answer.text.contains("kaiten"))
    }

    @Test("у настоящего сервиса без токена сообщение прежнее")
    func knownServiceStillAsksForToken() async {
        let answer = await ConnectorQuery.ask(
            .init(service: "kaiten", token: "", host: nil, scope: nil),
            query: "лимиты")
        #expect(answer.failed)
        #expect(answer.text.contains("Нет токена"))
    }

    @Test("пустой вопрос важнее незнакомого сервиса — спрашивать нечего в любом случае")
    func emptyQuestionComesFirst() async {
        let answer = await ConnectorQuery.ask(
            .init(service: "нетакого", token: "", host: nil, scope: nil), query: "   ")
        #expect(answer.text.contains("Пустой вопрос"))
    }

    /// Два отказа TLS выглядят похоже, а чинятся по-разному, и раньше о них
    /// сообщалось одной фразой про недоверенный сертификат. Внутренние серверы
    /// часто стоят на http — такому человеку совет «поправьте сертификат»
    /// отправлял чинить то, чего нет. Коды проверены на живых серверах:
    /// сервер без TLS даёт -1200, самоподписанный — -1202.
    @Test("сервер без TLS и недоверенный сертификат объясняются по-разному")
    func tlsFailuresAreToldApart() async {
        let http = await ConnectorQuery.ask(
            .init(service: "kaiten", token: "t", host: "127.0.0.1:1", scope: nil),
            query: "лимиты",
            trackerRUHTTP: { _ in throw URLError(.secureConnectionFailed) })
        #expect(http.failed)
        #expect(http.text.contains("не принял защищённое соединение"))
        #expect(http.text.contains("http, а не https"), "не сказано, что проверить")
        #expect(!http.text.contains("сертификат"), "снова про сертификат: \(http.text)")

        let cert = await ConnectorQuery.ask(
            .init(service: "kaiten", token: "t", host: "127.0.0.1:1", scope: nil),
            query: "лимиты",
            trackerRUHTTP: { _ in throw URLError(.serverCertificateUntrusted) })
        #expect(cert.failed)
        #expect(cert.text.contains("которому система не доверяет"))
        #expect(cert.text.contains("Связку ключей"), "не сказано, что делать")
    }

    /// Просроченный и с чужим корнем — тот же случай для человека.
    @Test("остальные беды с сертификатом объясняются так же",
          arguments: [URLError.Code.serverCertificateHasBadDate,
                      .serverCertificateNotYetValid,
                      .serverCertificateHasUnknownRoot])
    func certificateVariantsShareTheMessage(code: URLError.Code) async {
        let answer = await ConnectorQuery.ask(
            .init(service: "kaiten", token: "t", host: "127.0.0.1:1", scope: nil),
            query: "лимиты",
            trackerRUHTTP: { _ in throw URLError(code) })
        #expect(answer.failed)
        #expect(answer.text.contains("которому система не доверяет"), "\(code): \(answer.text)")
    }
}
