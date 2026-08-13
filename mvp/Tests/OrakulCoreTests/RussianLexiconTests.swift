import Foundation
import Testing
@testable import OrakulCore

/// Починка расшифровки умеет делать текст хуже — и ровно так уже случалось: на
/// английской стороне подсказка в декодере купила узнавание терминов ценой 2757
/// удалённых слов. Поэтому здесь проверяется не «починилось ли», а «не
/// испортилось ли»: обычная русская речь обязана пройти нетронутой.
@Suite("Русский словарь")
struct RussianLexiconTests {

    // MARK: - Что чинится

    @Test("аббревиатура приводится к заглавным латинским")
    func acronymsAreUpperCased() {
        #expect(RussianLexicon.restore("дёрнем api и посмотрим") == "дёрнем API и посмотрим")
    }

    @Test("заимствование приводится к кириллице")
    func loanwordsAreCanonical() {
        // Расшифровка русского созвона, где половина слов латиницей, читается
        // как чужая. Канон один и записан в словаре.
        #expect(RussianLexicon.restore("выкатили в Прод") == "выкатили в прод")
        #expect(RussianLexicon.restore("поправил ПРОМПТ") == "поправил промпт")
    }

    @Test("«ё» и «е» — одно слово")
    func yoIsHandled() {
        #expect(RussianLexicon.restore("сделали мерж") == "сделали мёрж")
    }

    @Test("дефисное слово чинится целиком, а не половинками")
    func hyphenatedTermsSurvive() {
        #expect(RussianLexicon.restore("открыл Пул-Реквест") == "открыл пул-реквест")
    }

    // MARK: - Что не должно чиниться (это важнее)

    @Test("«прод» внутри «продукта» не трогается")
    func substringsAreNotTouched() {
        // Замена по подстроке — самый быстрый способ испортить обычный текст.
        let sentence = "мы обсудили продукт и продажи, продвижение тоже"
        #expect(RussianLexicon.restore(sentence) == sentence)
    }

    @Test("обычные русские слова не входят в словарь")
    func ordinaryWordsAreExcluded() {
        // У каждого есть обиходное значение: страховой агент, модель поведения,
        // ветка дерева, образ жизни, очередь в магазине.
        let ordinary = ["агент", "модель", "ветка", "образ", "очередь", "канал"]
        let vocabulary = Set(RussianLexicon.allTerms.map { RussianLexicon.normalized($0) })
        for word in ordinary {
            #expect(!vocabulary.contains(word), "«\(word)» — слово языка, ему не место в словаре")
        }
    }

    @Test("обычная русская фраза проходит нетронутой")
    func plainRussianIsUntouched() {
        let sentence = "Давайте перенесём встречу на вторник и обсудим сроки по задаче."
        #expect(RussianLexicon.restore(sentence) == sentence)
    }

    @Test("починка не меняет количество слов")
    func wordCountIsPreserved() {
        // Свойство, а не пример: движок, который замолчал, дороже движка,
        // который ошибся. Пасс, умеющий терять слова, недопустим в принципе.
        let samples = [
            "выкатили в прод, поправили промпт и закрыли баг",
            "обычное предложение без единого термина вообще",
            "api, llm, rag — всё сразу в одной строке",
            "",
        ]
        for sample in samples {
            let before = sample.split(separator: " ").count
            let after = RussianLexicon.restore(sample).split(separator: " ").count
            #expect(before == after, "число слов изменилось: «\(sample)»")
        }
    }

    @Test("пунктуация и переносы строк сохраняются")
    func punctuationSurvives() {
        let sentence = "Прод — упал.\nОткатили релиз, завели баг!"
        let restored = RussianLexicon.restore(sentence)
        #expect(restored.contains("\n"))
        #expect(restored.contains("—"))
        #expect(restored.hasSuffix("!"))
    }

    @Test("повторный проход ничего не меняет")
    func restoreIsIdempotent() {
        // Пасс запускается после каждой расшифровки; накапливающиеся правки
        // означали бы, что текст дрейфует от прогона к прогону.
        let once = RussianLexicon.restore("выкатили в прод и дёрнули api")
        #expect(RussianLexicon.restore(once) == once)
    }

    // MARK: - Словарь как данные

    @Test("в словаре нет дублей")
    func noDuplicateTerms() {
        let normalized = RussianLexicon.allTerms.map { RussianLexicon.normalized($0) }
        #expect(Set(normalized).count == normalized.count, "дубль в словаре")
    }

