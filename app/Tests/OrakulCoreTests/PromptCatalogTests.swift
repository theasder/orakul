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

    private func button(id: String, tier: String = "free", offline: Bool = true) -> String {
        """
        {"id": "\(id)", "label": "Кнопка", "prompt": "Достаточно длинный текст запроса",
         "tier": "\(tier)", "offline": \(offline), "adapted": "почему так"}
        """
    }

    @Test("вшитый каталог читается и проходит проверки")
    func bundledCatalogLoads() throws {
        let catalog = try PromptCatalog.bundled()
        #expect(catalog.locale == "ru-RU")
        #expect(catalog.buttons.count >= 6)
        #expect(catalog.recall != nil, "главная кнопка продукта пропала из каталога")
    }

    @Test("поиск по своим созвонам бесплатный — и это проверяется в сборке")
    func recallIsFree() throws {
        let catalog = try PromptCatalog.bundled()
        let recall = try #require(catalog.recall)
        #expect(recall.tier == .free)
        #expect(recall.offline)
    }

    @Test("бесплатная кнопка, которой нужна сеть, не собирается")
    func freeButtonMustBeOffline() {
        // Не «мы стараемся»: каталог с таким сочетанием не грузится вообще.
        let broken = json(button(id: "bad", tier: "free", offline: false))
        #expect(throws: PromptCatalog.LoadError.freeButtonRequiresNetwork("bad")) {
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

    @Test("уровни упорядочены: команда видит бесплатное, бесплатный — нет")
    func tierOrdering() throws {
        let catalog = try PromptCatalog.decode(json(
            button(id: "free-one") + "," +
            button(id: "team-one", tier: "team", offline: false) + "," +
            button(id: "company-one", tier: "company", offline: false)))

        #expect(catalog.available(for: .free).map(\.id) == ["free-one"])
        #expect(catalog.available(for: .team).map(\.id) == ["free-one", "team-one"])
        #expect(catalog.available(for: .company).count == 3)
    }

    @Test("без сети остаются только кнопки, считающиеся на устройстве")
    func offlineFiltering() throws {
        let catalog = try PromptCatalog.decode(json(
            button(id: "local") + "," +
            button(id: "remote", tier: "team", offline: false)))

        #expect(catalog.actionable(for: .company, online: true).count == 2)
        #expect(catalog.actionable(for: .company, online: false).map(\.id) == ["local"])
        // Бесплатный уровень без сети не теряет ничего — в этом весь уровень.
        #expect(catalog.actionable(for: .free, online: false).count
                == catalog.available(for: .free).count)
    }

    @Test("недоступная кнопка объясняет причину, а не молчит")
    func unavailabilityIsExplained() throws {
        let catalog = try PromptCatalog.decode(json(
            button(id: "local") + "," +
            button(id: "remote", tier: "team", offline: false)))
        let local = catalog.buttons[0]
        let remote = catalog.buttons[1]

        #expect(catalog.unavailabilityReason(for: local, tier: .free, online: false) == nil)
        // Не хватает уровня — говорим, какого именно.
        let byTier = catalog.unavailabilityReason(for: remote, tier: .free, online: true)
        #expect(byTier?.contains("Команда") == true)
        // Уровень есть, сети нет — причина другая, и она не про деньги.
        let byNetwork = catalog.unavailabilityReason(for: remote, tier: .team, online: false)
        #expect(byNetwork?.contains("сеть") == true)
        #expect(byNetwork?.contains("уровне") != true)
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
