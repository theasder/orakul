import Foundation
import Testing
@testable import OrakulCore

/// Каталог кнопок — единственная логика, которая уже сейчас решает, что
/// пользователь увидит. Тесты держат ровно те правила, которые нельзя
/// нарушить незаметно: бесплатное остаётся бесплатным, оффлайн остаётся
/// оффлайном, и недоступная кнопка объясняет причину.
@Suite("Каталог кнопок")
struct PromptCatalogTests {

    private func json(_ buttons: String) -> Data {
        Data("""
        {"version": 1, "locale": "ru-RU", "buttons": [\(buttons)]}
        """.utf8)
    }

    private func button(id: String, offline: Bool = true) -> String {
        """
        {"id": "\(id)", "label": "Кнопка", "prompt": "Достаточно длинный текст запроса",
         "offline": \(offline), "adapted": "почему так"}
        """
    }

    @Test("вшитый каталог читается и проходит проверки")
    func bundledCatalogLoads() throws {
        let catalog = try PromptCatalog.bundled()
        #expect(catalog.locale == "ru-RU")
        #expect(catalog.buttons.count >= 6)
        #expect(catalog.recall != nil, "главная кнопка продукта пропала из каталога")
    }

    @Test("всё в каталоге работает на устройстве — платить не за что")
    func everythingIsFreeAndLocal() throws {
        let catalog = try PromptCatalog.bundled()
        let networkBound = catalog.buttons.filter { !$0.offline }.map(\.id)
        #expect(networkBound.isEmpty,
                "кнопки, которым нужна сеть: \(networkBound) — это ломает единственное обещание продукта")
        let recall = try #require(catalog.recall)
        #expect(recall.offline)
    }

    @Test("кнопка, которой нужна сеть, не собирается")
    func buttonMustBeOffline() {
        // Не «мы стараемся»: каталог с такой кнопкой не грузится вообще.
        // Платных уровней нет, значит нет и оправдания «это в подписке».
        let broken = json(button(id: "bad", offline: false))
        #expect(throws: PromptCatalog.LoadError.buttonRequiresNetwork("bad")) {
            try PromptCatalog.decode(broken)
        }
    }

    @Test("повтор идентификатора — ошибка, а не тихая перезапись")
    func duplicateIdentifiersRejected() {
        let broken = json(button(id: "same") + "," + button(id: "same"))
        #expect(throws: PromptCatalog.LoadError.duplicateIdentifier("same")) {
            try PromptCatalog.decode(broken)
        }
    }

    @Test("каталог отдаёт все кнопки: разграничивать нечего")
    func everythingIsActionable() throws {
        let catalog = try PromptCatalog.bundled()
        #expect(catalog.actionable.count == catalog.buttons.count)
    }

    @Test("порядок кнопок в файле ничего не решает")
    func lookupIsByIdentifier() throws {
        // Тексты правят люди, которые не собирают приложение. Если код начнёт
        // зависеть от позиции в массиве, перестановка строк сломает продукт.
        let reordered = try PromptCatalog.decode(json(
            button(id: "meeting-summary") + "," + button(id: "what-decided")))
        #expect(reordered.recall?.id == "what-decided")
    }
}
