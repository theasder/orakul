import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

/// Хранилище токенов — часть приложения, а не ядра.
///
/// Сам коннектор переехал в `OrakulCore`: он ничего не знает, кроме Foundation,
/// и потому переживёт порт на Windows. А `RussianTrackerStore` стоит на Связке
/// ключей macOS, и её в ядре быть не должно — иначе «портируемое ядро»
/// перестанет быть портируемым.
@Suite("Хранилище токенов базы знаний")
struct TeamNotesStoreTests {

    @Test("хранилище собирает клиента по одному токену")
    func storeNeedsOnlyToken() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        let http: TeamNotes.HTTP = { _ in (Data(), HTTPURLResponse()) }

        #expect(store.notesClient(for: .outline, http: http) == nil)
        store.setNotesToken("tok", for: .outline)
        #expect(store.notesClient(for: .outline, http: http) != nil)
        #expect(store.configuredNotes == [.outline])

        store.removeNotes(.outline)
        #expect(store.notesToken(for: .outline) == nil)
    }
}
