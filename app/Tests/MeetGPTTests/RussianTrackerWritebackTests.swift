import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Завести задачу в российском трекере.
///
/// Чтение можно повторить, запись — нет: неверный запрос либо создаёт не то,
/// либо не создаёт ничего, и человек узнаёт об этом после звонка. Поэтому тут
/// проверяется форма запроса по документации вендора, а не «хоть что-то ушло».
///
/// Обязательные поля сверены с документацией 2026-08-11:
/// Яндекс — `summary` + `queue`, Kaiten — `title` + `board_id` (целое),
/// YouGile — `title` + колонка.
@Suite("Заведение задач в трекерах")
struct RussianTrackerWritebackTests {

    private func stub(status: Int = 201, json: String = #"{"key": "TREK-42"}"#)
        -> (RussianTrackers.HTTP, Recorder) {
        let recorder = Recorder()
        let http: RussianTrackers.HTTP = { request in
            recorder.record(request)
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (http, recorder)
    }

    private func client(_ service: RussianTrackers.Service,
                        destination: String?,
                        http: @escaping RussianTrackers.HTTP) -> RussianTrackers {
        let secondary: String? = {
            switch service {
            case .yandexTracker: return "org-1"
            case .kaiten:        return "team.kaiten.ru"
            case .yougile:       return nil
            }
        }()
        return RussianTrackers(service: service, token: "t0ken",
                               secondary: secondary, destination: destination, http: http)
    }

    private func destination(for service: RussianTrackers.Service) -> String {
        switch service {
        case .yandexTracker: return "TREK"
        case .kaiten:        return "4"
        case .yougile:       return "col-1"
        }
    }

    @Test("каждый сервис получает POST по своему адресу")
    func createGoesToTheRightPlace() async throws {
        let expected: [RussianTrackers.Service: String] = [
            .yandexTracker: "https://api.tracker.yandex.net/v3/issues/",
            .kaiten: "https://team.kaiten.ru/api/latest/cards",
            .yougile: "https://yougile.com/api-v2/tasks",
        ]
        for service in RussianTrackers.Service.allCases {
            let (http, recorder) = stub()
            _ = try await client(service, destination: destination(for: service), http: http)
                .createIssue(title: "Поднять лимиты")

            let request = try #require(recorder.last)
            #expect(request.httpMethod == "POST", "\(service.title): не POST")
            #expect(request.url?.absoluteString == expected[service],
                    "\(service.title): \(request.url?.absoluteString ?? "нет адреса")")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    @Test("у Яндекса в теле summary и ключ очереди")
    func yandexBodyMatchesTheDocs() async throws {
        let (http, recorder) = stub()
        _ = try await client(.yandexTracker, destination: "TREK", http: http)
            .createIssue(title: "Поднять лимиты")

        let body = try #require(recorder.last?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["summary"] as? String == "Поднять лимиты")
        #expect(payload["queue"] as? String == "TREK")
        #expect(recorder.last?.value(forHTTPHeaderField: "X-Org-ID") == "org-1")
    }

    @Test("у Kaiten номер доски уходит числом, а не строкой")
    func kaitenBoardIsAnInteger() async throws {
        // Строка в board_id даёт 400. Ошибка приходит по-английски и уже после
        // звонка, поэтому её ловим здесь.
        let (http, recorder) = stub(json: #"{"id": 314, "title": "Поднять лимиты"}"#)
        _ = try await client(.kaiten, destination: "4", http: http)
            .createIssue(title: "Поднять лимиты")

        let body = try #require(recorder.last?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["board_id"] as? Int == 4, "board_id не число")
        #expect(payload["title"] as? String == "Поднять лимиты")
    }

    @Test("у YouGile задача кладётся в колонку")
    func yougileGetsItsColumn() async throws {
        let (http, recorder) = stub(json: #"{"id": "task-9"}"#)
        _ = try await client(.yougile, destination: "col-1", http: http)
            .createIssue(title: "Поднять лимиты")

        let body = try #require(recorder.last?.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["columnId"] as? String == "col-1")
    }

    @Test("без места назначения запрос не уходит")
    func noDestinationNoRequest() async {
        // Трекер, подключённый только на чтение, — нормальное состояние.
        // Отправить задачу «куда-нибудь» нельзя: у всех троих поле обязательное.
        for service in RussianTrackers.Service.allCases {
            let (http, recorder) = stub()
            await #expect(throws: RussianTrackers.TrackerError.notConfigured(service)) {
                try await client(service, destination: nil, http: http)
                    .createIssue(title: "Поднять лимиты")
            }
            #expect(recorder.count == 0, "\(service.title): запрос ушёл без места назначения")
        }
    }

    @Test("пустой заголовок не заводит задачу")
    func emptyTitleIsRejected() async {
        let (http, recorder) = stub()
        await #expect(throws: RussianTrackers.TrackerError.notConfigured(.kaiten)) {
            try await client(.kaiten, destination: "4", http: http).createIssue(title: "   ")
        }
        #expect(recorder.count == 0)
    }

    @Test("ответ возвращает ключ и ссылку на заведённую задачу")
    func createdIssueComesBack() async throws {
        let (http, _) = stub(json: #"{"key": "TREK-42", "summary": "Поднять лимиты"}"#)
        let issue = try await client(.yandexTracker, destination: "TREK", http: http)
            .createIssue(title: "Поднять лимиты")

        #expect(issue.key == "TREK-42")
        #expect(issue.title == "Поднять лимиты")
        // Ссылка нужна, чтобы человек убедился своими глазами: «задача заведена»
        // без возможности открыть её — это обещание, а не результат.
        #expect(issue.url?.absoluteString == "https://tracker.yandex.ru/TREK-42")
    }

    @Test("непонятный ответ — это ошибка, а не тихий успех")
    func unreadableResponseFails() async {
        // Худший исход: сказать «задача заведена», когда её нет. Здесь ответ
        // с кодом 201, но без ключа — значит, непонятно, что создалось.
        let (http, _) = stub(json: #"{"status": "ok"}"#)
        await #expect(throws: RussianTrackers.TrackerError.unreadable(.kaiten)) {
            try await client(.kaiten, destination: "4", http: http)
                .createIssue(title: "Поднять лимиты")
        }
    }

    @Test("чужой токен на записи читается как чужой токен")
    func unauthorisedIsRecognised() async {
        let (http, _) = stub(status: 403, json: "{}")
        await #expect(throws: RussianTrackers.TrackerError.unauthorised(.yougile)) {
            try await client(.yougile, destination: "col-1", http: http)
                .createIssue(title: "Поднять лимиты")
        }
    }

    @Test("хранилище отличает «можно читать» от «можно заводить задачи»")
    func storeSeparatesReadFromWrite() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setToken("k-token", for: .kaiten)
        store.setSecondary("team.kaiten.ru", for: .kaiten)
        #expect(store.isConfigured(.kaiten))
        #expect(!store.canFileTasks(.kaiten), "без доски задачи заводить некуда")
        #expect(store.writable.isEmpty)

        store.setDestination("4", for: .kaiten)
        #expect(store.canFileTasks(.kaiten))
        #expect(store.writable == [.kaiten])
    }

    @Test("отключение забирает и место назначения")
    func removeClearsDestination() {
        // Оставшийся номер доски после отключения — это чужая доска,
        // подставленная к следующему токену.
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("k-token", for: .kaiten)
        store.setSecondary("team.kaiten.ru", for: .kaiten)
        store.setDestination("4", for: .kaiten)

        store.remove(.kaiten)
        #expect(store.destination(for: .kaiten) == nil)
        #expect(keychain.count == 0)
    }

    @Test("у каждого сервиса написано, что класть в поле назначения")
    func everyServiceExplainsItsDestination() {
        // «Идентификатор» без уточнения, чего именно, — тупик: у Яндекса это
        // ключ очереди, у Kaiten номер доски, у YouGile колонка.
        for service in RussianTrackers.Service.allCases {
            let prompt = service.destinationPrompt ?? ""
            #expect(prompt.count > 8, "\(service.title): подсказка ни о чём")
        }
    }
}

/// Запоминает запросы: замыкание помечено `Sendable`, поэтому состояние
/// живёт под замком.
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
