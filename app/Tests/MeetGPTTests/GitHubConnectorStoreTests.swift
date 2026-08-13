import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Настройки GitHub в Связке ключей.
///
/// Сам коннектор уехал в переносимое ядро — ему хватает Foundation. Хранилище
/// осталось здесь: Связка ключей есть только на macOS. Поэтому и проверки
/// разделены, а не продублированы.
@Suite("GitHub — хранилище")
struct GitHubConnectorStoreTests {

    @Test("хранилище режет список репозиториев по запятым и пробелам")
    func storeParsesRepositoryList() {
        // Строку вставляют руками, и «myteam/backend, » — обычный случай.
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setGitHubToken("ghp_synthetic")
        store.setGitHubRepositories(" myteam/backend ,, myteam/web , ")
        #expect(store.githubRepositories() == ["myteam/backend", "myteam/web"])
        #expect(store.isGitHubReady)
    }

    @Test("токена без репозиториев не хватает")
    func tokenAloneIsNotEnough() {
        let store = RussianTrackerStore(store: InMemoryKeychain())
        store.setGitHubToken("ghp_synthetic")
        #expect(!store.isGitHubReady, "поиск ушёл бы по всему GitHub")
        #expect(store.githubClient(http: { _ in
            (Data(), HTTPURLResponse())
        }) == nil)
    }

    @Test("отключение забирает и токен, и репозитории")
    func removeClearsBoth() {
        let keychain = InMemoryKeychain()
        let store = RussianTrackerStore(store: keychain)
        store.setGitHubToken("ghp_synthetic")
        store.setGitHubRepositories("myteam/backend")

        store.removeGitHub()
        #expect(store.githubToken() == nil)
        #expect(store.githubRepositories().isEmpty)
        #expect(keychain.count == 0)
    }
}
