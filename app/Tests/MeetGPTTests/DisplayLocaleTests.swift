import Foundation
import Testing
@testable import MeetGPT

/// Даты и время — по-русски, независимо от языка системы.
///
/// Это не косметика: у российского разработчика macOS часто английская, и без
/// заданной локали русское приложение показывало «Wednesday, Aug 12 · 1:16 AM»
/// в шапке звонка и «Wednesday, 12 August 2026 at 14:30» в экспортированном
/// транскрипте — внутри документа, который человек отправляет коллегам.
@Suite("Локаль дат")
struct DisplayLocaleTests {

    /// 12 августа 2026, 14:30 UTC — точка зафиксирована, чтобы проверка не
    /// зависела от дня запуска.
    private var moment: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 12
        parts.hour = 14; parts.minute = 30
        parts.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: parts) ?? Date()
    }

    private func formatter(_ format: String) -> DateFormatter {
        let made = DisplayFormatting.displayFormatter(format)
        made.timeZone = TimeZone(identifier: "UTC")
        return made
    }

    @Test("месяц и день недели пишутся по-русски")
    func monthsAndWeekdaysAreRussian() {
        let text = formatter("EEEE, d MMMM yyyy").string(from: moment)

        #expect(text.contains("август"), "месяц не по-русски: \(text)")
        #expect(text.range(of: "[A-Za-z]", options: .regularExpression) == nil,
                "в дате осталась латиница: \(text)")
    }

    @Test("часы двадцатичетырёхчасовые, без AM/PM")
    func clockIsTwentyFourHour() {
        // В русском нет «1:16 AM». Формат с `a` в шапке звонка это и выдавал.
        let text = formatter("EEEE, d MMMM · HH:mm").string(from: moment)

        #expect(text.contains("14:30"), "не 24 часа: \(text)")
        #expect(!text.uppercased().contains("AM"))
        #expect(!text.uppercased().contains("PM"))
    }

    @Test("локаль задана, а не взята из системы")
    func localeIsPinnedNotInherited() {
        // Системная локаль дала бы русский интерфейс с английскими датами на
        // английской macOS — самый частый случай у разработчика.
        #expect(DisplayFormatting.locale.identifier == "ru_RU")
        #expect(DisplayFormatting.displayFormatter("d MMMM").locale == DisplayFormatting.locale)
    }

    @Test("машинные форматы остаются независимыми от языка")
    func machineFormatsStayPOSIX() {
        // Их менять нельзя: `en_US_POSIX` тем и хорош, что не зависит от
        // настроек. Разбор ISO и отметки UTC ломаются от локали молча.
        #expect(DisplayFormatting.machineLocale.identifier == "en_US_POSIX")
    }

    @Test("в шапке звонка и в экспорте не осталось английских дат")
    func noEnglishDateFormatsLeftInDisplayCode() {
        // Проверяется исходник: формат с `a` (AM/PM) или английское «at» рядом
        // с человекочитаемой датой — возврат той же ошибки.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT")
        let files = ["Views/ContentView.swift", "Export/TranscriptExporter.swift",
                     "MCP/NotionExport.swift", "Integrations/GoogleDocsWriter.swift"]

        for name in files {
            let text = (try? String(contentsOf: root.appendingPathComponent(name),
                                    encoding: .utf8)) ?? ""
            #expect(!text.isEmpty, "не прочитался \(name)")

            // Комментарии пропускаются: в них старый формат приведён нарочно,
            // чтобы было видно, что и почему заменили. Ищется живой код.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("h:mm a"), "\(name): двенадцатичасовые часы с AM/PM")
            #expect(!code.contains("'at'"), "\(name): английское «at» в дате")
        }
    }
}
