import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

/// Хранилище токенов — часть приложения, а не ядра.
///
/// Коннектор переехал в `OrakulCore`: он знает только Foundation и потому
/// переживёт порт на Windows. `RussianTrackerStore` стоит на Связке ключей
/// macOS, и ей в портируемом ядре не место.
@Suite("Хранилище токенов: WorkMessengers")
struct WorkMessengersStoreTests {

    @Test("хранилище держит мессенджеры отдельно от трекеров")
    func storeKeepsMessengersApart() {
        // Один сервис может быть подключён и как трекер, и как мессенджер;
        // общий ключ затёр бы один токен другим.
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setToken("tracker-token", for: .kaiten)
        store.setMessengerToken("messenger-token", for: .mattermost)

        #expect(store.token(for: .kaiten) == "tracker-token")
        #expect(store.messengerToken(for: .mattermost) == "messenger-token")
    }

    @Test("клиент не собирается, пока не хватает полей")
    func clientNeedsEverything() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        let http: WorkMessengers.HTTP = { _ in (Data(), HTTPURLResponse()) }

        store.setMessengerToken("tok", for: .mattermost)
        #expect(store.messengerClient(for: .mattermost, http: http) == nil,
                "клиент собрался без адреса сервера")

        store.setMessengerSecondary("chat.company.ru", for: .mattermost)
        #expect(store.messengerClient(for: .mattermost, http: http) == nil,
                "клиент собрался без команды")

        store.setMessengerScope("team-1", for: .mattermost)
        #expect(store.messengerClient(for: .mattermost, http: http) != nil)
        #expect(store.configuredMessengers == [.mattermost])
    }

    @Test("отключение забирает все три поля")
    func removeClearsEverything() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setMessengerToken("tok", for: .rocketChat)
        store.setMessengerSecondary("chat.company.ru", for: .rocketChat)
        store.setMessengerScope("room-9", for: .rocketChat)

        store.removeMessenger(.rocketChat)
        #expect(store.messengerToken(for: .rocketChat) == nil)
        #expect(store.messengerSecondary(for: .rocketChat) == nil)
        #expect(store.messengerScope(for: .rocketChat) == nil)
        #expect(keychain.count == 0)
    }

    @Test("Telegram хранит токен, allowlist и подтверждённый bot id вместе")
    func telegramCredentialsAreCompleteAndRemovable() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setTelegram(token: "123:synthetic", allowedChatIDs: [-1002, -1001], botID: 44)

        #expect(store.telegramToken() == "123:synthetic")
        #expect(store.telegramAllowedChatIDs() == [-1001, -1002])
        #expect(store.telegramBotID() == 44)
        #expect(store.isTelegramConfigured)

        store.removeTelegram()
        #expect(!store.isTelegramConfigured)
        #expect(store.telegramBotID() == nil)
        #expect(keychain.count == 0)
    }

    @Test("allowlist не принимает частично ошибочную строку")
    func telegramAllowlistParsingIsAllOrNothing() {
        #expect(RussianTrackerStore.parseTelegramChatIDs("-1001, -1002\n-1003")
                == [-1001, -1002, -1003])
        #expect(RussianTrackerStore.parseTelegramChatIDs("-1001, не-id") == nil)
        #expect(RussianTrackerStore.parseTelegramChatIDs("  ") == nil)
    }
}
