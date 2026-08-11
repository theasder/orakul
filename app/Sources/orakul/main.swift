import Foundation
import OrakulCore

// Тонкая оболочка: вся логика и все тексты живут в OrakulCore, потому что здесь
// их нельзя проверить тестом. В этом файле должно быть нечего ломать.

let home = ProcessInfo.processInfo.environment["ORAKUL_HOME"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orakul").path

let app = CommandLineApp(store: SessionStore(root: URL(fileURLWithPath: home)))
let result = app.run(Array(CommandLine.arguments.dropFirst()))

// Ошибки — в stderr, чтобы `orakul найти ... > файл` не смешивал ответ с
// жалобой на аргументы.
if result.exitCode == 0 {
    print(result.output)
} else {
    FileHandle.standardError.write(Data((result.output + "\n").utf8))
}
exit(result.exitCode)
