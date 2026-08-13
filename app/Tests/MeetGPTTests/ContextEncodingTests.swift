import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

/// Кодировка файла, который человек приносит как контекст.
///
/// Найдено измерением, а не чтением. Файл «Аня: По тарифам решили поднять.» в
/// CP1251 — самая обычная выгрузка из старого инструмента или текст, сохранён-
/// ный коллегой на Windows, — проходил через прежнюю цепочку так:
///
///     UTF-8      → отказ
///     UTF-16     → «샭Ｚ⃏⃯»              ← и это считалось успехом
///     isoLatin1  → «Àíÿ: Ïî òàðèôàì…»    ← до сюда дело не доходило
///
/// UTF-16 без метки порядка байтов берётся за любые байты и возвращает
/// иероглифы. Этот мусор уезжал в подсказку модели как «контекст», и модель
/// читала его всерьёз. Испорченный контекст хуже отсутствующего.
///
/// Ни один тест раньше не трогал `ContextImporter` вовсе — поэтому и не видел.
@Suite("Кодировка файлов контекста")
struct ContextEncodingTests {

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("русский файл в CP1251 читается по-русски, а не кракозяброй")
    func cp1251ContextIsReadable() async throws {
        let root = try scratch()
        let path = root.appendingPathComponent("выгрузка.txt")
        let text = "Аня: По тарифам решили поднять месячный на пятнадцать процентов."
        try #require(text.data(using: .windowsCP1251)).write(to: path)

        let imported = try await ContextImporter.importFile(at: path)
        #expect(imported.text.contains("По тарифам решили поднять"),
                "текст испорчен: «\(imported.text.prefix(60))»")
        // Признаки двух прежних поломок — именно они и уезжали модели.
        #expect(!imported.text.contains("Àíÿ"), "кракозябра из Latin-1")
        #expect(!imported.text.contains("샭"), "иероглифы из UTF-16 без метки")
    }

    @Test("обычный UTF-8 читается как раньше")
    func utf8ContextStillWorks() async throws {
        let root = try scratch()
        let path = root.appendingPathComponent("обычный.txt")
        let text = "Борис: Годовой тариф не трогаем до декабря."
        try #require(text.data(using: .utf8)).write(to: path)

        let imported = try await ContextImporter.importFile(at: path)
        #expect(imported.text.contains("Годовой тариф не трогаем"))
    }

    @Test("картинка с расширением .txt не выдаётся за текст")
    func binaryDisguisedAsTextIsRefused() async throws {
        // Граница запасной кодировки: в CP1251 почти каждый байт — символ.
        // Заголовок PNG читается «успешно» и даёт тридцать управляющих
        // символов; настоящий русский текст в той же кодировке — ноль.
        let root = try scratch()
        let path = root.appendingPathComponent("картинка.txt")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                 + (0..<40).map { UInt8($0) }).write(to: path)

        await #expect(throws: (any Error).self) {
            _ = try await ContextImporter.importFile(at: path)
        }
    }
}
