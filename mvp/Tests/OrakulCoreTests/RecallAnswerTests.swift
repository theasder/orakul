import Foundation
import Testing
@testable import OrakulCore

/// Ответ — то место, где продукт может соврать. Всё остальное чинится
/// следующей версией; сочинённое решение чужого созвона человек унесёт в
/// работу.
@Suite("Ответ на вопрос")
struct RecallAnswerTests {

    private func hit(_ id: String, _ title: String, date: String = "2026-07-24",
                     excerpt: String) -> RecallIndex.Hit {
        RecallIndex.Hit(
            session: RecallIndex.Session(id: id, title: title, date: date, digest: excerpt),
            score: 1, excerpt: excerpt)
    }

    @Test("ответ показывает встречу, дату и точные слова")
    func answerCarriesItsEvidence() {
        let answer = RecallAnswer.compose(
            query: "что решили по тарифам",
            hits: [hit("s1", "Планёрка по тарифам",
                       excerpt: "Решили перейти на оплату за использование")])

        #expect(answer.contains("«Планёрка по тарифам»"))
        #expect(answer.contains("24 июля 2026"))
        #expect(answer.contains("Решили перейти на оплату за использование"))
    }

    @Test("нет цитаты — нет ответа, и это сказано прямо")
    func withoutQuoteThereIsNoAnswer() {
        // Встреча нашлась по названию, но нужных слов в расшифровке нет.
        // Соблазн — пересказать итог своими словами; запрет — здесь.
        let answer = RecallAnswer.compose(
            query: "что решили по отпускам",
            hits: [hit("s1", "Планёрка по тарифам", excerpt: "")])

        #expect(answer.contains("цитировать нечего"))
        #expect(answer.contains("«Планёрка по тарифам»"), "человек должен знать, где смотрели")
    }

    @Test("пустой поиск отвечает отказом, а не пустотой")
    func emptyResultSaysSo() {
        let answer = RecallAnswer.compose(query: "что решили по отпускам", hits: [])
        #expect(answer.contains("не говорили"))
        #expect(answer.contains("придумывать не буду"))
    }

    @Test("две причины пустоты звучат по-разному")
    func twoKindsOfEmptinessDiffer() {
        // «Не нашёл ничего» и «нашёл, но там про это не сказано» ведут человека
        // к разным действиям: переформулировать или прекратить искать.
        let nothing = RecallAnswer.compose(query: "отпуск", hits: [])
        let ungrounded = RecallAnswer.compose(
            query: "отпуск", hits: [hit("s1", "Планёрка", excerpt: "")])
        #expect(nothing != ungrounded)
    }

    @Test("больше трёх звонков не вываливается в ответ")
    func atMostThreeCalls() {
        let hits = (1...5).map {
            hit("s\($0)", "Планёрка \($0)", excerpt: "Решили что-то важное \($0)")
        }
        let answer = RecallAnswer.compose(query: "что решили", hits: hits)

        #expect(answer.contains("Планёрка 1"))
        #expect(!answer.contains("Планёрка 4"), "ответ превратился в выдачу")
        #expect(answer.contains("Ещё 2 звонка"), "остальные должны быть посчитаны, а не забыты")
    }

    @Test("русский счёт звонков не ломается на 1, 2, 5 и 11")
    func pluralsAreRussian() {
        // «Ещё 1 звонков» — мелочь, по которой сразу видно переведённый продукт.
        //
        // Слово было «встреча»: в одном файле уживались «созвон», «встреча» и
        // «звонок» — три названия одной вещи. На странице и в README везде
        // «звонок», он и остался.
        #expect(RecallAnswer.callsWord(1) == "звонок")
        #expect(RecallAnswer.callsWord(3) == "звонка")
        #expect(RecallAnswer.callsWord(5) == "звонков")
        #expect(RecallAnswer.callsWord(11) == "звонков")
        #expect(RecallAnswer.callsWord(21) == "звонок")
        #expect(RecallAnswer.callsWord(112) == "звонков")
    }

    @Test("во всех ответах вещь называется одним словом")
    func oneNameForTheThing() {
        // Проверка на все ветки сразу, а не на одну строку: «созвон» и
        // «встреча» возвращались из разных мест, и по отдельному тесту это
        // было не видно — README цитировал отказ третьим словом и расходился
        // с тем, что программа печатает.
        let answers = [RecallAnswer.notFound(hits: []),
                       RecallAnswer.notFound(hits: [hit("s1", "Планёрка по тарифам",
                                                        excerpt: "Решили поднять месячный")]),
                       RecallAnswer.callsWord(1),
                       RecallAnswer.callsWord(2),
                       RecallAnswer.callsWord(5)]

        for answer in answers {
            #expect(!answer.contains("созвон"), "лишнее название: \(answer)")
            #expect(!answer.contains("встреч"), "лишнее название: \(answer)")
        }
    }

    @Test("дата читается по-русски, а не как в базе")
    func dateIsHumanReadable() {
        #expect(RecallAnswer.humanDate("2026-07-24") == "24 июля 2026")
        #expect(RecallAnswer.humanDate("2026-01-01") == "1 января 2026")
        #expect(RecallAnswer.humanDate("2026-12-31") == "31 декабря 2026")
    }

    @Test("испорченная дата показывается как есть, а не подменяется сегодняшней")
    func brokenDateIsShownAsIs() {
        // Подставить сегодняшнее число вместо нечитаемого — соврать о том,
        // когда это было сказано.
        #expect(RecallAnswer.humanDate("не дата") == "не дата")
        #expect(RecallAnswer.humanDate("2026-13-40") == "2026-13-40")
        #expect(RecallAnswer.humanDate("") == "")
    }

