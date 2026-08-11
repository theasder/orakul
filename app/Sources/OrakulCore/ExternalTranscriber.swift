import Foundation

/// WAV, 16 кГц моно 16 бит — формат, который принимают все движки распознавания.
///
/// Пишется руками, а не через AVFoundation: заголовок RIFF занимает сорок
/// четыре байта, а зависимость от аудиофреймворка означала бы, что ядро больше
/// не переносится на Windows одним файлом.
public enum WAVFile {

    public static let sampleRate = 16_000

    /// Байты WAV из нормализованных сэмплов (-1…1).
    public static func encode(samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var data = Data()
        let bytesPerSample = 2
        let payload = samples.count * bytesPerSample

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) {
            var little = UInt32(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: Int) {
            var little = UInt16(truncatingIfNeeded: value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(36 + payload)
        append("WAVE")
        append("fmt ")
        append32(16)            // размер fmt-блока
        append16(1)             // PCM без сжатия
        append16(1)             // моно
        append32(sampleRate)
        append32(sampleRate * bytesPerSample)
        append16(bytesPerSample)
        append16(16)            // бит на сэмпл
        append("data")
        append32(payload)

        for sample in samples {
            // Обрезка обязательна: значение за пределами -1…1 при переводе в
            // Int16 переполнится и превратит громкий фрагмент в треск.
            let clamped = max(-1, min(1, sample))
            append16(Int(clamped * 32_767))
        }
        return data
    }
}

/// Расшифровка внешней программой, которая уже стоит у человека.
///
/// Своей модели orakul не возит: веса весят гигабайты, а репозиторий, который
/// тянет их при установке, перестаёт запускаться «за пять минут». Зато у многих
/// уже стоит whisper.cpp или подобное — и тогда всё работает сегодня.
///
/// Команда задаётся строкой с подстановкой `{файл}`, например:
/// `whisper-cli -m ~/models/ggml-large-v3.bin -l ru -otxt -f {файл}`.
public struct ExternalTranscriber: Transcriber {

    /// Как запустить процесс. Подменяется в тестах, потому что тест, который
    /// действительно запускает whisper, зависит от чужой машины.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String],
                                         _ audio: URL) throws -> String

    public enum TranscriberError: Error, Equatable {
        case commandIsEmpty
        case commandHasNoFilePlaceholder
        case engineFailed(String)
        case engineSaidNothing
    }

    let command: String
    let run: Runner

    public init(command: String, run: @escaping Runner = ExternalTranscriber.processRunner) {
        self.command = command
        self.run = run
    }

    public func transcribe(samples: [Float]) async throws -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let executable = parts.first else { throw TranscriberError.commandIsEmpty }
        guard command.contains("{файл}") || command.contains("{file}") else {
            // Без подстановки движок получил бы аудио ниоткуда и молча
            // расшифровал бы пустоту — отказ понятнее.
            throw TranscriberError.commandHasNoFilePlaceholder
        }

        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-\(UUID().uuidString).wav")
        try WAVFile.encode(samples: samples).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let arguments = parts.dropFirst().map {
            $0.replacingOccurrences(of: "{файл}", with: audio.path)
              .replacingOccurrences(of: "{file}", with: audio.path)
        }

        let output = try run(executable, arguments, audio)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.engineSaidNothing }
        return text
    }

    /// Запуск настоящего процесса.
    public static let processRunner: Runner = { executable, arguments, _ in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Читать до завершения, а не после: движок, напечатавший больше буфера
        // трубы, иначе повиснет навсегда.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw TranscriberError.engineFailed(
                message.isEmpty ? "код \(process.terminationStatus)" : message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
