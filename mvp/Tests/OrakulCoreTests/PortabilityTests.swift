import Foundation
import Testing
@testable import OrakulCore

/// Ядро не должно знать, на какой системе оно работает.
///
/// Это не вкусовое требование, а единственное, на чём держится оценка порта на
/// Windows. README обещает: порт стоит ровно того, что лежит **снаружи**
/// `OrakulCore` — захват звука (WASAPI вместо ScreenCaptureKit) и оболочка.
/// План (§7) на этом же основании ставит Windows не «потом», а возможно раньше
/// macOS: доля Windows у российских разработчиков выше, а метрика проекта —
/// принятие именно в этой среде.
///
/// Сегодня обещание верно: во всех файлах ядра только `import Foundation`.
/// Завтра кто-нибудь добавит `import AppKit` ради одной удобной функции — и
/// обещание станет ложью молча. Ни компилятор, ни один тест на поведение этого
/// не заметят: на macOS всё соберётся и пройдёт. Заметит только тот, кто через
/// полгода возьмётся за порт и обнаружит, что «ровно оболочка» — это половина
/// ядра.
///
/// Поэтому проверка смотрит на импорты, а не на поведение. Она и должна падать
/// от одной строки: строка и есть поломка.
@Suite("Переносимость ядра")
struct PortabilityTests {

    /// Всё, что ядру разрешено знать.
    ///
    /// `Foundation` есть и в swift-corelibs-foundation на Linux и Windows —
    /// именно поэтому он здесь единственный системный модуль. Добавлять сюда
    /// что-то новое можно, но осознанно: каждая строка этого списка — часть
    /// цены будущего порта.
    static let allowed: Set<String> = ["Foundation"]

    /// Модули, из-за которых порт перестал бы быть «оболочкой». Перечислены
    /// отдельно от общей проверки, чтобы в сообщении об ошибке было видно не
    /// только «чужой импорт», но и чем именно он плох.
    static let macOSOnly: Set<String> = [
        "AppKit", "SwiftUI", "UIKit", "ScreenCaptureKit", "AVFoundation",
        "CoreML", "CreateML", "Speech", "CoreAudio", "AudioToolbox",
        "Cocoa", "Darwin", "CoreGraphics", "Combine", "ApplicationServices",
    ]

    private static var coreDirectory: URL {
        // От файла теста вверх до корня пакета: Tests/OrakulCoreTests/<этот>.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OrakulCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // корень пакета
            .appendingPathComponent("Sources/OrakulCore")
    }

    private static func sourceFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// Импорты, написанные в файле. Строки в комментариях не считаются: в этом
    /// репозитории комментарии регулярно цитируют то, чего в коде быть не
    /// должно, и проверка, попавшаяся на такую цитату, проверяет комментарий.
    private static func imports(in file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .compactMap { line in
                guard line.hasPrefix("import ") else { return nil }
                return line.dropFirst("import ".count)
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: ".").first.map(String.init)
            }
    }

    @Test("ядро не импортирует ничего, кроме Foundation")
    func coreImportsNothingPlatformSpecific() throws {
        let files = try Self.sourceFiles(in: Self.coreDirectory)
        // Без этой строки проверка вырождается в тишину: пустой список файлов
        // (переименовали каталог, сменили раскладку пакета) прошёл бы её, ничего
        // не проверив, и выглядел бы как успех.
        #expect(files.count >= 5,
                "в ядре нашлось \(files.count) файлов — проверка смотрит не туда")

        for file in files {
            let name = file.lastPathComponent
            for module in try Self.imports(in: file) {
                if Self.macOSOnly.contains(module) {
                    Issue.record("""
                        \(name) импортирует \(module) — модуль только для Apple. \
                        Порт на Windows держится на том, что ядро об этом не знает; \
                        с этой строкой он перестаёт быть «захват звука и оболочка».
                        """)
                    continue
                }
                #expect(Self.allowed.contains(module),
                        "\(name) импортирует \(module), которого нет в списке разрешённых")
            }
        }
    }

    /// Отдельно от импортов: тип из чужой системы можно назвать и не импортируя
    /// модуль, если он подтянут транзитивно. Проверка дешёвая, промах дорогой.
    @Test("в ядре не встречаются типы, которых нет вне Apple")
    func coreNamesNoAppleTypes() throws {
        let forbidden = ["NSApplication", "UIApplication", "SCStream", "AVAudioEngine",
                         "MLModel", "SFSpeechRecognizer", "NSViewController"]
        for file in try Self.sourceFiles(in: Self.coreDirectory) {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for type in forbidden {
                #expect(!code.contains(type),
                        "\(file.lastPathComponent) упоминает \(type) — ядро снова привязано к Apple")
            }
        }
    }

    /// Оболочка — место, где системным модулям как раз положено быть. Если
    /// SwiftUI однажды исчезнет и оттуда, значит переехал не тот слой, и
    /// «чистое ядро» выше стало чистым по недоразумению.
    @Test("оболочка, в отличие от ядра, системные модули использует")
    func shellIsWhereThePlatformLives() throws {
        let shell = Self.coreDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("OrakulApp")
        let modules = try Self.sourceFiles(in: shell).flatMap { try Self.imports(in: $0) }
        #expect(modules.contains(where: Self.macOSOnly.contains),
                "оболочка не импортирует ни одного системного модуля — проверка ядра ничего не значит")
    }
}
