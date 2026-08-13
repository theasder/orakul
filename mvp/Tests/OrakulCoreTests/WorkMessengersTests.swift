import Foundation
import Testing
@testable import OrakulCore

/// Поиск по рабочим мессенджерам.
///
/// Форма каждого запроса сверена с документацией вендора 2026-08-12. Она
/// закреплена здесь, потому что по тексту ошибки её не восстановить:
/// Rocket.Chat на запрос без `roomId` отвечает не «укажите комнату», а пустым
/// списком, и это неотличимо от «ничего не нашлось».
@Suite("Рабочие мессенджеры")
struct WorkMessengersTests {

    private func stub(status: Int = 200, json: String)
        -> (WorkMessengers.HTTP, Recorder) {
        let recorder = Recorder()
        let http: WorkMessengers.HTTP = { request in
            recorder.record(request)
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (http, recorder)
    }

    // MARK: - Пачка

    private static let pachcaJSON = """
    {"data": [{"id": 1, "chat_id": 7, "content": "Про тарифы решили в пятницу",
               "user_id": 42, "created_at": "2026-08-12T10:00:00Z"}],
     "meta": {"count": 1}}
    """

    @Test("Пачка ищет по всем чатам и кладёт токен в заголовок")
    func pachcaSearchesEverywhere() async throws {
        let (http, recorder) = stub(json: Self.pachcaJSON)
        let hits = try await WorkMessengers(service: .pachca, token: "tok-synthetic",
                                            http: http).search("тарифы")

        let url = try #require(recorder.last?.url?.absoluteString)
        #expect(url.hasPrefix("https://api.pachca.com/api/shared/v1/search/messages"))
        #expect(url.contains("query="))
        #expect(recorder.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer tok-synthetic")
        // Адрес сервера у Пачки не спрашивается: облако одно.
        #expect(WorkMessengers.Service.pachca.secondaryPrompt == nil)
        #expect(hits.map(\.text) == ["Про тарифы решили в пятницу"])
        #expect(hits.first?.author == "42")
    }

    // MARK: - Mattermost

    private static let mattermostJSON = """
    {"order": ["p2", "p1"],
     "posts": {"p1": {"message": "первое", "user_id": "u1"},
               "p2": {"message": "второе", "user_id": "u2"}}}
    """

    @Test("Mattermost ищет по команде, и это И, а не ИЛИ")
    func mattermostSearchesTheTeam() async throws {
        let (http, recorder) = stub(json: Self.mattermostJSON)
        _ = try await WorkMessengers(service: .mattermost, token: "tok-synthetic",
                                     secondary: "chat.company.ru", scope: "team-1",
                                     http: http).search("тарифы")

        let request = try #require(recorder.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
                == "https://chat.company.ru/api/v4/teams/team-1/posts/search")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["terms"] as? String == "тарифы")
        // ИЛИ вернуло бы сообщения, где совпало одно случайное слово.
        #expect(json["is_or_search"] as? Bool == false)
    }

    @Test("порядок берётся из order, а не из словаря")
    func mattermostKeepsServerOrder() async throws {
        // `posts` — словарь, его порядок не определён. Без `order` выдача
        // приходила бы каждый раз в новом порядке.
        let (http, _) = stub(json: Self.mattermostJSON)
        let hits = try await WorkMessengers(service: .mattermost, token: "t",
                                            secondary: "chat.company.ru", scope: "team-1",
                                            http: http).search("q")
        #expect(hits.map(\.text) == ["второе", "первое"])
    }

    // MARK: - Rocket.Chat

    private static let rocketJSON = """
    {"messages": [{"_id": "m1", "msg": "обсуждали в среду",
                   "u": {"username": "polina"}}], "success": true}
    """

    @Test("Rocket.Chat ищет в комнате и шлёт оба значения")
    func rocketChatNeedsRoomAndTwoHeaders() async throws {
        let (http, recorder) = stub(json: Self.rocketJSON)
        let hits = try await WorkMessengers(service: .rocketChat,
                                            token: "tok-synthetic:user-1",
                                            secondary: "chat.company.ru",
                                            scope: "room-9", http: http).search("тарифы")

        let request = try #require(recorder.last)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://chat.company.ru/api/v1/chat.search"))
        #expect(url.contains("roomId=room-9"))
        #expect(url.contains("searchText="))
        // Одного токена мало — сервису нужен ещё идентификатор пользователя.
        #expect(request.value(forHTTPHeaderField: "X-Auth-Token") == "tok-synthetic")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == "user-1")
        #expect(hits.first?.author == "polina")
        #expect(hits.first?.text == "обсуждали в среду")
    }

    // MARK: - Zulip

    private static let zulipJSON = """
    {"messages": [{"id": 5, "content": "решили в четверг",
                   "sender_full_name": "Полина"}], "result": "success"}
    """

    @Test("Zulip ищет через сужение и авторизуется по Basic")
    func zulipSearchesWithNarrow() async throws {
        let (http, recorder) = stub(json: Self.zulipJSON)
        let hits = try await WorkMessengers(service: .zulip,
                                            token: "me@company.ru:key-synthetic",
                                            secondary: "zulip.company.ru",
                                            http: http).search("тарифы")

        let request = try #require(recorder.last)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://zulip.company.ru/api/v1/messages"))
        // Оператор `search` — это и есть полнотекстовый поиск по содержимому.
        let decoded = try #require(request.url?.query?.removingPercentEncoding)
        #expect(decoded.contains(#"{"operator":"search","operand":"тарифы"}"#))
        #expect(decoded.contains("anchor=newest"))

        // Basic: почта и ключ через двоеточие, как требует Zulip.
        let expected = Data("me@company.ru:key-synthetic".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
        #expect(hits.first?.text == "решили в четверг")
        #expect(hits.first?.author == "Полина")
    }

    // MARK: - Matrix

    private static let matrixJSON = """
    {"search_categories": {"room_events": {"count": 1, "results": [
       {"result": {"sender": "@polina:company.ru",
                   "content": {"body": "решили не трогать годовой", "msgtype": "m.text"}}}
     ]}}}
    """

    @Test("Matrix ищет по событиям комнат и просит свежие сверху")
    func matrixSearchesRoomEvents() async throws {
        let (http, recorder) = stub(json: Self.matrixJSON)
        let hits = try await WorkMessengers(service: .matrix, token: "tok-synthetic",
                                            secondary: "matrix.company.ru",
                                            http: http).search("тарифы")

        let request = try #require(recorder.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
                == "https://matrix.company.ru/_matrix/client/v3/search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-synthetic")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let categories = try #require(json["search_categories"] as? [String: Any])
        let events = try #require(categories["room_events"] as? [String: Any])
        #expect(events["search_term"] as? String == "тарифы")
        // На звонке важнее «когда решили», чем «где слово встретилось чаще».
        #expect(events["order_by"] as? String == "recent")

        // Вложенность ответа родная для Matrix, и разбор «как у всех» вернул бы
        // пустоту, неотличимую от «не обсуждали».
        #expect(hits.first?.text == "решили не трогать годовой")
        #expect(hits.first?.author == "@polina:company.ru")
    }

    // MARK: - Общее

    @Test("без обязательного поля запрос не уходит",
          arguments: [WorkMessengers.Service.mattermost, .rocketChat])
    func incompleteSetupNeverCallsOut(service: WorkMessengers.Service) async {
        let (http, recorder) = stub(json: "{}")
        // Нет адреса сервера.
        await #expect(throws: WorkMessengers.ConnectorError.notConfigured) {
            try await WorkMessengers(service: service, token: "t", scope: "x",
                                     http: http).search("q")
        }
        // Нет места поиска — команды или комнаты.
        await #expect(throws: WorkMessengers.ConnectorError.notConfigured) {
            try await WorkMessengers(service: service, token: "t",
                                     secondary: "chat.company.ru", http: http).search("q")
        }
        #expect(recorder.count == 0, "ушёл запрос при неполной настройке")
    }

    @Test("401 и 403 читаются как неподходящий токен")
    func unauthorisedIsRecognised() async {
        for status in [401, 403] {
            let (http, _) = stub(status: status, json: "{}")
            await #expect(throws: WorkMessengers.ConnectorError.unauthorised) {
                try await WorkMessengers(service: .pachca, token: "t", http: http).search("q")
            }
        }
    }

    @Test("ошибка сервиса не выдаётся за пустую выдачу")
    func errorBodyIsNotAnEmptyResult() async {
        // Ответ без ожидаемого ключа — это невыполненный запрос. Пустой список
        // сказал бы «не обсуждали», и человек бы поверил.
        for service in WorkMessengers.Service.allCases {
            let (http, _) = stub(json: #"{"message": "Bad Request"}"#)
            await #expect(throws: WorkMessengers.ConnectorError.unreadable) {
                try await WorkMessengers(service: service, token: "t:u",
                                         secondary: "chat.company.ru", scope: "x",
                                         http: http).search("q")
            }
        }
    }

    @Test("пустой запрос никуда не уходит")
    func blankQueryIsNotSent() async throws {
        let (http, recorder) = stub(json: Self.pachcaJSON)
        let hits = try await WorkMessengers(service: .pachca, token: "t",
                                            http: http).search("   ")
        #expect(hits.isEmpty)
        #expect(recorder.count == 0)
    }

    @Test("у каждого сервиса сказано, что именно спрашивать у человека")
    func promptsExplainThemselves() {
        for service in WorkMessengers.Service.allCases {
            #expect(!service.title.isEmpty)
            #expect(!service.credentialHint.isEmpty)
            // Подсказку читает человек — значит по-русски.
            #expect(service.credentialHint.range(
                of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) != nil,
                "подсказка не по-русски: \(service)")
        }
        // Пачке хватает токена; остальным нужны адрес и место поиска.
        #expect(!WorkMessengers.Service.pachca.needsSecondary)
        #expect(!WorkMessengers.Service.pachca.needsScope)
        #expect(WorkMessengers.Service.mattermost.needsScope)
        #expect(WorkMessengers.Service.rocketChat.needsScope)
    }

    // MARK: - Хранение
}

/// Запоминает запросы: замыкание `Sendable`, поэтому состояние под замком.
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
