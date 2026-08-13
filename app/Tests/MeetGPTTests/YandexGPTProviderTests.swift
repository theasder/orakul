import Foundation
import Testing
@testable import MeetGPT

/// YandexGPT — единственный путь, на котором данные остаются в России.
///
/// Он же единственный, где ключа мало: модель называется
/// `gpt://<каталог>/<модель>/latest`, и каталог свой у каждого пользователя.
/// Ошибка здесь выглядит как «модель не найдена» — сообщение, по которому
/// человек никогда не догадается, что забыл вписать идентификатор каталога.
///
/// Форма запроса сверена с документацией (2026-08-12): вход, совместимый с
/// OpenAI, `llm.api.cloud.yandex.net/v1/chat/completions`, идентификатор
/// каталога и в имени модели, и в заголовке `x-folder-id`.
@Suite("YandexGPT", .serialized)
struct YandexGPTProviderTests {

    private func store(key: String? = "AQVN-synthetic", folder: String? = "b1g12345678")
        -> ProviderKeyStore {
        let store = ProviderKeyStore(store: InMemoryKeychain())
        if let key { store.setKey(key, for: .yandexGPT) }
        if let folder { store.setSecondary(folder, for: .yandexGPT) }
        return store
    }

    @Test("данные остаются в России — и это записано в коде, а не только на сайте")
    func jurisdictionIsRussia() {
        // Ради этого провайдер и добавлен: по замерам (§3 плана) домашние
        // модели не выигрывают у зарубежных, и берут их за место хранения.
        #expect(LLMProvider.yandexGPT.jurisdiction == .russia)
        for provider in LLMProvider.allCases where provider != .yandexGPT {
            #expect(provider.jurisdiction != .russia,
                    "\(provider.label) неожиданно оказался российским")
        }
    }

    @Test("имя модели превращается в адрес с каталогом")
    func modelIDCarriesTheFolder() throws {
        try ProviderKeyStore.$overrideForTesting.withValue(store()) {
            let dialect = try #require(LLMProvider.yandexGPT.openAIDialect)
            #expect(dialect.modelID("yandexgpt") == "gpt://b1g12345678/yandexgpt/latest")
            #expect(dialect.modelID("yandexgpt-lite") == "gpt://b1g12345678/yandexgpt-lite/latest")
        }
    }

    @Test("идентификатор каталога уходит и заголовком")
    func folderGoesInTheHeader() throws {
        try ProviderKeyStore.$overrideForTesting.withValue(store()) {
            let dialect = try #require(LLMProvider.yandexGPT.openAIDialect)
            #expect(dialect.headers()["x-folder-id"] == "b1g12345678")
        }
    }

    @Test("без каталога имя модели не подменяется")
    func withoutFolderTheModelIsLeftAlone() throws {
        // Подставить `gpt:///yandexgpt/latest` было бы хуже: сервис ответил бы
        // ошибкой про адрес, а не про то, что не хватает настройки.
        try ProviderKeyStore.$overrideForTesting.withValue(store(folder: nil)) {
            let dialect = try #require(LLMProvider.yandexGPT.openAIDialect)
            #expect(dialect.modelID("yandexgpt") == "yandexgpt")
            #expect(dialect.headers().isEmpty)
        }
    }

    @Test("ключа без каталога не хватает, чтобы считать провайдера готовым")
    func keyAloneIsNotEnough() {
        let onlyKey = store(folder: nil)
        #expect(onlyKey.hasKey(.yandexGPT))
        #expect(!onlyKey.isReady(.yandexGPT), "готов без каталога — запрос упадёт")

        let both = store()
        #expect(both.isReady(.yandexGPT))
    }

    @Test("остальным провайдерам второе поле не нужно и не хранится")
    func othersHaveNoSecondary() {
        let keychain = InMemoryKeychain()
        let store = ProviderKeyStore(store: keychain)
        store.setKey("sk-user", for: .openAI)
        store.setSecondary("b1g12345678", for: .openAI)

        #expect(store.secondary(for: .openAI) == nil)
        #expect(store.isReady(.openAI))
        #expect(keychain.count == 1, "лишнее поле записано в Связку ключей")
    }

    @Test("адрес — совместимый с OpenAI вход Яндекса")
    func endpointMatchesTheDocs() throws {
        let dialect = try #require(LLMProvider.yandexGPT.openAIDialect)
        #expect(dialect.endpoint.absoluteString
                == "https://llm.api.cloud.yandex.net/v1/chat/completions")
    }

    @Test("модели Яндекса есть в каталоге и доступны всем")
    func modelsAreInTheCatalogue() {
        let yandex = LLMCatalog.all.filter { $0.provider == .yandexGPT }
        #expect(yandex.count >= 2, "в каталоге нет российских моделей")
        // Тарифов нет, значит и здесь ничего не заперто.
        for model in yandex {
            #expect(model.isAvailable(for: Config.currentTier),
                    "\(model.label) заперт — тарифов в orakul нет")
        }
    }

    @Test("отключение забирает и ключ, и каталог")
    func removeClearsBoth() {
        // Оставшийся каталог после смены ключа — это чужой каталог,
        // подставленный к новому ключу.
        let keychain = InMemoryKeychain()
        let store = ProviderKeyStore(store: keychain)
        store.setKey("AQVN-synthetic", for: .yandexGPT)
        store.setSecondary("b1g12345678", for: .yandexGPT)

        store.remove(.yandexGPT)
        #expect(store.key(for: .yandexGPT) == nil)
        #expect(store.secondary(for: .yandexGPT) == nil)
        #expect(keychain.count == 0)
    }
}
