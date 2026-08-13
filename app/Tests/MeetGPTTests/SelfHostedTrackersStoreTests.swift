import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

/// Хранилище токенов — часть приложения, а не ядра.
///
/// Коннектор переехал в `OrakulCore`: он знает только Foundation и потому
/// переживёт порт на Windows. `RussianTrackerStore` стоит на Связке ключей
/// macOS, и ей в портируемом ядре не место.
@Suite("Хранилище токенов: SelfHostedTrackers")
struct SelfHostedTrackersStoreTests {

    @Test("хранилище собирает клиента только с адресом")
    func storeNeedsHost() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        let http: SelfHostedTrackers.HTTP = { _ in (Data(), HTTPURLResponse()) }

        store.setSelfHostedToken("tok", for: .gitlab)
        #expect(store.selfHostedClient(for: .gitlab, http: http) == nil,
                "клиент собрался без адреса сервера")

        store.setSelfHostedHost("gitlab.company.ru", for: .gitlab)
        #expect(store.selfHostedClient(for: .gitlab, http: http) != nil)
        #expect(store.configuredSelfHosted == [.gitlab])

        store.removeSelfHosted(.gitlab)
        #expect(store.selfHostedToken(for: .gitlab) == nil)
        #expect(store.selfHostedHost(for: .gitlab) == nil)
    }
}
