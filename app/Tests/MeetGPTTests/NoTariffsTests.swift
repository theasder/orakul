import Foundation
import Testing
@testable import MeetGPT

/// У orakul нет тарифов. Это свойство продукта, а не текущее состояние прайса,
/// и держится оно на одной строке в `Config.currentTier` — механика тарифов
/// внутри осталась от Cruxwing и легко оживает при следующем переносе изменений
/// сверху. Поэтому проверяется не «поле равно free», а то, ради чего это
/// делалось: ни одна функция не заперта и денег никто не просит.
@Suite("Тарифов нет", .serialized)
struct NoTariffsTests {

    @Test("доступны все модели, а не две из тринадцати")
    func everyModelIsAvailable() {
        // На бесплатном плане Cruxwing открыты две модели. Российскому
        // разработчику это выглядело бы как «остальное за деньги», которых
        // взять неоткуда: платить orakul не за что.
        let locked = LLMCatalog.all.filter { !$0.isAvailable(for: Config.currentTier) }
        #expect(locked.isEmpty,
                "заперты модели: \(locked.map(\.label).joined(separator: ", "))")
        #expect(LLMCatalog.all.count > 5, "каталог пуст — проверка была бы фиктивной")
    }

    @Test("платный экран не показывается ни при каком состоянии")
    func paywallNeverShows() {
        // Перебираются состояния, в которых Cruxwing его показывал: до ответа
        // на вопрос про подписку и после него.
        let savedChoice = Config.paywallChoiceMade
        let savedPurchase = Config.purchasedTier
        defer {
            Config.paywallChoiceMade = savedChoice
            Config.purchasedTier = savedPurchase
        }

        for choiceMade in [false, true] {
            Config.paywallChoiceMade = choiceMade
            Config.purchasedTier = nil
            #expect(!Config.shouldShowPaywall,
                    "экран с ценами показался (выбор сделан: \(choiceMade))")
        }
    }

    @Test("план не зависит от того, что записано в покупках")
    func purchaseCannotChangeAnything() {
        // Строка «pro» в настройках — след старого кода или чужой машины.
        // Она не должна ничего менять: менять нечего.
        let savedPurchase = Config.purchasedTier
        defer { Config.purchasedTier = savedPurchase }

        Config.purchasedTier = nil
        let withoutPurchase = Config.currentTier
        Config.purchasedTier = .pro
        #expect(Config.currentTier == withoutPurchase, "покупка сдвинула план")
        #expect(!Config.shouldShowPaywall)
    }

    @Test("подсказка собирается по всем источникам, а не по двум")
    func groundingIsNotRationed() {
        // Число источников — тоже тарифная ручка. Ограничение здесь незаметно:
        // ответ приходит, просто хуже.
        let candidates = (1...12).map { index in
            GroundingContextPolicy.SourceCandidate(
                id: "mcp:source-\(index)", searchableText: "тарифы лимиты выгрузка",
                strongFor: [])
        }
        let selected = GroundingContextPolicy.selectSources(
            candidates, query: "лимиты на выгрузку", tier: Config.currentTier,
            requestedLimit: nil)
        #expect(selected.count > 2,
                "источники урезаны до \(selected.count) — это тарифный лимит")
    }
}
