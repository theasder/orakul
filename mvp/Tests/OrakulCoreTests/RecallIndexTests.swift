import Foundation
import Testing
@testable import OrakulCore

/// Поиск по своим созвонам — это и есть продукт. Английская версия однажды
/// прошла все свои тесты и при этом не находила встречу по названию: каждый
/// кусок работал, целое — нет. Поэтому здесь проверяются не куски, а вопросы,
/// которые человек реально задаёт.
@Suite("Поиск по созвонам")
struct RecallIndexTests {

    private let index = RecallIndex(sessions: [
        .init(id: "s1", title: "Планёрка по тарифам", date: "2026-07-24",
              digest: """
              Решили перейти на оплату за использование, две копейки за кредит. \
              Сергей посчитает экономику к следующей неделе. \
              Вопрос про скидки отложили.
              """),
        .init(id: "s2", title: "Ретро спринта", date: "2026-07-25",
              digest: """
              Решили сократить дейли до пятнадцати минут. \
              Ответственный не назван. \
              Задачи зависают в ревью.
              """),
        .init(id: "s3", title: "Архитектура хранилища", date: "2026-07-28",
              digest: """
              Решили взять PostgreSQL вместо своего формата. \
              Миграцию делаем после релиза, иначе не успеваем. \
              Кеш пока оставляем как есть.
              """),
    ])

    @Test("вопрос про тарифы находит планёрку по тарифам")
    func findsByTopic() {
        let hits = index.search("что мы решили по тарифам?")
        #expect(hits.first?.session.id == "s1")
        // Цитата обязана показывать, за что встреча найдена.
        #expect(hits.first?.excerpt.contains("оплату за использование") == true)
    }

    @Test("цитата отвечает на вопрос, а не подтверждает тему")
    func excerptPrefersTheAnswer() {
        // Найдено запуском собранной программы, а не тестом: «Обсудили тарифы»
        // и «Решили перейти...» совпадают с вопросом одним словом каждая, и по
        // порядку побеждала первая — то есть та, которая ничего не отвечает.
        let sessions = [RecallIndex.Session(
            id: "s1", title: "Планёрка", date: "2026-07-24",
            digest: "Обсудили тарифы. Решили перейти на оплату за использование, "
                  + "две копейки за кредит.")]
        let hit = RecallIndex(sessions: sessions).search("что решили по тарифам").first
        #expect(hit?.excerpt.contains("оплату за использование") == true,
                "цитатой стало «\(hit?.excerpt ?? "")» — это не ответ на вопрос")
    }

    @Test("вопрос по названию встречи находит её же")
    func findsByName() {
        // Ровно тот случай, на котором провалился поиск по смыслу: «ретро» —
        // имя встречи, а не её тема.
        #expect(index.search("что было на ретро").first?.session.id == "s2")
        #expect(index.search("планёрка по тарифам").first?.session.id == "s1")
    }

    @Test("падежи не мешают: «тарифам», «тарифами», «тарифах» — одно слово")
    func inflectionIsHandled() {
        for query in ["решение по тарифам", "что с тарифами", "вопрос о тарифах"] {
            #expect(index.search(query).first?.session.id == "s1", "не нашлось: \(query)")
        }
    }

    @Test("термин находится независимо от регистра, которым его записали")
    func termsSurviveCasing() {
        #expect(index.search("почему выбрали postgresql").first?.session.id == "s3")
    }

    @Test("синонима не понимает — и это зафиксировано, а не замаскировано")
    func synonymsAreNotUnderstood() {
        // «Цены» и «тарифы» для лексического поиска разные слова. Пока
        // синонимов нет, вопрос про цены найдёт планёрку только по слову
        // «решили» — то есть по случайности. Тест существует, чтобы это
        // ограничение было видно в отчёте, а не всплыло у пользователя.
        let sessions = [RecallIndex.Session(id: "s1", title: "Планёрка по тарифам",
                                            date: "2026-07-24",
                                            digest: "Перешли на оплату за использование.")]
        #expect(RecallIndex(sessions: sessions).search("что с ценами").isEmpty,
                "если это перестало быть пустым — появились синонимы, и комментарий устарел")
    }

    @Test("вопрос без общих слов не находит ничего")
    func unrelatedQueryFindsNothing() {
        // Пустой ответ честнее выдуманного: продукт обещает цитату, а цитировать
        // тут нечего.
        #expect(index.search("когда корпоратив и где касса").isEmpty)
    }

    @Test("одни служебные слова — не запрос")
    func stopwordsOnly() {
        #expect(index.search("а что если и как").isEmpty)
        #expect(index.search("").isEmpty)
    }

    @Test("редкое слово весит больше частого")
    func rarityBeatsFrequency() {
        // «Релиз» встречается в одном созвоне, «решили» — в нескольких.
        #expect(index.search("что решили про релиз").first?.session.id == "s3")
    }

    @Test("совпадение в названии весит больше, чем в тексте")
    func titleOutweighsBody() {
        let sessions = [
            RecallIndex.Session(id: "body", title: "Случайный созвон", date: "2026-07-01",
                                digest: "Мимоходом упомянули хранилище и пошли дальше."),
            RecallIndex.Session(id: "title", title: "Хранилище", date: "2026-07-02",
                                digest: "Обсудили сроки."),
        ]
        #expect(RecallIndex(sessions: sessions).search("хранилище").first?.session.id == "title")
    }

    @Test("пустой архив не выдумывает ответов")
    func emptyIndex() {
        #expect(RecallIndex(sessions: []).search("что решили по тарифам").isEmpty)
    }

    @Test("цитата пустая, если совпало только название")
    func excerptOnlyWhenGrounded() {
        // Лучше пустая цитата, чем первое предложение, выданное за основание:
        // читатель проверяет ответ именно по ней.
        let sessions = [RecallIndex.Session(id: "t", title: "Кубернетес", date: "2026-07-02",
                                            digest: "Обсудили сроки и разошлись.")]
        let hit = RecallIndex(sessions: sessions).search("кубернетес").first
        #expect(hit != nil)
        #expect(hit?.excerpt.isEmpty == true)
    }

    @Test("порядок выдачи не зависит от порядка встреч в архиве")
    func rankingIsStable() {
        let forward = index.search("что решили по тарифам").map(\.session.id)
        let reversed = RecallIndex(sessions: index.sessions.reversed())
            .search("что решили по тарифам").map(\.session.id)
        #expect(forward == reversed)
    }

    @Test("выдача ограничена и не вываливает весь архив")
    func limitIsRespected() {
        #expect(index.search("решили", limit: 1).count <= 1)
    }
}

