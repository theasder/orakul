import Foundation
import Testing
@testable import OrakulCore

/// Архив — это годы чужой работы. Тесты здесь проверяют не «сохранилось ли», а
/// что происходит, когда что-то идёт не так: битый файл, обрыв записи,
/// подозрительный идентификатор. Потерять архив можно ровно один раз.
@Suite("Архив созвонов")
struct SessionStoreTests {

    /// Своя папка на каждый тест: общий каталог означал бы, что тесты видят
    /// чужие записи и падают по очереди.
    private func makeStore() -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-tests-\(UUID().uuidString)", isDirectory: true)
        return SessionStore(root: root)
    }

    private func session(_ id: String,
                         date: String = "2026-07-24",
                         title: String = "Планёрка по тарифам",
                         digest: String = "Решили перейти на оплату за использование.")
        -> RecallIndex.Session {
        RecallIndex.Session(id: id, title: title, date: date, digest: digest)
    }

    private func cleanUp(_ store: SessionStore) {
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("сохранённая встреча читается обратно без потерь")
    func roundTrip() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        let original = session("s1")
        try store.save(original)
        let archive = store.load()

        #expect(archive.sessions == [original])
        #expect(archive.skipped.isEmpty)
    }

    @Test("папки ещё нет — это не ошибка, а пустой архив")
    func missingDirectoryIsEmptyArchive() {
        let store = makeStore()
        // Первый запуск приложения: каталога нет. Падать здесь нельзя.
        #expect(store.load().sessions.isEmpty)
        #expect(store.index().search("тарифы").isEmpty)
    }

    @Test("повторное сохранение заменяет запись, а не плодит копии")
    func saveIsIdempotent() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1", digest: "Первая версия."))
        try store.save(session("s1", digest: "Уточнили: две копейки за кредит."))

        let archive = store.load()
        #expect(archive.sessions.count == 1)
        #expect(archive.sessions.first?.digest.contains("две копейки") == true)
    }

    @Test("битый файл пропускается, остальной архив открывается")
    func corruptFileDoesNotKillTheArchive() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("good"))
        try Data("{ это не json".utf8).write(to: store.root.appendingPathComponent("bad.json"))

        let archive = store.load()
        // Одна встреча потеряна, год работы — нет.
        #expect(archive.sessions.map(\.id) == ["good"])
        #expect(archive.skipped == ["bad.json"], "пропуск обязан быть виден, а не проглочен")
    }

    @Test("посторонние файлы в папке игнорируются молча")
    func unrelatedFilesAreIgnored() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1"))
        try Data("заметка".utf8).write(to: store.root.appendingPathComponent("readme.txt"))

        let archive = store.load()
        #expect(archive.sessions.count == 1)
        // .txt никто не обещал читать — это не повреждение и не повод тревожить.
        #expect(archive.skipped.isEmpty)
    }

    @Test("временный файл недописанной записи не читается как встреча")
    func temporaryFilesAreNotSessions() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1"))
        try Data("{".utf8).write(to: store.root.appendingPathComponent(".s2.tmp"))

        let archive = store.load()
        #expect(archive.sessions.count == 1)
        #expect(archive.skipped.isEmpty, "обрыв записи не должен выглядеть как повреждение архива")
    }

    @Test("идентификатор с путём отклоняется, а не пишет мимо архива")
    func pathTraversalIsRejected() {
        let store = makeStore()
        defer { cleanUp(store) }

        for dangerous in ["../эвакуация", "папка/файл", "", ".скрытый"] {
            #expect(throws: SessionStore.StoreError.identifierUnusableAsFilename(dangerous)) {
                try store.save(session(dangerous))
            }
        }
    }

    @Test("свежие встречи идут первыми, порядок не зависит от файловой системы")
    func sortedByDateDescending() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("b", date: "2026-07-25"))
        try store.save(session("a", date: "2026-07-28"))
        try store.save(session("c", date: "2026-07-25"))

        #expect(store.load().sessions.map(\.id) == ["a", "b", "c"])
    }

    @Test("удаление убирает одну встречу и не трогает остальные")
    func deleteRemovesOne() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1"))
        try store.save(session("s2", date: "2026-07-25"))
        try store.delete(id: "s1")

        #expect(store.load().sessions.map(\.id) == ["s2"])
        // Удаление того, чего нет, — не ошибка: пользователь мог нажать дважды.
        #expect(throws: Never.self) { try store.delete(id: "s1") }
    }

    @Test("архив ищется целиком: сохранили — нашли")
    func archiveIsSearchable() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1"))
        try store.save(session("s2", date: "2026-07-25", title: "Ретро спринта",
                               digest: "Решили сократить дейли до пятнадцати минут."))

        let hit = store.index().search("что решили на ретро").first
        #expect(hit?.session.id == "s2")
    }

    @Test("файл на диске остаётся читаемым человеком")
    func fileIsHumanReadable() throws {
        let store = makeStore()
        defer { cleanUp(store) }

        try store.save(session("s1"))
        let raw = try String(contentsOf: store.url(for: "s1"), encoding: .utf8)
        // Это записи пользователя: он должен открыть их без нашего приложения
        // и увидеть русский текст, а не последовательность \u04XX.
        #expect(raw.contains("Планёрка по тарифам"))
        #expect(raw.contains("\n"), "не одна строка — иначе читать невозможно")
    }
}
