import Foundation
import Testing
@testable import MeetGPT

/// Что видит разработчик, который поставил orakul и ещё не вставил ключ.
///
/// Это состояние — не редкий случай, а первый запуск любого скачавшего:
/// в установщик ключи не кладут намеренно. Значит, единственная ошибка,
/// которую он встретит, обязана называть экран, где ключ вставляют.
///
/// Прежний текст советовал «войти в аккаунт, чтобы пользоваться моделями» —
/// совет из Cruxwing, у которого есть сервер. У orakul его нет, и человек по
/// такому совету идёт искать несуществующий вход вместо поля для ключа.
@Suite("Первый запуск без ключа")
struct KeylessFirstRunTests {

    @Test("ошибка про отсутствующий ключ называет экран, а не диагноз")
    func missingKeyPointsAtTheScreen() throws {
        let message = try #require(LLMError.missingKey("DeepSeek").errorDescription)

        #expect(message.contains("Ключи провайдеров"),
                "не назван экран, где вставляют ключ: \(message)")
        #expect(message.contains("DeepSeek"), "не сказано, какого провайдера ключ")
        // И не советует того, чего в продукте нет.
        #expect(!message.lowercased().contains("войдите"),
                "совет войти в аккаунт: сервера у orakul нет")
        #expect(!message.contains("managed"), "английский остаток из Cruxwing")
    }

    @Test("ошибка говорит, что без ключа работает")
    func missingKeySaysWhatStillWorks() throws {
        // Иначе «нет ключа» читается как «приложение не работает», хотя запись,
        // расшифровка и поиск по звонкам ключа не требуют вовсе.
        let message = try #require(LLMError.missingKey("OpenAI").errorDescription)
        #expect(message.contains("без ключа"),
                "не сказано, что часть продукта работает и так: \(message)")
    }

    @Test("пустой список моделей отправляет туда же")
    func emptyPickerPointsAtTheSameScreen() {
        // Второе место, где человек упирается в то же самое. Раньше и здесь
        // предлагалось «войти».
        let source = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetGPT/Views/ModelSelectionRows.swift"),
            encoding: .utf8)) ?? ""
        #expect(!source.isEmpty, "не прочитался ModelSelectionRows — проверка фиктивна")
        #expect(source.contains("Ключи провайдеров"),
                "пустой список моделей не ведёт к экрану с ключами")
        #expect(!source.contains("войдите, чтобы пользоваться моделями"),
                "остался совет войти в несуществующий аккаунт")
    }

    @Test("без ключей ни один провайдер не выглядит готовым")
    func nothingLooksReadyWithoutKeys() {
        // Если провайдер считается настроенным без ключа, человек выбирает
        // модель, жмёт кнопку и получает ошибку вместо ответа — а это худший
        // способ узнать, что нужен ключ.
        let store = ProviderKeyStore(store: InMemoryKeychain())
        for provider in LLMProvider.allCases {
            #expect(!store.isReady(provider), "\(provider.label) готов без ключа")
        }
    }
}