/// Поиск через границу алфавита.
///
/// §6.2 плана: русская речь разработчиков — код-свитчинг, и движки расходятся
/// не в слухе, а в АЛФАВИТЕ. Whisper пишет `Prompt`, Parakeet — «Промпт».
/// Словарь заводили ровно для этого — и он чинил только расшифровку.
///
/// Запрос никто не канонизировал: в архиве лежал «промпт», человек искал
/// `prompt` — то самое слово, которое произнёс, — и не находил ничего. Отказ
/// звучал как «в звонках об этом не говорили», хотя говорили именно об этом.
@Suite("Кросс-алфавитный поиск")
struct CrossAlphabetSearchTests {

    private func index() -> RecallIndex {
        RecallIndex(sessions: [
            .init(id: "s1", title: "Планёрка",
                  date: "2026-08-12",
                  digest: "Мы поменяли промпт для модели и выкатили на прод."),
        ])
    }

    @Test("латинское написание находит канон, записанный кириллицей",
          arguments: ["prompt", "промпт", "prod", "прод"])
    func eitherAlphabetFindsTheCall(query: String) {
        #expect(!index().search(query).isEmpty,
                "«\(query)» не нашёл звонок, где это слово прозвучало")
    }

    @Test("обе формы дают один и тот же токен")
    func bothSpellingsStemToOneToken() {
        // Суть починки: канон — общая точка. Если формы расходятся, совпадение
        // получается случайно и ломается на следующем термине.
        #expect(RecallIndex.stem("prompt") == RecallIndex.stem("промпт"))
        #expect(RecallIndex.stem("prod") == RecallIndex.stem("прод"))
        #expect(RecallIndex.stem("апи") == RecallIndex.stem("API"))
    }

    @Test("слово не из словаря по-прежнему не переводится между алфавитами")
    func unknownWordsAreNotTransliterated() {
        // Границы починки: словарь — таблица измеренных терминов, а не
        // транслитератор. «cat» не должен становиться «кот», иначе поиск начнёт
        // находить то, чего не говорили, — а это дороже, чем не найти.
        #expect(index().search("cat").isEmpty)
        #expect(RecallIndex.stem("cat") == "cat")
    }

    @Test("отказ остаётся отказом, когда слова действительно не было")
    func absentWordStillRefuses() {
        #expect(index().search("корпоратив").isEmpty)
    }
}

