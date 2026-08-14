import Foundation
import Testing
@testable import OrakulCore

/// Список команд в подсказке — единственное, откуда человек узнаёт, что
/// продукт умеет. Команды при этом разбираются в двух местах: обычные — в
/// ядре, а `записать` и `спросить` — в исполняемом файле, потому что им нужны
/// микрофон и настоящая сеть.
///
/// Так и разъехалось: `orakul записать` — запись звонка с микрофона, то есть
/// главное действие продукта, — была реализована и не названа в подсказке
/// вовсе. Шесть команд из семи.
@Suite("Список команд")
struct CommandListingTests {

    private func source(_ relative: String) throws -> String {
        // #filePath → …/mvp/Tests/OrakulCoreTests/CommandListingTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Имена команд из строк вида `orakul <имя>` в подсказке.
    private var listed: Set<String> {
        let usage = CommandLineApp.usage
        var names: Set<String> = []
        for line in usage.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("orakul ") else { continue }
            let word = trimmed.dropFirst("orakul ".count)
                .prefix { $0.isLetter }
            if word.count > 2 { names.insert(String(word)) }
        }
        return names
    }

    /// Имена из `case "…"` в обоих разборах.
    private func dispatched() throws -> Set<String> {
        var names: Set<String> = []
        for file in ["Sources/OrakulCore/CommandLineApp.swift", "Sources/orakul/main.swift"] {
            for line in try source(file).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("case \"") else { continue }
                for part in trimmed.split(separator: "\"").enumerated()
                    .filter({ $0.offset % 2 == 1 }).map({ String($0.element) })
                where part.allSatisfy({ $0.isLetter }) && part.count > 2 {
                    names.insert(part)
                }
            }
        }
        return names
    }

    @Test("каждая команда из подсказки где-то разбирается")
    func everyListedCommandExists() throws {
        let handled = try dispatched()
        #expect(handled.count > 4, "разбор не прочитался: \(handled)")
        let missing = listed.subtracting(handled)
        #expect(missing.isEmpty, "обещаны в подсказке, но не разбираются: \(missing.sorted())")
    }

    @Test("каждая команда названа в подсказке")
    func everyCommandIsListed() throws {
        // Английские синонимы (`record`, `ask`, `help`) в подсказке не нужны:
        // продукт русский, а синонимы — вежливость к тем, кто печатает вслепую.
        let synonyms: Set<String> = ["record", "ask", "help", "list", "find", "add",
                                     "delete", "transcribe", "search"]
        let handled = try dispatched().subtracting(synonyms)
        #expect(handled.count > 4, "разбор не прочитался: \(handled)")
        let undocumented = handled.subtracting(listed).subtracting(["помощь"])
        #expect(undocumented.isEmpty,
                "реализованы, но не названы в подсказке: \(undocumented.sorted())")
    }
}