    @Test("встречи без цитаты не занимают места среди тех, у кого она есть")
    func groundedHitsWin() {
        let answer = RecallAnswer.compose(query: "тарифы", hits: [
            hit("empty", "Без цитаты", excerpt: ""),
            hit("s1", "Планёрка по тарифам", excerpt: "Решили перейти на оплату"),
        ])
        #expect(answer.contains("Планёрка по тарифам"))
        #expect(!answer.contains("Без цитаты"))
    }

    @Test("ответ не сочиняет ничего сверх цитаты")
    func nothingIsInvented() {
        // Проверка на отсебятину: в ответе не должно появиться слов, которых нет
        // ни в цитате, ни в названии, ни в служебной обвязке.
        let excerpt = "Решили перейти на оплату за использование"
        let answer = RecallAnswer.compose(query: "что решили по тарифам",
                                          hits: [hit("s1", "Планёрка по тарифам",
                                                     excerpt: excerpt)])
        for invented in ["вероятно", "видимо", "скорее всего", "рекомендую", "думаю"] {
            #expect(!answer.lowercased().contains(invented), "в ответе появилось «\(invented)»")
        }
    }

    // MARK: - Вопрос без слов для поиска

    @Test("вопрос из одних служебных слов не выдаётся за поиск",
          arguments: ["а что там по этому", "ну и что", "когда это было", "что и как"])
    func queryWithoutSearchableWords(query: String) {
        // Поиск здесь словарный, и служебные слова из него выброшены. «А что
        // там по этому?» после отбора не оставляет НИ ОДНОГО слова — искать
        // было нечем, и архив никто не смотрел. Ответ же гласил «в сохранённых
        // звонках об этом не говорили», то есть утверждал результат поиска,
        // которого не было. Человек уходит уверенным, что тему не обсуждали.
        //
        // Родной брат ошибки с пустым архивом: уверенная фраза поверх того,
        // чего не происходило.
        let hits: [RecallIndex.Hit] = []
        let answer = RecallAnswer.compose(query: query, hits: hits)

        #expect(!answer.contains("не говорили"),
                "сказано про несостоявшийся поиск: «\(answer)»")
        #expect(answer.contains("искать"),
                "не объяснено, что искать было нечем: «\(answer)»")
    }

    @Test("вопрос со значимым словом ищется как прежде")
    func queryWithContentWordStillSearches() {
        // Граница: если счесть «пустым» любой короткий вопрос, пропадёт
        // честный отказ, ради которого продукт и делается.
        let answer = RecallAnswer.compose(query: "что решили по тарифам", hits: [])
        #expect(answer.contains("не говорили"),
                "потерян честный отказ на настоящем вопросе: «\(answer)»")
    }

    @Test("находка важнее придирок к вопросу")
    func hitsWinOverTheComplaint() {
        // Если что-то нашлось, вопрос был достаточно конкретным по
        // определению — жаловаться на него поздно и незачем.
        let session = RecallIndex.Session(id: "1", title: "Планёрка",
                                          date: "2026-08-13",
                                          digest: "Решили поднять тариф.")
        let hit = RecallIndex.Hit(session: session, score: 1,
                                  excerpt: "Решили поднять тариф.")
        let answer = RecallAnswer.compose(query: "ну и что", hits: [hit])
        #expect(answer.contains("Решили поднять тариф"), "находка потерялась")
    }

    // MARK: - Пустой архив

    @Test("пустой архив не выдаётся за архив без совпадений")
    func emptyArchiveIsItsOwnAnswer() {
        let answer = RecallAnswer.compose(query: "что решили по тарифам", hits: [],
                                          archiveIsEmpty: true)
        #expect(answer.contains("пуст"), "не сказано, что архив пуст: «\(answer)»")
        #expect(answer.contains("добавить"), "не сказано, что делать: «\(answer)»")
        #expect(!answer.contains("не говорили"),
                "утверждение о несуществующих звонках: «\(answer)»")
    }

    @Test("непустой архив без совпадений отвечает по-прежнему")
    func nonEmptyArchiveKeepsTheHonestRefusal() {
        // Граница: если объявить пустым всё, где нет находок, пропадёт
        // честный отказ — тот, ради которого продукт и existsует.
        let answer = RecallAnswer.compose(query: "что решили по тарифам", hits: [],
                                          archiveIsEmpty: false)
        #expect(answer.contains("не говорили"), "потерян честный отказ: «\(answer)»")
        #expect(!answer.contains("Архив пуст"), "непустой архив назван пустым")
    }

    @Test("обе поверхности продукта передают признак пустоты")
    func bothSurfacesPassTheFlag() throws {
        // Смысл общего составителя ответа в том, что правка доходит до обоих.
        // Значение по умолчанию (false) делает молчаливый пропуск возможным:
        // забывший его вызов собирается и печатает старую фразу. Здесь
        // проверяется, что оба настоящих вызова передают признак явно.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrakulCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mvp
        for (file, surface) in [("Sources/OrakulCore/CommandLineApp.swift", "командная строка"),
                                ("Sources/OrakulApp/OrakulApp.swift", "приложение")] {
            let source = try String(contentsOf: root.appendingPathComponent(file),
                                    encoding: .utf8)
            guard let call = source.range(of: "RecallAnswer.compose") else {
                Issue.record("\(surface) больше не зовёт общий составитель ответа")
                continue
            }
            let tail = source[call.lowerBound...].prefix(320)
            #expect(tail.contains("archiveIsEmpty:"),
                    "\(surface) не передаёт признак пустоты: на первом запуске человек снова прочитает про несуществующие звонки")
        }
    }
}

