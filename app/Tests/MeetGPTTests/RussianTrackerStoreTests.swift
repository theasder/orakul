import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Хранилище токенов трекеров. Проверяется главным образом одно: когда
/// приложение считает сервис настроенным. Ошибка здесь не видна на экране —
/// строка показывает «подключено», а запрос падает с 403.
@Suite("Хранилище токенов трекеров")
struct RussianTrackerStoreTests {

    @Test("токен переживает перезапуск и лежит в Связке ключей, не в настройках")
    func tokenRoundTrips() {
        let keychain = InMemoryKeychain()
        RussianTrackerStore(store: keychain).setToken("k-token", for: .kaiten)

        // Новый экземпляр — как после перезапуска приложения.
        #expect(RussianTrackerStore(store: keychain).token(for: .kaiten) == "k-token")
        #expect(keychain.count == 1)
    }

    @Test("у каждого сервиса свой ключ")
    func servicesDoNotShareOneSlot() {
        // Общая запись означала бы, что подключение второго трекера молча
        // отключает первый.
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("a", for: .kaiten)
        store.setToken("b", for: .yougile)

        #expect(store.token(for: .kaiten) == "a")
        #expect(store.token(for: .yougile) == "b")
        #expect(keychain.count == 2)
    }

    @Test("пустой токен стирает запись, а не сохраняет пустоту")
    func emptyTokenClears() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("k-token", for: .kaiten)
        store.setToken("   ", for: .kaiten)

        #expect(store.token(for: .kaiten) == nil)
        #expect(!store.isConfigured(.kaiten))
        #expect(keychain.count == 0, "мёртвая запись осталась в Связке ключей")
    }

    @Test("токен обрезается по краям")
    func tokenIsTrimmed() {
        // Скопированный токен почти всегда приезжает с переводом строки, а
        // сервис отвечает на такой заголовок 401.
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setToken("  k-token\n", for: .kaiten)
        #expect(store.token(for: .kaiten) == "k-token")
    }

    @Test("Яндекс Трекер не считается настроенным без организации")
    func yandexNeedsBothHalves() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setToken("y0_synthetic", for: .yandexTracker)
        #expect(!store.isConfigured(.yandexTracker), "403 при первом же запросе")

        store.setSecondary("1234567", for: .yandexTracker)
        #expect(store.isConfigured(.yandexTracker))
    }

    @Test("сервису без второго поля оно не нужно и не хранится")
    func othersIgnoreSecondary() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("y-token", for: .yougile)
        store.setSecondary("1234567", for: .yougile)

        #expect(store.isConfigured(.yougile))
        #expect(store.secondary(for: .yougile) == nil)
        #expect(keychain.count == 1, "лишнее поле записано в Связку ключей")
    }

    @Test("отключение убирает обе половины ключа")
    func removeClearsEverything() {
        // Оставшийся X-Org-ID после отключения — это чужой идентификатор,
        // подставленный к следующему токену.
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("y0_synthetic", for: .yandexTracker)
        store.setSecondary("1234567", for: .yandexTracker)

        store.remove(.yandexTracker)
        #expect(store.token(for: .yandexTracker) == nil)
        #expect(store.secondary(for: .yandexTracker) == nil)
        #expect(keychain.count == 0)
    }

    @Test("клиент выдаётся только для настроенного сервиса")
    func clientOnlyWhenConfigured() throws {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        let http: RussianTrackers.HTTP = { request in
            (Data("[]".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(store.client(for: .yandexTracker, http: http) == nil)

        store.setToken("y0_synthetic", for: .yandexTracker)
        #expect(store.client(for: .yandexTracker, http: http) == nil, "нет организации — нет клиента")

        store.setSecondary("1234567", for: .yandexTracker)
        let client = try #require(store.client(for: .yandexTracker, http: http))
        #expect(client.headers()["X-Org-ID"] == "1234567")
        #expect(client.headers()["Authorization"] == "OAuth y0_synthetic")
    }
}
