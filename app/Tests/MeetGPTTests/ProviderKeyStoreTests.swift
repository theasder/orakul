import Foundation
import Testing
@testable import MeetGPT

/// Ключи провайдеров, введённые пользователем.
///
/// Смысл всей этой части: в готовом установщике ключей нет ни одного, и без
/// ввода в настройках приложение не может ответить ни на один вопрос. Поэтому
/// проверяется не «строка сохранилась», а то, что делает продукт рабочим —
/// правильный порядок источников и отсутствие мёртвых записей.
@Suite("Ключи провайдеров")
struct ProviderKeyStoreTests {

    @Test("ключ переживает перезапуск и лежит в Связке ключей")
    func keyRoundTrips() {
        let keychain = InMemoryKeychain()
        ProviderKeyStore(store: keychain).setKey("sk-user", for: .openAI)

        // Новый экземпляр — как после перезапуска приложения.
        #expect(ProviderKeyStore(store: keychain).key(for: .openAI) == "sk-user")
        #expect(keychain.count == 1)
    }

    @Test("ключ пользователя важнее зашитого при сборке")
    func userKeyWinsOverBaked() {
        // Обратный порядок означал бы, что чужой ключ, случайно попавший в
        // сборку, молча переопределяет тот, который человек только что вписал
        // и видит в настройках.
        let store = ProviderKeyStore(store: InMemoryKeychain())
        #expect(store.resolvedKey(for: .openAI, baked: "sk-baked") == "sk-baked")

        store.setKey("sk-user", for: .openAI)
        #expect(store.resolvedKey(for: .openAI, baked: "sk-baked") == "sk-user")
    }

    @Test("без ключа остаётся зашитый, даже если он пустой")
    func bakedRemainsTheFallback() {
        // Пустой зашитый ключ — норма для готового установщика: так и
        // задумано, ключи в него не кладут.
        let store = ProviderKeyStore(store: InMemoryKeychain())
        #expect(store.resolvedKey(for: .deepSeek, baked: "") == "")
        #expect(!store.hasKey(.deepSeek))
    }

    @Test("у каждого провайдера свой ключ")
    func providersDoNotShareOneSlot() {
        // Общая запись означала бы, что второй ключ молча отключает первый.
        let keychain = InMemoryKeychain()
        let store = ProviderKeyStore(store: keychain)
        store.setKey("sk-user", for: .openAI)
        store.setKey("sk-deep", for: .deepSeek)

        #expect(store.key(for: .openAI) == "sk-user")
        #expect(store.key(for: .deepSeek) == "sk-deep")
        #expect(keychain.count == 2)
    }

    @Test("пустая строка убирает ключ, а не сохраняет пустоту")
    func emptyKeyClears() {
        let keychain = InMemoryKeychain()
        let store = ProviderKeyStore(store: keychain)
        store.setKey("sk-user", for: .openAI)
        store.setKey("   ", for: .openAI)

        #expect(store.key(for: .openAI) == nil)
        #expect(keychain.count == 0, "мёртвая запись осталась в Связке ключей")
    }

    @Test("ключ обрезается по краям")
    func keyIsTrimmed() {
        // Скопированный ключ почти всегда приезжает с переводом строки, а
        // провайдер отвечает на такой заголовок 401.
        let store = ProviderKeyStore(store: InMemoryKeychain())
        store.setKey("  sk-user\n", for: .openAI)
        #expect(store.key(for: .openAI) == "sk-user")
    }

    @Test("список настроенных провайдеров — это те, у кого есть ключ")
    func configuredListsOnlyKeyed() {
        let store = ProviderKeyStore(store: InMemoryKeychain())
        #expect(store.configured.isEmpty)

        store.setKey("sk-deep", for: .deepSeek)
        #expect(store.configured == [.deepSeek])

        store.remove(.deepSeek)
        #expect(store.configured.isEmpty)
    }

    @Test("у каждого провайдера своя запись в Связке, а не общая")
    func everyProviderHasItsOwnAccount() {
        // Перебор по всем: новый провайдер в каталоге не должен случайно
        // разделить запись с уже существующим.
        let keychain = InMemoryKeychain()
        let store = ProviderKeyStore(store: keychain)
        for provider in LLMProvider.allCases {
            store.setKey("sk-\(provider.rawValue)", for: provider)
        }
        #expect(keychain.count == LLMProvider.allCases.count)
        for provider in LLMProvider.allCases {
            #expect(store.key(for: provider) == "sk-\(provider.rawValue)")
        }
    }
}
