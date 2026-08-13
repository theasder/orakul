import Foundation
import Testing
@testable import OrakulCore

/// Что коннектор говорит, когда сервер ответил ошибкой.
///
/// Найдено настоящим круговым рейсом: локальный сервер, отвечающий как
/// сломанный обратный прокси (502 и страница HTML вместо JSON), — и `orakul
/// спросить gitlab` сообщил: «Трекер ответил непонятным образом. Если у вас
/// свой сервер, проверьте адрес и версию».
///
/// Адрес проверить и правда стоит, а версия тут ни при чём: сервер жив и
/// внятно сказал 502. Для брифа это ровно целевой случай — «popular on-premise
/// solutions», то есть GitLab и Redmine за корпоративным прокси, где 502 и 504
/// самый обычный отказ.
///
/// Три коннектора разбирали только 401 и 403, а всё остальное проваливалось в
/// разбор JSON и выходило наружу как «непонятный ответ». `RussianTrackers` и
/// `GitHubConnector` с самого начала делают правильно — образец брался с них.
@Suite("Ошибка сервера у коннекторов")
struct ConnectorHTTPStatusTests {

    private func responding(_ status: Int)
        -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            // Тело намеренно не JSON: сломанный прокси отдаёт страницу HTML,
            // и именно поэтому прежний код объявлял ответ неразборчивым.
            (Data("<html><title>\(status)</title></html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("самоподнятый трекер называет код ответа", arguments: [500, 502, 504, 404])
    func selfHostedTrackerNamesTheStatus(status: Int) async {
        let client = SelfHostedTrackers(service: .gitlab, token: "tok",
                                        host: "http://gitlab.internal",
                                        http: responding(status))
        await #expect(throws: SelfHostedTrackers.ConnectorError.http(status)) {
            _ = try await client.search("лимиты")
        }
    }

    @Test("база знаний называет код ответа")
    func notesNameTheStatus() async {
        let client = TeamNotes(service: .outline, token: "tok",
                               host: "http://wiki.internal", http: responding(503))
        await #expect(throws: TeamNotes.ConnectorError.http(503)) {
            _ = try await client.search("лимиты")
        }
    }

    @Test("мессенджер называет код ответа")
    func messengerNamesTheStatus() async {
        let client = WorkMessengers(service: .mattermost, token: "tok",
                                    secondary: "http://chat.internal", scope: "team",
                                    http: responding(502))
        await #expect(throws: WorkMessengers.ConnectorError.http(502)) {
            _ = try await client.search("лимиты")
        }
    }

    @Test("401 и 403 по-прежнему про токен, а не про код")
    func authorisationStillReadsAsAToken() async {
        // Граница: если свалить всё в один случай, пропадёт единственное
        // сообщение, по которому человек понимает, что дело в токене.
        for status in [401, 403] {
            let client = SelfHostedTrackers(service: .redmine, token: "tok",
                                            host: "http://redmine.internal",
                                            http: responding(status))
            await #expect(throws: SelfHostedTrackers.ConnectorError.unauthorised) {
                _ = try await client.search("лимиты")
            }
        }
    }

    @Test("текст ошибки называет число и не советует проверять версию")
    func theMessageNamesTheNumber() {
        // Сообщение читает человек, а не программа. «Проверьте версию» на 502
        // отправляет его не туда: сервер жив и внятно ответил.
        let messages = [
            SelfHostedTrackers.ConnectorError.http(502).errorDescription,
            TeamNotes.ConnectorError.http(502).errorDescription,
            WorkMessengers.ConnectorError.http(502).errorDescription,
        ]
        for message in messages {
            let text = message ?? ""
            #expect(text.contains("502"), "код ответа не назван: «\(text)»")
            #expect(!text.contains("версию"),
                    "совет проверить версию остался там, где сервер просто ответил ошибкой")
            #expect(text.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil,
                    "сообщение не по-русски: «\(text)»")
        }
    }

    @Test("неразборчивый ответ с кодом 200 остаётся неразборчивым")
    func twoHundredWithGarbageIsStillUnreadable() async {
        // Второй край: сервер ответил 200 и мусором — это действительно
        // «не удалось разобрать», и та ветка обязана уцелеть.
        let garbage: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            (Data("<html>не json</html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        }
        let client = SelfHostedTrackers(service: .gitea, token: "tok",
                                        host: "http://git.internal", http: garbage)
        await #expect(throws: SelfHostedTrackers.ConnectorError.unreadable) {
            _ = try await client.search("лимиты")
        }
    }

    @Test("состояние не выдумывается, когда сервис его не сообщил")
    func absentStateIsOmittedNotInvented() async {
        // Поиск Redmine состояния не возвращает вовсе. Раньше строка выходила
        // как «[#314, unknown]» — будто это человеку что-то неизвестно.
        let redmine: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let json = #"{"results": [{"id": 314, "title": "Обновить постгрес"}], "total_count": 1}"#
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let settings = ConnectorQuery.Settings(service: "redmine", token: "tok",
                                               host: "http://redmine.internal", scope: nil)
        let answer = await ConnectorQuery.ask(settings, query: "постгрес", trackerHTTP: redmine)

        #expect(answer.text.contains("[#314]"), "ключ потерян: «\(answer.text)»")
        #expect(!answer.text.contains("unknown"),
                "состояние выдумано: «\(answer.text)»")
        #expect(answer.text.contains("Обновить постгрес"))
    }

    @Test("сообщённое состояние по-прежнему показывается")
    func reportedStateStillShows() async {
        // Граница: у GitLab и Gitea состояние есть, и «закрыто» меняет смысл
        // находки на противоположный — терять его нельзя.
        let gitlab: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let json = #"[{"iid": 42, "title": "Поднять лимиты", "state": "closed"}]"#
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let settings = ConnectorQuery.Settings(service: "gitlab", token: "tok",
                                               host: "http://gitlab.internal", scope: nil)
        let answer = await ConnectorQuery.ask(settings, query: "лимиты", trackerHTTP: gitlab)
        #expect(answer.text.contains("[#42, closed]"), "состояние потеряно: «\(answer.text)»")
    }
}
