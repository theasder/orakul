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

    @Test("больше трёх встреч не вываливается в ответ")
    func atMostThreeMeetings() {
        let hits = (1...5).map {
            hit("s\($0)", "Созвон \($0)", excerpt: "Решили что-то важное \($0)")
        }
        let answer = RecallAnswer.compose(query: "что решили", hits: hits)

        #expect(answer.contains("Созвон 1"))
        #expect(!answer.contains("Созвон 4"), "ответ превратился в выдачу")
        #expect(answer.contains("Ещё 2 встречи"), "остальные должны быть посчитаны, а не забыты")
    }

    @Test("русский счёт встреч не ломается на 1, 2, 5 и 11")
    func pluralsAreRussian() {
        // «Ещё 1 встреч» — мелочь, по которой сразу видно переведённый продукт.
        #expect(RecallAnswer.meetingsWord(1) == "встреча")
        #expect(RecallAnswer.meetingsWord(3) == "встречи")
        #expect(RecallAnswer.meetingsWord(5) == "встреч")
        #expect(RecallAnswer.meetingsWord(11) == "встреч")
        #expect(RecallAnswer.meetingsWord(21) == "встреча")
        #expect(RecallAnswer.meetingsWord(112) == "встреч")
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
}
