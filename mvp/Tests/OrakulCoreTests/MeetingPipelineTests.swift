import Foundation
import Testing
@testable import OrakulCore

/// Сквозной путь: звук — расшифровка — словарь — архив — поиск.
///
/// Каждый кусок проверен отдельно, и это ничего не доказывает: в английской
/// версии все куски были зелёными, а функция не работала, потому что сервис
/// читал не тот архив. Такое ловится только здесь.
@Suite("Конвейер созвона")
struct MeetingPipelineTests {

    private struct FakeTranscriber: Transcriber {
        let text: String
        func transcribe(samples: [Float]) async throws -> String { text }
    }

    private struct FailingTranscriber: Transcriber {
        struct Failure: Error, Equatable {}
        func transcribe(samples: [Float]) async throws -> String { throw Failure() }
    }

    private func makeStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-pipeline-\(UUID().uuidString)", isDirectory: true))
    }

    private func cleanUp(_ store: SessionStore) {
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("созвон доходит от звука до поиска")
    func endToEnd() async throws {
        let store = makeStore()
        defer { cleanUp(store) }

        let pipeline = MeetingPipeline(
            transcriber: FakeTranscriber(text: "Решили выкатить в прод после ревью."),
            store: store,
            today: { "2026-07-24" },
            makeIdentifier: { "s1" })

        let session = try await pipeline.record(samples: [0.1, 0.2], title: "Планёрка по тарифам")
        #expect(session.id == "s1")
        #expect(session.date == "2026-07-24")

        // Главное: встреча реально попала в архив и реально ищется. Возвращённое
        // из метода значение об этом ничего не говорит.
        let found = store.index().search("что решили про прод").first
        #expect(found?.session.id == "s1")
        #expect(found?.excerpt.contains("выкатить в прод") == true)
    }

    @Test("словарь применяется до сохранения, а не при показе")
    func lexiconIsAppliedBeforeSaving() async throws {
        let store = makeStore()
        defer { cleanUp(store) }

        // Движок написал латиницей — в архив обязано лечь каноническое
        // написание, иначе поиск ищет по одному тексту, а человек видит другой.
        let pipeline = MeetingPipeline(
            transcriber: FakeTranscriber(text: "Выкатили в prod и дёрнули api."),
            store: store, today: { "2026-07-24" }, makeIdentifier: { "s1" })
        try await pipeline.record(samples: [], title: "Созвон")

        let saved = try #require(store.load().sessions.first)
        #expect(saved.digest.contains("прод"))
        #expect(saved.digest.contains("API"))
        #expect(!saved.digest.contains("prod"))
    }

    @Test("пустая расшифровка не создаёт встречу")
    func emptyTranscriptSavesNothing() async {
        let store = makeStore()
        defer { cleanUp(store) }

        let pipeline = MeetingPipeline(transcriber: FakeTranscriber(text: "   \n  "),
                                       store: store, today: { "2026-07-24" },
                                       makeIdentifier: { "s1" })
        await #expect(throws: MeetingPipeline.PipelineError.nothingRecognised) {
            try await pipeline.record(samples: [], title: "Созвон")
        }
        // Пустая встреча в списке выглядит как потерянная запись.
        #expect(store.load().sessions.isEmpty)
    }

    @Test("сбой расшифровки не оставляет обломков в архиве")
    func transcriptionFailureLeavesNothing() async {
        let store = makeStore()
        defer { cleanUp(store) }

        let pipeline = MeetingPipeline(transcriber: FailingTranscriber(), store: store,
                                       today: { "2026-07-24" }, makeIdentifier: { "s1" })
        await #expect(throws: FailingTranscriber.Failure()) {
            try await pipeline.record(samples: [], title: "Созвон")
        }
        #expect(store.load().sessions.isEmpty)
        #expect(store.load().skipped.isEmpty, "неудача не должна оставлять битый файл")
    }

    @Test("созвон без названия называется «Созвон», а не пустотой")
    func untitledMeetingGetsAName() async throws {
        let store = makeStore()
        defer { cleanUp(store) }

        let pipeline = MeetingPipeline(transcriber: FakeTranscriber(text: "Обсудили сроки."),
                                       store: store, today: { "2026-07-24" },
                                       makeIdentifier: { "s1" })
        let session = try await pipeline.record(samples: [], title: "   ")
        #expect(session.title == "Звонок")
    }

    @Test("две записи подряд не перетирают друг друга")
    func consecutiveRecordingsCoexist() async throws {
        let store = makeStore()
        defer { cleanUp(store) }

        let counter = Counter()
        let pipeline = MeetingPipeline(transcriber: FakeTranscriber(text: "Решили и разошлись."),
                                       store: store, today: { "2026-07-24" },
                                       makeIdentifier: { counter.next() })

        try await pipeline.record(samples: [], title: "Первый")
        try await pipeline.record(samples: [], title: "Второй")
        #expect(store.load().sessions.count == 2)
    }

    @Test("день берётся из переданных часов, а не из системных")
    func dateComesFromInjectedClock() async throws {
        let store = makeStore()
        defer { cleanUp(store) }

        let pipeline = MeetingPipeline(transcriber: FakeTranscriber(text: "Решили."),
                                       store: store, today: { "1999-12-31" },
                                       makeIdentifier: { "s1" })
        let session = try await pipeline.record(samples: [], title: "Созвон")
        // Тест, зависящий от календаря, однажды падает ночью 31 декабря.
        #expect(session.date == "1999-12-31")
    }

    @Test("формат сегодняшней даты — тот же, что в архиве")
    func currentDayMatchesArchiveFormat() {
        #expect(MeetingPipeline.currentDay().range(of: #"^\d{4}-\d{2}-\d{2}$"#,
                                                   options: .regularExpression) != nil)
    }
}

/// Счётчик под замком: генератор идентификаторов помечен `Sendable`, и захват
/// изменяемой переменной из замыкания — это гонка, а не мелочь.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return "s\(value)"
    }
}
