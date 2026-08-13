import Foundation
import Testing
@testable import OrakulCore

/// README обещает пять минут. Здесь проверяется, что они действительно пять.
///
/// **Почему не хватает `CommandLineAppTests`.** Тот набор проверяет поведение
/// команд и знает нужные строки наизусть. README знает те же строки отдельно.
/// Это две копии одного обещания, и расходятся они молча: команду переименуют,
/// текст ответа поправят, тесты останутся зелёными — а первое, что делает
/// пришедший из README человек, перестанет работать. Для проекта, метрика
/// которого — звёзды, поломка самая дорогая из возможных: случается ровно один
/// раз, ровно с новым человеком, и он не возвращается.
///
/// Поэтому ожидания здесь **вычитаны из README**, а не написаны рядом. Перепишут
/// README — тест начнёт проверять новый текст; сломают команду — упадёт.
/// Скопировать строки сюда значило бы завести третью копию.
@Suite("Быстрый старт из README")
struct ReadmeQuickstartTests {

    private static var readme: String {
        get throws {
            // Tests/OrakulCoreTests/<этот> → Tests → mvp → корень репозитория.
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("README.md"),
                              encoding: .utf8)
        }
    }

    /// Расшифровка из README — та, что лежит в heredoc между `<<'TXT'` и `TXT`.
    private static func transcript(from readme: String) -> String? {
        guard let start = readme.range(of: "<<'TXT'\n"),
              let end = readme.range(of: "\nTXT", range: start.upperBound..<readme.endIndex)
        else { return nil }
        return String(readme[start.upperBound..<end.lowerBound])
    }

    /// Аргументы команды, как они напечатаны в README.
    private static func arguments(from readme: String, command: String) -> [String]? {
        guard let line = readme.split(separator: "\n").first(where: {
            $0.contains("orakul \(command) ")
        }) else { return nil }
        guard let after = line.range(of: "orakul ") else { return nil }
        var arguments: [String] = []
        var current = ""
        var quoted = false
        for character in line[after.upperBound...] {
            switch character {
            case "\"": quoted.toggle()
            case " " where !quoted:
                if !current.isEmpty { arguments.append(current); current = "" }
            default: current.append(character)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }

    /// День закреплён: заголовок выдачи содержит дату добавления, и без этого
    /// тест начал бы зависеть от того, когда его запустили.
    private func makeApp(transcript: String, day: String = "2026-08-12") -> CommandLineApp {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-readme-\(UUID().uuidString)")
        return CommandLineApp(
            store: SessionStore(root: root),
            today: { day },
            // Файл на диск не кладём: README показывает `cat > расшифровка.txt`,
            // а проверяется не работа `cat`, а то, что дальше сделает orakul.
            readFile: { _ in transcript })
    }

    @Test("расшифровка и команды из README на месте и разбираются")
    func readmeStillShowsTheQuickstart() throws {
        let readme = try Self.readme
        let transcript = try #require(Self.transcript(from: readme),
                                      "в README пропал heredoc с расшифровкой")
        #expect(transcript.contains("Аня:"), "в примере расшифровки не осталось реплик")

        let add = try #require(Self.arguments(from: readme, command: "добавить"),
                               "в README нет команды «добавить»")
        #expect(add.first == "добавить")
        #expect(add.count >= 3, "команда «добавить» в README потеряла название звонка")

        let find = try #require(Self.arguments(from: readme, command: "найти"),
                                "в README нет команды «найти»")
        #expect(find.first == "найти")
        #expect(find.count >= 2, "команде «найти» в README нечего искать")
    }

    @Test("«добавить» отвечает так, как обещает README")
    func addPrintsWhatReadmePromises() throws {
        let readme = try Self.readme
        let transcript = try #require(Self.transcript(from: readme))
        let arguments = try #require(Self.arguments(from: readme, command: "добавить"))
        let title = try #require(arguments.last, "в команде README нет названия")

        let output = makeApp(transcript: transcript).run(arguments).output

        // README печатает `Добавлено: «Планёрка по тарифам» (27AE25B5-…)` —
        // идентификатор в нём заведомо сокращён, поэтому сверяется всё, кроме
        // него: слово, название в кавычках и наличие скобок с идентификатором.
        let promised = try #require(
            readme.split(separator: "\n").first(where: { $0.hasPrefix("Добавлено:") }),
            "README больше не показывает ответ команды «добавить»")
        let word = String(promised.prefix(while: { $0 != " " }))
        #expect(output.hasPrefix(word),
                "README обещает ответ с «\(word)», а команда отвечает «\(output)»")
        #expect(output.contains("«\(title)»"),
                "в ответе нет названия звонка, хотя README его показывает")
        #expect(output.contains("(") && output.contains(")"),
                "README показывает идентификатор в скобках, а команда его не печатает")
    }

    @Test("«найти» возвращает ту самую строку, что напечатана в README")
    func findReturnsTheQuotedLine() throws {
        let readme = try Self.readme
        let transcript = try #require(Self.transcript(from: readme))
        let app = makeApp(transcript: transcript)
        _ = app.run(try #require(Self.arguments(from: readme, command: "добавить")))

        let output = app.run(try #require(Self.arguments(from: readme, command: "найти"))).output

        // Строка выдачи — единственное в примере, что не зависит от дня запуска:
        // заголовок с датой меняется каждый день, цитата нет. Её и сверяем,
        // потому что она и есть обещание продукта: ответ чужими словами.
        let quoted = try #require(
            readme.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix("    Аня:") })?
                .trimmingCharacters(in: .whitespaces),
            "README больше не показывает найденную строку")
        #expect(output.contains(quoted),
                "README обещает найти «\(quoted)», а выдача такая: \(output)")
    }

    @Test("отказ отвечать звучит дословно так, как напечатан в README")
    func refusalMatchesReadme() throws {
        let readme = try Self.readme
        let transcript = try #require(Self.transcript(from: readme))
        let app = makeApp(transcript: transcript)
        _ = app.run(try #require(Self.arguments(from: readme, command: "добавить")))

        // README показывает отказ отдельным примером: спросили то, чего в
        // звонках не было. Это главное обещание продукта — «ответ придумывать
        // не буду», — и расхождение здесь дороже любой другой строки.
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: false)
        let promptIndex = try #require(
            lines.firstIndex(where: { $0.hasPrefix("$ orakul найти") }),
            "README больше не показывает пример отказа")
        let promised = String(lines[promptIndex + 1])
        let question = String(lines[promptIndex].dropFirst("$ orakul ".count))
            .split(separator: " ").map(String.init)

        let output = app.run(question).output
        #expect(output == promised,
                "README обещает «\(promised)», а команда отвечает «\(output)»")
    }
}
