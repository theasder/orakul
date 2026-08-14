import Foundation
import Testing
@testable import OrakulCore

/// Файл расшифровки приходит из чужого редактора, и это редактор из Windows.
///
/// У `TranscriptFile.decode` не было ни одной проверки — отсюда и находки.
/// Обе нашлись прогоном: файл с меткой порядка байтов и файл с переводом
/// строки по-виндовому, то есть ровно то, что пришлёт коллега из аудитории,
/// ради которой всё делается.
@Suite("Кодировки расшифровки")
struct TranscriptEncodingTests {

    private func utf8(_ text: String) -> Data { Data(text.utf8) }
    private let bomBytes = Data([0xEF, 0xBB, 0xBF])

    /// Метка порядка байтов невидима — и потому опаснее видимого мусора.
    ///
    /// Первое слово файла становилось «\u{FEFF}Вера»: на вопрос «вера» продукт
    /// отвечал, что точных слов в расшифровке нет, стоя рядом со строкой, где
    /// они есть. Ещё она вылезала в цитату — в ответ, который человек читает.
    @Test("метка порядка байтов не остаётся в тексте")
    func bomIsStripped() throws {
        let decoded = try #require(
            TranscriptFile.decode(bomBytes + utf8("Вера: Миграцию отложили.\n")))
        #expect(!decoded.hasPrefix("\u{FEFF}"), "метка осталась в начале текста")
        #expect(!decoded.contains("\u{FEFF}"), "метка осталась где-то внутри")
        #expect(decoded.hasPrefix("Вера:"), "получилось: \(decoded.prefix(20))")
    }

    /// Та же беда с той стороны, где её видит человек: до цитаты.
    ///
    /// Первая редакция этой проверки требовала лишь непустого `search`, и
    /// прошла зелёной, пока продукт на том же вопросе отвечал «цитировать
    /// нечего»: находка была, цитаты не было. Проверять надо то, что человек
    /// читает, а не промежуточный список.
    @Test("слово после метки доходит до цитаты")
    func wordAfterBOMIsQuoted() throws {
        let decoded = try #require(
            TranscriptFile.decode(bomBytes + utf8("Вера: Миграцию отложили.\n")))
        let index = RecallIndex(sessions: [
            RecallIndex.Session(id: "1", title: "Звонок", date: "2026-08-14",
                                digest: decoded),
        ])
        let ответ = RecallAnswer.compose(query: "вера", hits: index.search("вера"))
        #expect(ответ.contains("Вера: Миграцию отложили"), "получилось: \(ответ)")
        #expect(!ответ.contains("цитировать нечего"), "получилось: \(ответ)")
    }

    /// И отдельно — первое слово, не являющееся именем: метка ломала любое
    /// первое слово файла, а не только имена.
    @Test("первое слово файла с меткой цитируется")
    func firstWordAfterBOMIsQuoted() throws {
        let decoded = try #require(
            TranscriptFile.decode(bomBytes + utf8("Тарифы обсудили в четверг.\n")))
        let index = RecallIndex(sessions: [
            RecallIndex.Session(id: "1", title: "Звонок", date: "2026-08-14",
                                digest: decoded),
        ])
        let ответ = RecallAnswer.compose(query: "тарифы", hits: index.search("тарифы"))
        #expect(ответ.contains("Тарифы обсудили"), "получилось: \(ответ)")
    }

    /// Возврат каретки доезжал до цитаты. В терминале он переводит курсор в
    /// начало строки: остаток строки затирается тем, что печатается следом.
    @Test("возврат каретки не доезжает до текста")
    func carriageReturnsAreNormalised() throws {
        let decoded = try #require(
            TranscriptFile.decode(utf8("Аня: Решили катить.\r\nБорис: Тарифы.\r\n")))
        #expect(!decoded.contains("\r"), "возврат каретки остался в тексте")
        #expect(decoded.contains("Аня: Решили катить.\nБорис: Тарифы."),
                "строки склеились или потерялись: \(decoded.debugDescription)")
    }

    /// Одинокий возврат каретки — перевод строки в старых редакторах Mac.
    /// Оставить его значит склеить весь звонок в одну строку.
    @Test("одинокий возврат каретки становится переводом строки")
    func loneCarriageReturnBecomesNewline() throws {
        let decoded = try #require(TranscriptFile.decode(utf8("Аня: Раз.\rБорис: Два.")))
        #expect(decoded == "Аня: Раз.\nБорис: Два.", "получилось: \(decoded.debugDescription)")
    }

    // MARK: - Что и раньше работало

    /// Эти три уже работали, и проверки на них не было ни одной. Починка
    /// первых двух находок не должна их уронить.
    @Test("обычный UTF-8 не меняется")
    func plainUTF8Untouched() throws {
        let text = "Аня: Решили катить в пятницу.\nБорис: Тарифы поднимаем.\n"
        #expect(TranscriptFile.decode(utf8(text)) == text)
    }

    @Test("CP1251 читается — файл из Windows приходит именно таким")
    func cp1251IsRead() throws {
        let text = "Аня: Решили катить в пятницу.\n"
        let data = try #require(text.data(using: .windowsCP1251))
        #expect(TranscriptFile.decode(data) == text)
    }

    @Test("UTF-16 читается")
    func utf16IsRead() throws {
        let text = "Глеб: Отгрузили релиз в четверг.\n"
        let data = try #require(text.data(using: .utf16))
        #expect(TranscriptFile.decode(data) == text)
    }

    /// Двоичный файл расшифровкой не притворяется: молча принять его значит
    /// положить в архив мусор и потом искать по нему.
    @Test("двоичный файл расшифровкой не считается")
    func binaryIsRejected() {
        #expect(TranscriptFile.decode(Data([0x00, 0x01, 0x02, 0x03, 0xFF])) == nil)
    }
}

