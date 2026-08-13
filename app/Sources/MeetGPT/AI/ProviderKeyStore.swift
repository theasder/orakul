import Foundation

/// Ключи провайдеров, которые пользователь вводит сам.
///
/// **Зачем это вернули.** У Cruxwing ключи перестали быть пользовательскими,
/// когда появился серверный шлюз: они уехали на сервер, а в приложение стал
/// зашиваться пустой `Secrets`. orakul этот код унаследовал, но сервера у него
/// нет и не планируется — значит, в готовом установщике ключа нет ни своего, ни
/// чужого, и ответы модели не работают вовсе. Скачанное приложение, которое не
/// может ответить ни на один вопрос, — это не бесплатный продукт, а
/// неработающий.
///
/// Поэтому ключ снова вводится в настройках и живёт в Связке ключей. Для
/// продукта, который считает всё на компьютере пользователя, так и честнее:
/// расход идёт по его собственному договору с провайдером, без посредника.
struct ProviderKeyStore: Sendable {

    private let store: KeychainStore

    init(store: KeychainStore = SystemKeychain.shared) {
        self.store = store
    }

    static let shared = ProviderKeyStore()

    /// Подмена для тестов. Нужна там, где проверяется маршрутизация: она
    /// отбирает модели по `isConfigured`, а это зависит от наличия ключа.
    /// Раньше вопрос не стоял — при серверном шлюзе настроенными считались все
    /// провайдеры сразу, и тесты маршрутизации проходили, ничего про ключи не
    /// зная. В прямом режиме так уже нельзя.
    ///
    /// Продакшен сюда не заглядывает: значение nil, и `current` отдаёт `shared`.
    ///
    /// **Почему `@TaskLocal`, а не обычная статическая переменная.** Раньше была
    /// обычная — одна на весь процесс. Swift Testing гоняет наборы параллельно,
    /// и подмена, сделанная в одном наборе, была видна всем остальным: набор
    /// «LLM catalog» заполнял хранилище ключами, а в это время «Прямой доступ к
    /// провайдеру» спрашивал `isConfigured` и получал true там, где ждал false.
    /// Полный прогон падал каждый раз, причём каждый раз в другом месте, и
    /// каждый упавший тест по отдельности проходил — то есть зелёный прогон
    /// вообще ничего не значил.
    ///
    /// `.serialized` тут не лечит: он упорядочивает тесты ВНУТРИ набора, а
    /// гонка была между наборами в разных файлах. Task-local снимает её
    /// устройством, а не дисциплиной: значение живёт в задаче, которая его
    /// связала, и соседняя задача его просто не видит.
    ///
    /// Цена: `Task.detached` task-local не наследует. Для подмены в тестах это
    /// правильное поведение — оторванная задача и не должна тянуть за собой
    /// тестовое окружение, — но если когда-нибудь понадобится подменить ключи
    /// коду внутри `Task.detached`, придётся передавать хранилище явно.
    @TaskLocal static var overrideForTesting: ProviderKeyStore?

    static var current: ProviderKeyStore { overrideForTesting ?? shared }

    private func account(_ provider: LLMProvider) -> String {
        "provider.key.\(provider.rawValue)"
    }

    private func secondaryAccount(_ provider: LLMProvider) -> String {
        "provider.key.\(provider.rawValue).secondary"
    }

    /// Ключ, введённый пользователем. nil — не вводили.
    func key(for provider: LLMProvider) -> String? {
        guard let data = store.get(account(provider)),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Пустая строка убирает ключ, а не сохраняет пустоту: иначе очищенное
    /// поле оставляет мёртвую запись, и провайдер выглядит настроенным.
    /// Возвращает, удалось ли сохранить.
    ///
    /// Раньше результат `store.set` здесь выбрасывался. Связка ключей умеет не
    /// записать — заблокирована, строка осталась от прежней подписи бинарника
    /// (для этих двух случаев в `Keychain.swift` есть отдельная ветка), — и
    /// тогда происходило худшее: настройки говорили «ключ есть», поле
    /// очищалось, а каждый запрос к модели падал с «нет ключа». Человеку
    /// оставалось вставлять ключ снова и снова.
    @discardableResult
    func setKey(_ key: String, for provider: LLMProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove(provider)
            return true          // очистить ключ — это успех, а не отказ
        }
        return store.set(Data(trimmed.utf8), for: account(provider))
    }

    func remove(_ provider: LLMProvider) {
        store.delete(account(provider))
        store.delete(secondaryAccount(provider))
    }

    func hasKey(_ provider: LLMProvider) -> Bool { key(for: provider) != nil }

    // MARK: - Второе поле

    /// Идентификатор каталога у Яндекса. Без него запрос уходит с моделью,
    /// которую сервис не знает, — то же самое, что без ключа, только ошибка
    /// приходит позже и звучит непонятнее.
    func secondary(for provider: LLMProvider) -> String? {
        guard provider.needsSecondary,
              let data = store.get(secondaryAccount(provider)),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func setSecondary(_ value: String, for provider: LLMProvider) -> Bool {
        guard provider.needsSecondary else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.delete(secondaryAccount(provider))
            return true
        }
        return store.set(Data(trimmed.utf8), for: secondaryAccount(provider))
    }

    /// Готов ли провайдер к запросу: ключа мало, если нужен ещё и каталог.
    func isReady(_ provider: LLMProvider) -> Bool {
        guard hasKey(provider) else { return false }
        return provider.needsSecondary ? secondary(for: provider) != nil : true
    }

    /// Ключ для запроса: сначала введённый человеком, потом зашитый при сборке.
    ///
    /// Порядок именно такой. Обратный означал бы, что ключ из чужого `.env`,
    /// случайно попавший в сборку, молча переопределяет тот, который человек
    /// только что вписал и видит в настройках.
    func resolvedKey(for provider: LLMProvider, baked: String) -> String {
        key(for: provider) ?? baked
    }

    /// Провайдеры, у которых есть пользовательский ключ.
    var configured: [LLMProvider] {
        LLMProvider.allCases.filter(hasKey)
    }
}