    @Test("термины из замера покрыты словарём")
    func measuredTermsAreCovered() {
        // Ровно те слова, на которых движки разошлись на настоящем корпусе.
        // Если словарь их не покрывает, он не решает измеренную задачу.
        let vocabulary = Set(RussianLexicon.allTerms.map { RussianLexicon.normalized($0) })
        for term in ["прод", "промпт", "api", "джейлбрейк"] {
            #expect(vocabulary.contains(term), "измеренный спорный термин «\(term)» вне словаря")
        }
    }

    @Test("поиск терминов возвращает канон, а не то, как слово написали")
    func termsReturnCanonicalForms() {
        let found = RussianLexicon.terms(in: "дёрнули Api, выкатили ПРОД")
        #expect(found.contains("API"))
        #expect(found.contains("прод"))
    }

    @Test("английская расшифровка не кириллизуется")
    func englishTranscriptIsUntouched() {
        // Самый опасный случай таблицы вариантов: в английском созвоне «prod»
        // и «bug» — обычные слова, и переписать их кириллицей значит испортить
        // расшифровку, которую пользователь не просил переводить.
        let english = "We shipped to prod and closed the bug after review."
        #expect(RussianLexicon.restoreIfRussian(english) == english)
    }

    @Test("русская фраза с английскими терминами всё-таки чинится")
    func mixedRussianIsRepaired() {
        // Речь разработчика наполовину латиница — определитель языка на таком
        // тексте регулярно отвечает «английский», поэтому порог по доле букв.
        let mixed = "Выкатили в prod, поправили промпт и дёрнули api."
        let repaired = RussianLexicon.restoreIfRussian(mixed)
        #expect(repaired.contains("прод"))
        #expect(repaired.contains("API"))
        #expect(!repaired.contains("prod"))
    }

    @Test("порог определения языка выдерживает жаргон")
    func languageDetectionHandlesJargon() {
        #expect(RussianLexicon.looksRussian("поднимем LLM-фильтр в prod"))
        #expect(!RussianLexicon.looksRussian("deploy the LLM filter to prod"))
        // Пустой и технический текст не должен считаться русским: чинить там
        // нечего, а испортить есть что.
        #expect(!RussianLexicon.looksRussian(""))
        #expect(!RussianLexicon.looksRussian("git commit -m fix"))
    }


    @Test("канонический токен: термин, падеж или ничего",
          arguments: [("промпт", "промпт"), ("prompt", "промпт"), ("prompts", "промпт"),
                      ("деплою", "деплой"), ("коммита", "коммит"), ("фичи", "фича"),
                      ("апи", "api"), ("API", "api")])
    func canonicalTokenResolves(pair: (String, String)) {
        #expect(RussianLexicon.canonicalToken(for: pair.0) == pair.1)
    }

    @Test("слово не из словаря даёт nil, а не выдумку",
          arguments: ["продукт", "багаж", "cat", "совещание"])
    func unknownWordsHaveNoCanonicalToken(word: String) {
        // nil — это «решай сам»: командная строка обрежет окончание, приложение
        // оставит слово как есть. Вернуть здесь что-нибудь значит заставить оба
        // поиска находить то, чего не говорили.
        #expect(RussianLexicon.canonicalToken(for: word) == nil,
                "«\(word)» не термин, а словарь его присвоил")
    }

}

@Suite("Слова, которые говорят вслух, а пишут по-английски")
struct SpokenInfrastructureTests {
    /// Человек на созвоне говорит «дженкинс», а через месяц ищет «jenkins».
    /// Без канонизации это разные слова, и поиск честно отвечает «не
    /// говорили» — при том что говорили.
    @Test("сказанное по-русски находится по английскому запросу",
          arguments: [("дженкинс", "jenkins"), ("питон", "python"),
                      ("джава", "java"), ("кассандра", "cassandra"),
                      ("эйрфлоу", "airflow"), ("постман", "postman"),
                      ("сваггер", "swagger"), ("вебхук", "webhook"),
                      ("зукипер", "zookeeper")])
    func spokenMatchesWritten(spoken: String, written: String) {
        #expect(RussianLexicon.canonicalToken(for: spoken) == RussianLexicon.canonicalToken(for: written),
                "«\(spoken)» и «\(written)» остались разными словами для поиска")
    }

    /// Таблица только для поиска. Расшифровку она не трогает — иначе
    /// «постман» превратился бы в postman там, где речь о почтальоне, а
    /// «питон» в python там, где о змее.
    @Test("расшифровку эти слова не переписывают",
          arguments: ["постман", "питон", "джава", "кассандра"])
    func transcriptIsNotRewritten(word: String) {
        #expect(RussianLexicon.restore(word) == word,
                "слово из поисковой таблицы попало в починку расшифровки")
    }
}