/// Падежи терминов словаря.
///
/// Страница и README обещают: падежи понимаются. Для обычных слов это делала
/// обрезка окончаний, а для терминов — не делал никто: термин возвращался
/// каноном без обрезки, а его падеж обрезался как обычное слово. «деплой» и
/// «деплою» получали разные токены, и человек не находил свой же звонок.
///
/// Обрезать термины по-прежнему нельзя, и это не вкусовщина: у «коммит» на
/// конце «ит», у «деплой» — «ой». Попытка причесать обе стороны одной обрезкой
/// починила «деплою» и сломала «коммита» — поэтому падежи лежат таблицей.
@Suite("Падежи терминов")
struct TermInflectionTests {

    @Test("падеж термина даёт тот же токен, что сам термин",
          arguments: [
            ("деплой", "деплою"), ("деплой", "деплоя"), ("деплой", "деплое"),
            ("коммит", "коммита"), ("коммит", "коммиты"), ("коммит", "коммитов"),
            ("фича", "фичи"), ("фича", "фиче"), ("баг", "баги"), ("баг", "бага"),
            ("промпт", "промпты"), ("кеш", "кеша"), ("релиз", "релиза"),
            ("миграция", "миграции"),
          ])
    func inflectionCollapsesToTheTerm(pair: (String, String)) {
        let left = RecallIndex.stem(pair.0)
        let right = RecallIndex.stem(pair.1)
        #expect(left == right,
                "«\(pair.0)» и «\(pair.1)» разошлись: \(left) против \(right)")
    }

    @Test("термин сам по себе не обрезается")
    func termsAreNeverStripped() {
        // Регрессия, которую поймала мутация: обрезка канона превращает
        // «коммит» в «комм», а «деплой» — в «депл», и термин перестаёт
        // совпадать сам с собой в архиве.
        for term in ["коммит", "деплой", "релиз", "докер"] {
            #expect(RecallIndex.stem(term) == term,
                    "термин «\(term)» обрезали до «\(RecallIndex.stem(term))»")
        }
    }

    @Test("английское множественное латинского написания тоже находит")
    func latinPluralResolves() {
        // Человек, привыкший писать термин латиницей, наберёт `prompts`.
        #expect(RecallIndex.stem("prompts") == RecallIndex.stem("промпт"))
    }

    @Test("порождённая форма не крадёт чужой термин")
    func generatedFormsNeverShadowRealTerms() {
        // Порождение механическое, и оно может выдать строку, которая сама
        // является термином. Такая форма должна остаться термином.
        let inflections = RussianLexicon.inflections()
        for term in RussianLexicon.allTerms {
            let key = RussianLexicon.normalized(term)
            #expect(inflections[key] == nil,
                    "форма перекрыла настоящий термин «\(term)»")
        }
    }

    @Test("обычные слова падежами терминов не становятся")
    func ordinaryWordsAreUntouched() {
        // Таблица закрытая: «продукт» не должен стать «прод», «багаж» — «баг».
        for word in ["продукт", "багаж", "фичуринг", "коммитет"] {
            #expect(RussianLexicon.inflections()[word] == nil,
                    "обычное слово «\(word)» попало в таблицу падежей")
        }
    }
}

/// Цитата вместе с тем, кто её сказал.
///
/// Обещание продукта — ответ ЦИТАТОЙ из звонка. Цитата без говорящего это
/// обещание выполняет наполовину: слова есть, а переспросить некого.
///
/// Разрыв нашёлся живым прогоном: реплика «Борис: Обсудили деплой. Выкатываем
/// в пятницу…» на запрос «пятницу» отвечала «Выкатываем в пятницу, откат
/// готовим заранее» — без имени. Резали по «.!?» на всей расшифровке сразу, и
/// говорящий доставался только первому предложению строки.
@Suite("Говорящий в цитате")
struct ExcerptAttributionTests {