/// Три причины, по которым файл не прочитался, — три разных совета.
///
/// `orakul добавить /tmp` отвечал «Не смог прочитать файл: /tmp». Сообщение о
/// следствии: каталог не «не прочитался», он не файл, и чинится это иначе, чем
/// опечатка в пути или отсутствие прав.
@Suite("Почему файл не прочитался")
struct UnreadableReasonTests {

    @Test("каталог называется каталогом")
    func directoryIsNamed() throws {
        let каталог = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: каталог, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: каталог) }

        let ответ = CommandLineApp.whyUnreadable(каталог.path)
        #expect(ответ.contains("каталог, а не файл"), "получилось: \(ответ)")
        #expect(!ответ.hasPrefix("Не смог прочитать"), "причина названа следствием")
    }

    @Test("отсутствующий файл называется отсутствующим")
    func missingIsNamed() {
        let путь = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString).path
        let ответ = CommandLineApp.whyUnreadable(путь)
        #expect(ответ.contains("Файла нет"), "получилось: \(ответ)")
    }

    /// Файл на месте и читается как байты — значит дело в правах или в том,
    /// что это вообще не текст. Только здесь «не смог прочитать» — правда.
    @Test("существующий файл — про права и про запись звонка")
    func existingFileMentionsRights() throws {
        let файл = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0x00, 0x01, 0x02]).write(to: файл)
        defer { try? FileManager.default.removeItem(at: файл) }

        let ответ = CommandLineApp.whyUnreadable(файл.path)
        #expect(ответ.hasPrefix("Не смог прочитать файл"), "получилось: \(ответ)")
        #expect(ответ.contains("права доступа"))
        #expect(ответ.contains("orakul расшифровать"),
                "про запись звонка не сказано, а .wav сюда попадает чаще всего")
    }

    /// Три причины — три разных текста. Совпади любые два, разбор был бы
    /// украшением.
    @Test("три причины не повторяют друг друга")
    func threeReasonsDiffer() throws {
        let каталог = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: каталог, withIntermediateDirectories: true)
        let файл = каталог.appendingPathComponent("есть.bin")
        try Data([0x00, 0x01]).write(to: файл)
        defer { try? FileManager.default.removeItem(at: каталог) }

        let ответы = [
            CommandLineApp.whyUnreadable(каталог.path),
            CommandLineApp.whyUnreadable(каталог.appendingPathComponent("нет").path),
            CommandLineApp.whyUnreadable(файл.path),
        ]
        #expect(Set(ответы).count == 3, "разные причины дали одинаковый ответ: \(ответы)")
    }
}
