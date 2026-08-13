import Foundation
import Testing
@testable import MeetGPT

/// Приложение называется orakul — везде, где название видит пользователь.
///
/// Отдельный идентификатор и своё имя тома уже проверяются снаружи
/// (`orakul/test/identity.test.mjs`), но там речь про то, как приложение
/// выглядит для macOS. Здесь — про то, как оно разговаривает: подпись в
/// экспортированном документе и подписи в настройках это и есть продукт для
/// того, кто их читает.
///
/// Форк переносит изменения сверху, из Cruxwing, и каждая такая правка тащит
/// чужое имя обратно. Поэтому это тест, а не разовая замена.
@Suite("Название продукта")
struct ProductNameTests {

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetGPTTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/MeetGPT")
    }

    /// Строковые литералы файла — грубо, но достаточно: комментарии про
    /// происхождение форка законны и не должны валить тест, а вот текст в
    /// кавычках почти всегда попадает на экран.
    private func literals(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .flatMap { line -> [String] in
                line.split(separator: "\"", omittingEmptySubsequences: false)
                    .enumerated()
                    .filter { $0.offset % 2 == 1 }       // нечётные куски — внутри кавычек
                    .map { String($0.element) }
            }
    }

    private func swiftFiles(under directory: String) -> [URL] {
        let root = sources.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("ни один текст на экране не называет приложение чужим именем")
    func viewsNeverSayCruxwing() {
        let files = swiftFiles(under: "Views")
        #expect(files.count > 10, "не нашлись файлы интерфейса — проверка была бы фиктивной")

        var offenders: [String] = []
        for file in files {
            for literal in literals(of: file) where literal.localizedCaseInsensitiveContains("cruxwing") {
                offenders.append("\(file.lastPathComponent): \(literal.prefix(70))")
            }
        }
        let report = offenders.joined(separator: "; ")
        #expect(offenders.isEmpty, "чужое имя на экране: \(report)")
    }

    @Test("экспортированный документ подписан orakul")
    func exportsAreStampedWithOurName() {
        // Документ уезжает в чужой Notion или Google Docs и живёт там дольше
        // приложения. Чужая подпись в нём — это не опечатка в настройках,
        // это чужой продукт в переписке пользователя.
        // Подпись ищется по дате, а не по слову «export»: слово из неё как раз
        // и убрали, и проверка на него молча перестала что-либо проверять —
        // тест продолжал «проходить», найдя ноль подписей.
        for path in ["MCP/NotionExport.swift", "Integrations/GoogleDocsWriter.swift"] {
            let file = sources.appendingPathComponent(path)
            let stamps = literals(of: file).filter { $0.contains("df.string(from: date)") }
            #expect(stamps.count == 1, "\(path): подпись экспорта не найдена (\(stamps.count))")
            for stamp in stamps {
                #expect(stamp.contains("orakul"),
                        "\(path): документ не подписан именем продукта — \(stamp)")
                #expect(!stamp.localizedCaseInsensitiveContains("cruxwing"),
                        "\(path): документ подписан чужим именем — \(stamp)")
            }
        }
    }

    @Test("имя приложения в бандле совпадает с тем, что говорит интерфейс")
    func bundleAgreesWithTheCopy() {
        // Заодно ловит обратный случай: интерфейс переименовали, а Info.plist
        // остался прежним, и в Dock висит другое имя.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Info.plist")
        let text = (try? String(contentsOf: plist, encoding: .utf8)) ?? ""
        #expect(text.contains("<string>orakul</string>"), "Info.plist называет приложение иначе")
        #expect(!text.localizedCaseInsensitiveContains("cruxwing"))
    }
}