    private let digest = """
    Борис: Обсудили деплой. Выкатываем в пятницу, откат готовим заранее.
    Вера: Про тарифы вскользь: клиенты жалуются на цену.
    Аня: Кто дежурит?
    """

    private func excerpt(_ query: String) -> String {
        RecallIndex.excerpt(for: Set(RecallIndex.tokens(query)), in: digest)
    }

    @Test("не первое предложение реплики тоже подписано")
    func laterSentenceKeepsTheSpeaker() {
        let quote = excerpt("пятницу")
        #expect(quote.hasPrefix("Борис:"),
                "цитата без говорящего: «\(quote)»")
        #expect(quote.contains("пятницу"))
    }

    @Test("первое предложение подписано как и раньше")
    func firstSentenceIsUnchanged() {
        #expect(excerpt("деплой") == "Борис: Обсудили деплой")
    }

    /// «Что говорила Вера» — вопрос, который задают этому продукту постоянно,
    /// и на него отвечали «точных слов по вашему вопросу в расшифровке нет».
    /// Имя отрезалось `splitSpeaker` до сравнения, поэтому в совпадение не
    /// входило никогда. Указатель имя знал и звонок находил — пустой была
    /// именно цитата, и человек читал приговор про того, кто на звонке говорил.
    @Test("вопрос по имени говорящего цитируется", arguments: [
        ("вера", "Вера:"),
        ("борис", "Борис:"),
        ("что говорила вера", "Вера:"),
    ])
    func speakerNameIsQuotable(_ query: String, _ ожидается: String) {
        let quote = excerpt(query)
        #expect(quote.hasPrefix(ожидается), "на «\(query)» вышло: «\(quote)»")
    }

    /// Сквозь весь продукт, а не только через `excerpt`: до починки поиск
    /// возвращал звонок, а составитель ответа говорил, что цитировать нечего.
    @Test("на имя говорящего продукт отвечает цитатой, а не отказом")
    func speakerQuestionGetsAnAnswer() {
        let index = RecallIndex(sessions: [
            RecallIndex.Session(id: "1", title: "Планёрка", date: "2026-08-14",
                                digest: digest),
        ])
        let ответ = RecallAnswer.compose(query: "что говорила вера",
                                         hits: index.search("что говорила вера"))
        #expect(ответ.contains("Вера:"), "получилось: \(ответ)")
        #expect(!ответ.contains("цитировать нечего"), "получилось: \(ответ)")
    }

    /// Имя не должно перебивать существо вопроса: спросили про тарифы у Веры —
    /// получите её реплику про тарифы, а не первую попавшуюся её строку.
    @Test("имя не вытесняет слова вопроса")
    func nameDoesNotOutrankTheQuestion() {
        #expect(excerpt("вера тарифы").contains("тариф"),
                "получилось: «\(excerpt("вера тарифы"))»")
    }

    /// Слово, которого нет ни в речи, ни в именах, цитаты по-прежнему не даёт:
    /// иначе починка превратила бы отказ в выдумку.
    @Test("чужое слово цитаты не получает")
    func unrelatedWordStillHasNoQuote() {
        #expect(excerpt("криптовалюта").isEmpty)
    }

    @Test("двоеточие внутри фразы не принимается за говорящего")
    func midSentenceColonIsNotASpeaker() {
        // «Про тарифы вскользь: клиенты жалуются» — двоеточие есть, говорящего
        // в этом месте нет. Иначе цитата подписывалась бы обрывком фразы.
        let quote = excerpt("жалуются")
        #expect(quote.hasPrefix("Вера:"), "подписано не тем: «\(quote)»")
        #expect(quote.contains("вскользь: клиенты"),
                "фразу разрезали по внутреннему двоеточию: «\(quote)»")
    }

    @Test("длинное имя не перевешивает содержательную фразу")
    func longSpeakerNameDoesNotWinOverContent() {
        // При равном совпадении побеждает более содержательная фраза. Если
        // мерить длину ВМЕСТЕ с подписью, победа достаётся тому, у кого длиннее
        // имя, — и человек получает «Тарифы да» вместо ответа по существу.
        let digest = """
        Константин Александрович Петров: Тарифы да.
        Ян: Тарифы решили не поднимать до декабря.
        """
        let quote = RecallIndex.excerpt(for: Set(RecallIndex.tokens("тарифы")), in: digest)
        #expect(quote.hasPrefix("Ян:"), "выбрана менее содержательная цитата: «\(quote)»")
        #expect(quote.contains("не поднимать"))
    }

    @Test("строка без говорящего остаётся как есть")
    func lineWithoutSpeakerIsLeftAlone() {
        let plain = RecallIndex.excerpt(for: Set(RecallIndex.tokens("релиз")),
                                        in: "Договорились про релиз в среду.")
        #expect(plain == "Договорились про релиз в среду")
    }

    @Test("разбор подписи: что считается именем")
    func speakerSplitBoundaries() {
        #expect(RecallIndex.splitSpeaker("Борис: привет").0 == "Борис")
        // Длинное начало — не имя, а фраза с двоеточием.
        let long = String(repeating: "а", count: 41) + ": хвост"
        #expect(RecallIndex.splitSpeaker(long).0 == nil)
        // Знаки конца предложения до двоеточия — тоже не имя.
        #expect(RecallIndex.splitSpeaker("Так вот. Итог: поехали").0 == nil)
        // Пустой хвост — не реплика.
        #expect(RecallIndex.splitSpeaker("Борис:").0 == nil)
    }
}

