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
        // Прежний замер брал 150 коротких звонков — 22 тыс. слов. Настоящий
        // часовой звонок это 15 тыс. слов сам по себе, и месяц таких —
        // 450 тыс. На этом масштабе видно то, чего не видно на коротких:
        // почти всё время уходило на обрезку окончаний, по 44 сравнения
        // суффикса на слово. Замерено: 4.1 с → 2.8 с → 0.4 с (последнее — три
        // прогона подряд, разброса нет). Число здесь легко устаревает: на
        // странице оно простояло «полторы секунды» до тех пор, пока его не
        // перемерили, и потолок в 12 секунд этого не ловил — он и не должен,
        // он про возврат к перебору списком. Связь потолка со страницей
        // держит landing.test.mjs.
        //
        // Бюджет с большим запасом: ловится возврат к перебору списком, а не
        // проценты. Индекс на диск не пишется намеренно — устаревший индекс
        // это отдельный класс поломок, а секунды здесь пока терпимы.
        let words = ["тарифы", "деплой", "релиз", "миграцию", "кеш", "промпт"]
        let sessions = (0..<20).map { index -> RecallIndex.Session in
            let body = (0..<900).map { line in
                "Спикер\(line % 4): Обсуждаем \(words[line % words.count]), "
                    + "длинная реплика номер \(line) про то, что делать дальше."
            }.joined(separator: "\n")
            return RecallIndex.Session(id: "s\(index)", title: "Звонок \(index)",
                                       date: "2026-08-13", digest: body)
        }
        let index = RecallIndex(sessions: sessions)

        let started = Date()
        let hits = index.search("что решили по тарифам")
        let elapsed = Date().timeIntervalSince(started)

        #expect(!hits.isEmpty, "поиск ничего не нашёл — замеряли пустую работу")
        let report = "поиск по 20 часовым звонкам занял "
            + String(format: "%.1f", elapsed) + " с"
        #expect(elapsed < 12, "\(report)")
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
}
