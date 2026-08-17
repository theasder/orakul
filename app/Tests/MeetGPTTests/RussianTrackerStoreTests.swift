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

    @Test("WEEEK хранит токен и проект в отдельных записях Связки ключей")
    func weeekCredentialsRoundTrip() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setToken("weeek-token", for: .weeek)
        store.setDestination("42", for: .weeek)

        let afterRestart = RussianTrackerStore(store: keychain)
        #expect(afterRestart.token(for: .weeek) == "weeek-token")
        #expect(afterRestart.destination(for: .weeek) == "42")
        #expect(afterRestart.isConfigured(.weeek))
        #expect(afterRestart.canFileTasks(.weeek))
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

@Suite("Пустое поле стирает запись — у каждого поля")
struct EveryCredentialSetterClearsTests {
    /// CONTRIBUTING обещает это как правило, а не как свойство одного поля:
    /// «Пустая строка убирает запись, а не сохраняет пустоту: иначе очищенное
    /// поле оставляет мёртвый ключ, и сервис выглядит настроенным».
    ///
    /// Поведенчески проверен один сеттер из двенадцати. Остальные держатся на
    /// том, что их писали подряд и одинаково. Главная просьба к участникам —
    /// новый коннектор, то есть новые сеттеры; тринадцатый без проверки на
    /// пустоту не сломает ни один существующий тест.
    @Test("ни один сеттер в хранилище не сохраняет пустую строку")
    func everySetterGuardsEmptyInput() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/MCP/RussianTrackerStore.swift")
        let lines = try String(contentsOf: url, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var checked = 0
        var unguarded: [String] = []
        for (index, line) in lines.enumerated() where line.contains("func set") {
            let name = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "func ", with: "")
                .components(separatedBy: "(").first ?? line

            // Тело — до закрывающей скобки, по счётчику, а не по числу строк.
            // Сначала здесь стояло окно в четырнадцать строк, и оно залезало
            // в следующую функцию: снятая проверка находилась у соседа, и тест
            // проходил. Проверка, которая ничего не проверяет, хуже её
            // отсутствия — она закрывает вопрос.
            var depth = 0
            var body: [String] = []
            for current in lines[index...] {
                body.append(current)
                depth += current.filter { $0 == "{" }.count
                depth -= current.filter { $0 == "}" }.count
                if depth == 0 && body.count > 1 { break }
            }
            let text = body.joined(separator: "\n")
            checked += 1
            let clears = text.contains("isEmpty")
                && (text.contains("delete") || text.contains("remove"))
            if !clears { unguarded.append(name) }
        }

        #expect(checked >= 12, "найдено \(checked) сеттеров — обход сломался")
        #expect(unguarded.isEmpty,
                "сеттер сохранит пустую строку, и сервис будет выглядеть настроенным: \(unguarded)")
    }
}