/// Поиск должен оставаться быстрым на настоящем архиве.
///
/// Нашлось живым замером, а не тестом: один поиск по 20 звонкам занимал 118
/// секунд, по 200 — не заканчивался вовсе. Причина — `stem` спрашивал
/// `canonicalForms()` и `inflections()` на КАЖДОЕ слово, а `inflections()`
/// внутри своего цикла звал `canonicalForms()` ещё раз. Таблицы перестраивались
/// тысячи раз за один запрос.
///
/// Ни один тест этого не видел: во всех архивах по две-три фразы, где разница
/// незаметна. Поэтому здесь архив настоящего размера.
///
/// Запас намеренно огромный. Проверка ловит не «медленнее на 20%», а возврат
/// той самой ошибки: до починки этот прогон занял бы минуты.
@Suite("Скорость поиска")
struct SearchPerformanceTests {

    private func archive(sessions: Int) -> RecallIndex {
        let words = ["деплой", "релиз", "коммит", "фича", "баг", "промпт",
                     "кеш", "докер", "миграция", "тарифы", "клиенты", "решили"]
        var generator = SystemRandomNumberGenerator()
        let sessions = (0..<sessions).map { index in
            let body = (0..<6).map { speaker in
                "Спикер\(speaker): " + (0..<25)
                    .map { _ in words.randomElement(using: &generator)! }
                    .joined(separator: " ")
            }.joined(separator: "\n")
            return RecallIndex.Session(id: "s\(index)", title: "Звонок \(index)",
                                       date: "2026-08-12", digest: body)
        }
        return RecallIndex(sessions: sessions)
    }

    // MARK: - Вопрос против ответа

