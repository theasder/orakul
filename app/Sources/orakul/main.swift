import Foundation
import OrakulCore

// Тонкая оболочка: вся логика и все тексты живут в OrakulCore, потому что здесь
// их нельзя проверить тестом. Исключение одно — запись с микрофона: её нельзя
// проверить тестом в принципе, поэтому она тоже здесь, и её видно.

let home = ProcessInfo.processInfo.environment["ORAKUL_HOME"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orakul").path
let store = SessionStore(root: URL(fileURLWithPath: home))
let arguments = Array(CommandLine.arguments.dropFirst())

/// Запись с микрофона: единственная команда, которой нужен настоящий компьютер.
func recordFromMicrophone(_ rest: [String]) async -> CommandLineApp.Result {
    let seconds = Double(rest.first ?? "") ?? 15
    let title = rest.dropFirst().joined(separator: " ")

    FileHandle.standardError.write(Data("Записываю \(Int(seconds)) с. Говорите…\n".utf8))
    do {
        let samples = try await MicrophoneRecorder.record(seconds: seconds) { done in
            FileHandle.standardError.write(Data("\r\(String(format: "%.0f", done)) с".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))

        var buffer = AudioAccumulator()
        buffer.append(samples)

        guard buffer.isWorthTranscribing else {
            // Отличить «тишину» от «слишком коротко» важно: причины разные и
            // чинятся по-разному. К тишине обязательно число: вердикт без
            // уровня неотличим от сломанного преобразования, и разбираться
            // пришлось бы вслепую — ровно так и выяснилось, что прежний порог
            // был ниже фона обычной комнаты.
            let reason: String
            if buffer.looksSilent {
                reason = String(format: "Тишина: уровень %.5f при пороге %.3f. "
                                + "Похоже, выбран не тот микрофон или он выключен.",
                                buffer.level, AudioAccumulator.silenceThreshold)
            } else {
                reason = String(format: "Слишком коротко — записано %.1f с.", buffer.seconds)
            }
            return CommandLineApp.Result(output: reason, exitCode: 1)
        }

        // Сохраняем запись рядом, чтобы её можно было расшифровать и потом:
        // потерять созвон из-за ненастроенного движка было бы обидно.
        let wav = URL(fileURLWithPath: home)
            .appendingPathComponent("записи", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try WAVFile.encode(samples: buffer.samples).write(to: wav)

        return CommandLineApp.Result(output: """
        Записано \(String(format: "%.1f", buffer.seconds)) с → \(wav.path)
        Дальше: orakul расшифровать \(wav.path) "\(title.isEmpty ? "Созвон" : title)"
        """, exitCode: 0)
    } catch {
        return CommandLineApp.Result(output: "\(error)", exitCode: 1)
    }
}

let result: CommandLineApp.Result
switch arguments.first {
case "записать", "record":
    result = await recordFromMicrophone(Array(arguments.dropFirst()))
default:
    result = CommandLineApp(store: store).run(arguments)
}

// Ошибки — в stderr, чтобы `orakul найти ... > файл` не смешивал ответ с
// жалобой на аргументы.
if result.exitCode == 0 {
    print(result.output)
} else {
    FileHandle.standardError.write(Data((result.output + "\n").utf8))
}
exit(result.exitCode)
