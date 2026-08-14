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

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notRIFF
        case notPCM16
        /// Частоту не пересчитываем: плохой ресемплер портит распознавание
        /// тише, чем отказ, и человек об этом не узнает.
        case unsupportedSampleRate(Int)

        public var description: String {
            switch self {
            case .notRIFF:
                return "Это не WAV-файл: в начале нет заголовка RIFF."
            case .notPCM16:
                return "WAV не в формате PCM 16 бит. Переведите так: "
                    + "ffmpeg -i запись -ar 16000 -ac 1 -sample_fmt s16 запись-16k.wav"
            case .unsupportedSampleRate(let rate):
                return "Запись на \(rate) Гц, а движку нужно 16000. "
                    + "Переведите её заранее: ffmpeg -i запись -ar 16000 -ac 1 запись-16k.wav"
            }
        }
    }

    /// Сэмплы из WAV-файла. Стерео сводится в моно усреднением каналов.
    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count >= 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw DecodeError.notRIFF
        }

        func uint16(at offset: Int) -> Int {
            Int(data.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            })
        }
        func uint32(at offset: Int) -> Int {
            Int(data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            })
        }

        // Блоки идут в произвольном порядке, и между fmt и data встречаются
        // чужие: файл от диктофона с LIST-блоком иначе прочитался бы как шум.
        var offset = 12
        var channels = 1
        var rate = sampleRate
        var bits = 16
        var format = 1
        var payload: Range<Int>?

        while offset + 8 <= data.count {
            let identifier = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = uint32(at: offset + 4)
            let body = offset + 8
            guard size >= 0, body + size <= data.count || identifier == "data" else { break }

            if identifier == "fmt " {
                format = uint16(at: body)
                channels = max(1, uint16(at: body + 2))
                rate = uint32(at: body + 4)
                bits = uint16(at: body + 14)
            } else if identifier == "data" {
                payload = body..<min(body + size, data.count)
                break
            }
            offset = body + size + (size % 2)   // блоки выровнены по чётности
        }

        guard format == 1, bits == 16 else { throw DecodeError.notPCM16 }
        guard rate == sampleRate else { throw DecodeError.unsupportedSampleRate(rate) }
        guard let payload, !payload.isEmpty else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2 / channels)
        var index = payload.lowerBound
        while index + 2 * channels <= payload.upperBound {
            var sum = 0.0
            for channel in 0..<channels {
                let raw = data.withUnsafeBytes {
                    Int16(littleEndian: $0.loadUnaligned(fromByteOffset: index + channel * 2,
                                                         as: Int16.self))
                }
                sum += Double(raw) / 32_767
            }
            samples.append(Float(sum / Double(channels)))
            index += 2 * channels
        }
        return samples
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

    public enum TranscriberError: Error, Equatable, CustomStringConvertible {
        case commandIsEmpty
        case commandHasNoFilePlaceholder
        case engineFailed(String)
        case engineSaidNothing
        /// Движок напечатал байты, но это не речь.
        case engineSaidGibberish(letters: Int, total: Int)

        /// По-русски и с действием.
        ///
        /// Печаталось `engineFailed("движок упал\n")` — имя случая
        /// перечисления прямо в строке для человека. Соседние сообщения этой же
        /// команды написаны нормально («Запись на 44100 Гц, а движку нужно
        /// 16000»), и разница видна только в момент отказа: там, где человеку
        /// и нужна помощь, он получал внутренности.
        public var description: String {
            switch self {
            case .commandIsEmpty:
                return "В ORAKUL_ENGINE пустая команда — запускать нечего."
            case .commandHasNoFilePlaceholder:
                return "В команде нет места для файла. Добавьте {файл} — "
                    + "orakul подставит туда путь к записи."
            case .engineFailed(let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = detail.isEmpty ? "Движок ничего не сказал о причине."
                                          : "Движок ответил: \(detail)"
                return "Движок распознавания не справился. \(tail)"
            case .engineSaidNothing:
                return "Движок отработал, но текста не вернул. Обычно это "
                    + "тишина в записи или неверные ключи запуска — проверьте "
                    + "команду в ORAKUL_ENGINE на этом же файле вручную."
            case .engineSaidGibberish(let letters, let total):
                return "Движок вернул не текст: букв \(letters) из \(total) знаков. "
                    + "Обычно в ORAKUL_ENGINE стоит не та программа — например, "
                    + "путь к модели вместо распознавателя, — и она печатает "
                    + "двоичные данные. Проверьте команду на этом же файле вручную."
            }
        }
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
        try Self.checkLooksLikeSpeech(text)
        return text
    }

    /// Похоже ли это на речь вообще.
    ///
    /// Пустой вывод продукт уже отвергал, а двоичный мусор — нет: сообщение
    /// «Расшифровано» и запись в архив, где вместо разговора лежат байты.
    /// Случай не выдуманный: в ORAKUL_ENGINE легко указать не ту программу —
    /// скажем, путь к файлу модели вместо распознавателя, — и она напечатает
    /// в stdout что угодно.
    ///
    /// Порог намеренно очень низкий: у настоящей расшифровки, русской или
    /// английской, букв и пробелов свыше девяти десятых. Треть — это заведомо
    /// не речь, и при этом не мешает диктовке кода или расшифровке, полной
    /// цифр и знаков.
    static func checkLooksLikeSpeech(_ text: String) throws {
        let total = text.count
        guard total > 0 else { return }
        let letters = text.reduce(into: 0) { count, character in
            if character.isLetter || character.isWhitespace { count += 1 }
        }
        // Считается только доля букв. Отдельного правила про знаки замены тут
        // было: «не больше пяти процентов». Оно ломало то, что продукт уже
        // решил терпеть — один сбойный байт в короткой строке: «Решили
        // выкатить в прод.» плюс два таких знака давало 8%, и целая
        // расшифровка отвергалась из-за одного байта. Знак замены и так не
        // буква, доли букв достаточно.
        guard letters * 3 >= total else {
            throw TranscriberError.engineSaidGibberish(letters: letters, total: total)
        }
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
        // Декодируем терпимо. Строгий UTF-8 возвращает nil на ОДНОМ битом
        // байте и выбрасывает вместе с ним всю расшифровку — движок, который
        // подмешал в вывод хоть что-то нетекстовое, стоил бы человеку целого
        // созвона, а сообщение гласило бы «движок промолчал».
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
