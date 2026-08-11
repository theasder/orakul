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
