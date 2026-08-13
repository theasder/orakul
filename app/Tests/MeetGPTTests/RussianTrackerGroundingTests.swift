import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Подключённый трекер должен попадать в подсказку.
///
/// Без этого настройки сохраняют токен, кнопка показывает «подключено», и
/// ничего не происходит — то же самое, что кнопка «Подключить», ведущая в
/// никуда, только заметить труднее.
@MainActor
@Suite("Трекеры в подсказке", .serialized)
struct RussianTrackerGroundingTests {

    /// Один ответ на любой запрос: тест про маршрут, а не про разбор JSON —
    /// его проверяет RussianTrackersTests.
    private func manager(seeding services: [RussianTrackers.Service],
                         answer: String = #"[{"id": 314, "title": "Лимиты на выгрузку"}]"#)
        -> (MCPConnectionManager, () -> Int) {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        for service in services {
            store.setToken("k-token", for: service)
            if service.needsSecondary {
                store.setSecondary(service == .kaiten ? "team.kaiten.ru" : "1234567", for: service)
            }
        }
        let calls = Counter()
        let http: RussianTrackers.HTTP = { request in
            calls.bump()
            return (Data(answer.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (MCPConnectionManager(tokenStore: keychain,
                                     notificationCenter: NotificationCenter(),
                                     trackerHTTP: http),
                { calls.value })
    }

    @Test("настроенный трекер отвечает в подсказку")
    func configuredTrackerGrounds() async {
        let (manager, calls) = self.manager(seeding: [.kaiten])
        let snippets = await manager.groundingSnippets(goal: "лимиты на выгрузку")

        let tracker = snippets.first { $0.sourceID == "tracker:kaiten" }
        #expect(tracker != nil, "подключённый Kaiten молчит")
        #expect(tracker?.text.contains("Лимиты на выгрузку") == true)
        #expect(tracker?.serverName == "Kaiten")
        #expect(calls() == 1)
    }

    @Test("ненастроенный трекер не занимает место среди источников")
    func unconfiguredTrackerStaysOut() async {
        // Пустой список источников — не то же, что источник, который молчит:
        // второй тратит бюджет ожидания и вытесняет тот, который ответил бы.
        let (manager, calls) = self.manager(seeding: [])
        let snippets = await manager.groundingSnippets(goal: "лимиты на выгрузку")

        #expect(!snippets.contains { $0.sourceID?.hasPrefix("tracker:") == true })
        #expect(calls() == 0, "запрос ушёл без токена")
    }

    @Test("токен без организации не делает Яндекс Трекер источником")
    func yandexNeedsOrganisationToGround() async {
        let keychain = InMemoryKeychain()
        RussianTrackerStore(store: keychain).setToken("y0_synthetic", for: .yandexTracker)
        let calls = Counter()
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter(),
            trackerHTTP: { request in
                calls.bump()
                return (Data("[]".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            })

        let snippets = await manager.groundingSnippets(goal: "сроки по задаче")
        #expect(!snippets.contains { $0.sourceID == "tracker:yandexTracker" })
        #expect(calls.value == 0, "ушёл запрос, который вернул бы 403")
    }

    @Test("пустая выдача трекера не превращается в пустой источник")
    func emptyResultIsNoSource() async {
        // Источник со строкой из нуля задач стоит места в подсказке и ничего
        // не сообщает.
        let (manager, _) = self.manager(seeding: [.yougile], answer: "[]")
        let snippets = await manager.groundingSnippets(goal: "лимиты")
        #expect(!snippets.contains { $0.sourceID == "tracker:yougile" })
    }

    @Test("сломанный трекер не роняет остальную подсказку")
    func failureIsSurvivable() async {
        // 401 у одного коннектора не должен стоить пользователю ответа: он
        // узнает о просроченном токене в настройках, а не посреди звонка.
        let keychain = InMemoryKeychain()
        RussianTrackerStore(store: keychain).setToken("k-token", for: .kaiten)
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter(),
            trackerHTTP: { request in
                (Data("{}".utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 401,
                                 httpVersion: nil, headerFields: nil)!)
            })

        let snippets = await manager.groundingSnippets(goal: "лимиты")
        #expect(!snippets.contains { $0.sourceID == "tracker:kaiten" })
    }

    @Test("трекеру уходит подсказка про задачи, а не голая цель")
    func queryCarriesTheTrackerHint() {
        // Голая цель («что мы решили по срокам») ищется в трекере плохо: его
        // ранжирование опирается на слова из задач.
        let query = ConnectorProbeStrategy.query(goal: "сроки", serverID: "kaiten")
        #expect(query.contains("сроки"))
        #expect(query.contains("открытые задачи"))
        #expect(ConnectorProbeStrategy.probe(forTracker: "kaiten") != nil)
        #expect(ConnectorProbeStrategy.probe(forTracker: "notion") == nil,
                "не трекер, а MCP-сервер со своей подсказкой")
    }
}

/// Считает вызовы: замыкание `Sendable`, поэтому счётчик под замком.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