    @Test("на вопрос показывается и то, что ответили")
    func answerFollowsTheQuestion() {
        // Найдено прогоном быстрого старта из README дословно. Спрашиваешь
        // «что решили по тарифам» — и получаешь строку Ани «По тарифам — что
        // решили в итоге», то есть свой же вопрос. Решение стоит следующей
        // строкой и со словами запроса не пересекается вовсе, поэтому
        // словарным поиском оно недостижимо в принципе.
        //
        // Для продукта, чьё обещание — «отвечает цитатой из того звонка»,
        // процитировать вопрос значит не ответить. Следующая реплика берётся
        // дословно и с именем говорящего: это не додумывание, а соседний текст
        // расшифровки, и человек сам видит, кто что сказал.
        let digest = """
        Аня: По тарифам — что решили в итоге?
        Борис: Годовой не трогаем до декабря, месячный поднимаем на пятнадцать процентов.
        """
        let index = RecallIndex(sessions: [.init(id: "1", title: "Планёрка",
                                                 date: "2026-08-13", digest: digest)])
        let hit = index.search("что решили по тарифам").first
        let excerpt = hit?.excerpt ?? ""

        #expect(excerpt.contains("Годовой не трогаем"),
                "ответ не показан, процитирован только вопрос: «\(excerpt)»")
    }

    @Test("утвердительная находка не тянет за собой соседа")
    func statementDoesNotPullTheNextLine() {
        // Граница: если приклеивать следующую строку ко всему подряд, ответ
        // раздуется чужими репликами, а часть из них будет не по делу.
        let digest = """
        Борис: По тарифам подняли месячный на пятнадцать процентов.
        Аня: Кто идёт на конференцию в ноябре?
        """
        let index = RecallIndex(sessions: [.init(id: "1", title: "Планёрка",
                                                 date: "2026-08-13", digest: digest)])
        let excerpt = index.search("что решили по тарифам").first?.excerpt ?? ""

        #expect(excerpt.contains("подняли месячный"), "находка потерялась")
        #expect(!excerpt.contains("конференцию"),
                "к утверждению приклеилась чужая реплика: «\(excerpt)»")
    }

    @Test("вопрос последней строкой не выдумывает ответа")
    func questionAtTheEndStaysAlone() {
        // И край: отвечать было некому — значит, и показывать нечего.
        let digest = "Аня: По тарифам — что решили в итоге?"
        let index = RecallIndex(sessions: [.init(id: "1", title: "Планёрка",
                                                 date: "2026-08-13", digest: digest)])
        let excerpt = index.search("что решили по тарифам").first?.excerpt ?? ""

        #expect(excerpt.contains("что решили в итоге"), "вопрос потерялся")
        #expect(excerpt.split(separator: "\n").count == 1,
                "к одинокому вопросу приписано что-то ещё: «\(excerpt)»")
    }

    @Test("поиск по 150 звонкам укладывается в секунды, а не минуты")
    func searchStaysFastOnARealArchive() {
        let index = archive(sessions: 150)
        let started = Date()
        let hits = index.search("что решили по деплою")
        let elapsed = Date().timeIntervalSince(started)

        #expect(!hits.isEmpty, "поиск ничего не нашёл — замеряли пустую работу")
        #expect(elapsed < 10,
                "поиск занял \(String(format: "%.1f", elapsed)) с: таблицы снова строятся на каждое слово")
    }

    @Test("двадцать вопросов подряд не стоят двадцати разборов архива")
    func repeatedQuestionsReuseTheParsedArchive() {
        // Разбор встреч происходит один раз, при создании индекса. Но самой
        // дорогой частью оставалась цитата: она заново разбирает расшифровку
        // по строкам и предложениям, и считалась для КАЖДОГО совпадения —
        // а в выдачу идут пять. Замерено: повторный поиск стоил столько же,
        // сколько первый (750 мс), хотя индекс уже был разобран; после
        // починки — 175 мс.
        //
        // Двадцать вопросов, потому что один тонет в шуме, а разница здесь
        // кратная.
        var sessions: [RecallIndex.Session] = []
        for index in 0..<20 {
            var lines: [String] = []
            for line in 0..<900 {
                let word: String = ["тарифы", "деплой", "релиз"][line % 3]
                lines.append("Спикер: Обсуждаем " + word + " реплика " + String(line))
            }
            sessions.append(RecallIndex.Session(id: "s" + String(index), title: "Звонок",
                                                date: "2026-08-13",
                                                digest: lines.joined(separator: "\n")))
        }
        let index = RecallIndex(sessions: sessions)

        let started = Date()
        for _ in 0..<20 { _ = index.search("что решили по тарифам") }
        let elapsed = Date().timeIntervalSince(started)

        let report = "двадцать вопросов заняли " + String(format: "%.1f", elapsed)
            + " с — цитаты снова считаются для всех совпадений"
        #expect(elapsed < 10, "\(report)")
    }

    @Test("цитата считается только для того, что попало в выдачу")
    func excerptsAreBuiltOnlyForReturnedHits() {
        // Структурно и точно: бюджет по времени ловит обвал, а эту починку
        // легко откатить, оставшись внутри любого честного порога.
        let source = try! String(contentsOfFile: Self.sourcePath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("Hit(session: session, score: score, excerpt: \"\")"),
                "цитата снова считается до отбора пяти лучших")
        #expect(code.contains("best.map"),
                "выдача больше не строит цитаты отдельным проходом")
    }

    @Test("окончания ищутся по длине, а не перебором списка")
    func endingsAreIndexedByLength() {
        // Бюджет по времени ловит обвал, но не эту починку: возврат к перебору
        // даёт 4.1 с вместо 2.8 с — внутри любого честного порога. А ужать
        // порог до 3.5 с значит завести проверку, которая падает от загрузки
        // машины. Поэтому сама структура проверяется отдельно и точно.
        let source = try! String(contentsOfFile: Self.sourcePath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("endingsByLength"),
                "обрезка окончаний вернулась к перебору всего списка")
        #expect(!code.contains("for ending in endings where"),
                "перебор списка окончаний вернулся на горячий путь")
    }

    static let sourcePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OrakulCore/RecallIndex.swift").path

    @Test("месяц часовых звонков ищется секундами, а не минутами")
    func searchStaysUsableOnFullLengthCalls() {
        // Часовой звонок — 15 тыс. слов, месяц таких — 450 тыс. Корпус здесь
        // именно такой: 30 звонков по 1250 реплик, 412 тыс. слов, 37.5 тыс.
        // строк. Раньше он был вдвое меньше (20 звонков по 900 строк, 216 тыс.
        // слов), а комментарий и страница говорили про 450 тыс. — число
        // называли, а не мерили.
        //
        // Меряются обе половины, потому что человек ждёт обе. Разбор слов
        // делается один раз при создании указателя, и командная строка платит
        // за него на каждый вопрос: индекс на диск не пишется намеренно —
        // устаревший индекс это отдельный класс поломок. Замер 14 августа,
        // три прогона: указатель 3.5 с, поиск 0.7 с, всего 4.2 с. После того
        // как основы стали считаться один раз на слово, а не на каждое
        // вхождение: 1.8 / 0.45 / 2.3.
        //
        // Потолок с большим запасом: он ловит возврат к перебору списком, а не
        // проценты. Связь потолка со страницей держит landing.test.mjs.
        let words = ["тарифы", "деплой", "релиз", "миграцию", "кеш", "промпт"]
        let sessions = (0..<30).map { index -> RecallIndex.Session in
            let body = (0..<1250).map { line in
                "Спикер\(line % 4): Обсуждаем \(words[line % words.count]), "
                    + "длинная реплика номер \(line) про то, что делать дальше."
            }.joined(separator: "\n")
            return RecallIndex.Session(id: "s\(index)", title: "Звонок \(index)",
                                       date: "2026-08-13", digest: body)
        }
        let totalWords = sessions.reduce(0) { $0 + $1.digest.split(separator: " ").count }
        #expect(totalWords > 400_000, "корпус меньше месяца звонков: \(totalWords) слов")

        // Холодный кэш: иначе замер покажет не стоимость разбора, а то, что
        // успели разобрать соседние проверки в этом же процессе.
        RecallIndex.stemCache.resetForTesting()
        let buildStarted = Date()
        let index = RecallIndex(sessions: sessions)
        let building = Date().timeIntervalSince(buildStarted)

        let started = Date()
        let hits = index.search("что решили по тарифам")
        let searching = Date().timeIntervalSince(started)
        let elapsed = building + searching
        print(String(format: "поиск по месяцу звонков: указатель %.2f с, поиск %.2f с, всего %.2f с",
                     building, searching, elapsed))

        #expect(!hits.isEmpty, "поиск ничего не нашёл — замеряли пустую работу")
        let report = "месяц звонков (30 часовых, 412 тыс. слов) занял "
            + String(format: "%.1f", elapsed) + " с — указатель "
            + String(format: "%.1f", building) + " с, поиск "
            + String(format: "%.1f", searching) + " с"
        #expect(elapsed < 12, "\(report)")
    }

    /// Подсказка про опечатку не должна стоить второго разбора архива.
    ///
    /// Первая её редакция ради написаний слов заново разбирала весь архив на
    /// слова: на 600 тыс. слов промах стоил лишних 1,8 секунды — столько же,
    /// сколько построение указателя. Замерено запуском, а не выведено из кода.
    /// Теперь похожее ищется по уже разобранным основам, а до текста дело
    /// доходит только ради тех немногих основ, что нашлись.
    ///
    /// Сравнение идёт с построением указателя в том же прогоне, а не с
    /// абсолютным потолком: занятость машины сдвигает оба числа разом, и
    /// отношение переживает шумного соседа, а секунды — нет.
    @Test("подсказка про опечатку не стоит второго разбора архива")
    func suggestionDoesNotReparseTheArchive() {
        let words = ["тарифы", "деплой", "релиз", "миграцию", "кеш", "промпт"]
        let sessions = (0..<30).map { index -> RecallIndex.Session in
            let body = (0..<1250).map { line in
                "Спикер\(line % 4): Обсуждаем \(words[line % words.count]), "
                    + "длинная реплика номер \(line) про то, что делать дальше."
            }.joined(separator: "\n")
            return RecallIndex.Session(id: "s\(index)", title: "Звонок \(index)",
                                       date: "2026-08-14", digest: body)
        }

        RecallIndex.stemCache.resetForTesting()
        let buildStarted = Date()
        let index = RecallIndex(sessions: sessions)
        let building = Date().timeIntervalSince(buildStarted)

        let started = Date()
        let подсказки = index.nearMisses(for: "тарифф")
        let suggesting = Date().timeIntervalSince(started)
        print(String(format: "подсказка на месяце звонков: %.3f с против разбора %.2f с",
                     suggesting, building))

        // Пустой ответ здесь означал бы, что замеряли работу, которой не было.
        #expect(подсказки.contains("тарифы"), "подсказка не нашлась: \(подсказки)")
        let отчёт = String(format: "подсказка заняла %.2f с при разборе %.2f с — "
                           + "похоже на второй разбор архива", suggesting, building)
        #expect(suggesting < building / 2, "\(отчёт)")
    }

    @Test("повторные запросы не дорожают")
    func repeatedSearchesDoNotDegrade() {
        // Если таблицы строятся заново, стоимость растёт с числом слов в
        // запросе. Длинный запрос ловит это раньше короткого.
        let index = archive(sessions: 60)
        let started = Date()
        for _ in 0..<5 {
            _ = index.search("что решили по деплою и релизу про коммит и фичу")
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10,
                "пять запросов заняли \(String(format: "%.1f", elapsed)) с")
    }

    /// Кэш основ обязан отвечать то же, что счёт без него, — иначе он ускоряет
    /// неправильный ответ. Обязан попадать (иначе он бесполезен, а замер
    /// показывает то же время). И обязан быть ограничен: у приложения процесс
    /// живёт днями, без предела он копил бы каждое услышанное слово.
    @Test("кэш основ отвечает то же, попадает и не растёт без предела")
    func stemCacheIsHonestUsefulAndBounded() {
        RecallIndex.stemCache.resetForTesting()
        let words = ["развёртыванием", "тарифам", "коммита", "годовым",
                     "джира", "постгресу", "решение", "Kubernetes-кластер"]
        let cold = words.map(RecallIndex.stem)
        let warm = words.map(RecallIndex.stem)
        #expect(cold == warm, "с кэшем и без него основы разошлись: \(cold) / \(warm)")

        // Кэш обязан ПОПАДАТЬ, а не просто существовать: если ключ не совпадает
        // с тем, что ищут, он молча не работает и остаётся лишней памятью.
        // Спрашиваем кэш тем же ключом, каким пользуется `stem`.
        //
        // Считать записи здесь нельзя: проверки идут параллельно в одном
        // процессе и разбирают свои слова в тот же кэш. Первая версия сравнивала
        // счётчик до и после — и падала через раз от соседей, а не от ошибки.
        for (word, expected) in zip(words, cold) {
            #expect(RecallIndex.stemCache.value(for: word) == expected,
                    "кэш не отвечает по ключу «\(word)» — значит не попадает")
        }

        // Предел проверяется на своём экземпляре, а не на общем: проверки идут
        // параллельно, и замер скорости в этом же наборе сбрасывает общий кэш
        // ради холодного старта. Первая версия считала записи в общем — и
        // мутация «снять предел» проходила зелёной, потому что сосед успевал
        // очистить кэш посреди счёта. В одиночку та же мутация падала: набор,
        // который ловит ошибку по одному, но не целиком, — ненадёжный набор.
        let own = RecallIndex.StemCache()
        for i in 0..<60_000 { own.store("основа", for: "слово\(i)") }
        #expect(own.countForTesting() <= 50_000,
                "кэш растёт без предела: \(own.countForTesting())")
        own.store("тариф", for: "тарифам")
        #expect(own.value(for: "тарифам") == "тариф", "запись не читается обратно")
        own.resetForTesting()
        #expect(own.countForTesting() == 0, "сброс не работает")
    }
}
