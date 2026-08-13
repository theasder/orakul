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

@Suite("Экрана с ценами нет в исходниках")
struct NoPricingScreenTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetGPTTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/MeetGPT")
    }

    /// Экран был выключен флагом, но лежал в исходниках: 471 строка с
    /// заголовком «Тарифы orakul» и планами. Репозиторий открытый, и это
    /// первое, что находит любой, кто решит проверить обещание «бесплатно,
    /// целиком». Выключенное — не то же самое, что удалённое.
    @Test("файлов платного экрана не осталось")
    func pricingViewIsGone() throws {
        let manager = FileManager.default
        let walker = try #require(manager.enumerator(atPath: sources.path))
        let offenders = walker.compactMap { $0 as? String }.filter {
            $0.hasSuffix("PaywallView.swift") || $0.contains("/Paywall/PaywallView")
        }
        #expect(offenders.isEmpty, "экран с ценами вернулся: \(offenders)")
    }

    @Test("ни одно представление не открывает экран с ценами")
    func nothingPresentsPricing() throws {
        let manager = FileManager.default
        let walker = try #require(manager.enumerator(atPath: sources.path))
        var offenders: [String] = []
        var scanned = 0
        for case let path as String in walker where path.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(path),
                                  encoding: .utf8)
            scanned += 1
            if text.contains("PaywallView(") { offenders.append(path) }
        }
        #expect(scanned > 50, "обход не нашёл исходников — проверка была бы фиктивной")
        #expect(offenders.isEmpty, "экран с ценами снова показывают: \(offenders)")
    }
}
