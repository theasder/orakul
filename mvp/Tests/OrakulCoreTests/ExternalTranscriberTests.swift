import Foundation
import Testing
@testable import OrakulCore

/// Расшифровщик запускает чужую программу — значит, всё, что может пойти не
/// так, пойдёт не так у пользователя, а не у нас. Настоящий процесс здесь не
/// запускается: тест, зависящий от того, стоит ли на машине whisper, проверяет
/// машину, а не код.
@Suite("Внешний расшифровщик")
struct ExternalTranscriberTests {

    // MARK: - WAV

    @Test("заголовок WAV — канонические сорок четыре байта")
    func wavHeaderIsCorrect() {
        let data = WAVFile.encode(samples: [0, 0, 0, 0])
        #expect(data.count == 44 + 8, "заголовок плюс четыре сэмпла по два байта")

        func string(_ range: Range<Int>) -> String {
            String(decoding: data[range], as: UTF8.self)
        }
        #expect(string(0..<4) == "RIFF")
        #expect(string(8..<12) == "WAVE")
        #expect(string(12..<16) == "fmt ")
        #expect(string(36..<40) == "data")
        #expect(data[22] == 1 && data[23] == 0, "каналов должно быть ровно один")
        #expect(data[24] == 0x80 && data[25] == 0x3E, "частота 16000 Гц")
    }

    @Test("громкий сэмпл обрезается, а не переполняется")
    func loudSamplesAreClamped() {
        // Значение за пределами -1…1 при переводе в Int16 переполнилось бы и
        // превратило громкий фрагмент в треск — то есть в мусор для движка.
        let data = WAVFile.encode(samples: [2.0, -2.0])
        let first = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44, as: Int16.self) }
        let second = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 46, as: Int16.self) }
        #expect(Int16(littleEndian: first) == 32_767)
        #expect(Int16(littleEndian: second) == -32_767)
    }

    @Test("тишина кодируется, а не выбрасывается")
    func emptySamplesStillProduceAValidFile() {
        // Пустой WAV — валидный WAV. Движок сам скажет, что там ничего нет.
        #expect(WAVFile.encode(samples: []).count == 44)
    }

    // MARK: - Чтение WAV

    @Test("что записали, то и прочитали")
    func encodeDecodeRoundTrip() throws {
        let original: [Float] = [0, 0.5, -0.5, 1, -1]
        let decoded = try WAVFile.decode(WAVFile.encode(samples: original))
        #expect(decoded.count == original.count)
        for (a, b) in zip(original, decoded) {
            #expect(abs(a - b) < 0.001, "сэмпл изменился при записи и чтении")
        }
    }

    @Test("не-WAV отклоняется, а не читается как шум")
    func garbageIsRejected() {
        #expect(throws: WAVFile.DecodeError.notRIFF) {
            try WAVFile.decode(Data("это просто текст, а не запись".utf8))
        }
        #expect(throws: WAVFile.DecodeError.notRIFF) { try WAVFile.decode(Data()) }
    }

    @Test("частота не 16 кГц — отказ с названной частотой")
    func wrongSampleRateIsNamed() {
        // Пересчитать молча — значит тихо ухудшить распознавание. Человек
        // должен узнать частоту, чтобы сконвертировать файл самому.
        #expect(throws: WAVFile.DecodeError.unsupportedSampleRate(44_100)) {
            try WAVFile.decode(WAVFile.encode(samples: [0.1], sampleRate: 44_100))
        }
    }

    @Test("стерео сводится в моно, а не читается как двойная скорость")
    func stereoIsMixedDown() throws {
        // Стерео, прочитанное как моно, звучит вдвое быстрее и распознаётся
        // как каша. Каналы усредняются.
        var data = WAVFile.encode(samples: [])
        data[22] = 2                                   // channels = 2
        let left: [Int16] = [16_000, -16_000]
        let right: [Int16] = [16_000, -16_000]
        var payload = Data()
        for (l, r) in zip(left, right) {
            withUnsafeBytes(of: l.littleEndian) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: r.littleEndian) { payload.append(contentsOf: $0) }
        }
        var sized = data
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes in
            sized.replaceSubrange(40..<44, with: bytes)
        }
        let decoded = try WAVFile.decode(sized + payload)
        #expect(decoded.count == 2, "каналы не свелись в моно")
    }

    @Test("посторонний блок между fmt и data не ломает чтение")
    func unknownChunksAreSkipped() throws {
        // Диктофоны вставляют LIST с названием устройства. Файл, прочитанный
        // «по фиксированным смещениям», превратился бы в шум.
        let base = WAVFile.encode(samples: [0.25, -0.25])
        var withList = base[0..<36]
        withList.append(contentsOf: Array("LIST".utf8))
        withUnsafeBytes(of: UInt32(4).littleEndian) { withList.append(contentsOf: $0) }
        withList.append(contentsOf: Array("INFO".utf8))
        withList.append(contentsOf: base[36...])

        let decoded = try WAVFile.decode(Data(withList))
        #expect(decoded.count == 2)
    }

    // MARK: - Запуск движка

    @Test("аудио попадает в команду на место подстановки")
    func audioPathIsSubstituted() async throws {
        let seen = Box()
        let transcriber = ExternalTranscriber(
            command: "whisper-cli -l ru -f {файл}",
            run: { executable, arguments, _ in
                seen.value = ([executable] + arguments).joined(separator: " ")
                return "Решили выкатить в прод."
            })

        let text = try await transcriber.transcribe(samples: [0.1, 0.2])
        #expect(text == "Решили выкатить в прод.")
        #expect(seen.value.contains("whisper-cli"))
        #expect(seen.value.contains(".wav"), "движку не передали файл")
        #expect(!seen.value.contains("{файл}"), "подстановка не сработала")
    }

    @Test("английская подстановка тоже работает")
    func englishPlaceholder() async throws {
        let transcriber = ExternalTranscriber(command: "engine -f {file}",
                                              run: { _, _, _ in "текст" })
        let text = try await transcriber.transcribe(samples: [])
        #expect(text == "текст")
    }

    @Test("команда без подстановки отклоняется до запуска")
    func missingPlaceholderIsRejected() async {
        // Иначе движок запустится без аудио и вернёт расшифровку тишины —
        // пустой результат, выглядящий как «никто ничего не сказал».
        let transcriber = ExternalTranscriber(command: "whisper-cli -l ru",
                                              run: { _, _, _ in "не должно вызваться" })
        await #expect(throws: ExternalTranscriber.TranscriberError.commandHasNoFilePlaceholder) {
            try await transcriber.transcribe(samples: [0.1])
        }
    }

    @Test("пустая команда — ошибка настройки, а не пустой результат")
    func emptyCommandIsRejected() async {
        let transcriber = ExternalTranscriber(command: "", run: { _, _, _ in "" })
        await #expect(throws: ExternalTranscriber.TranscriberError.commandIsEmpty) {
            try await transcriber.transcribe(samples: [0.1])
        }
    }

    @Test("молчание движка не превращается в пустую встречу")
    func silentEngineThrows() async {
        // Пустая строка от движка — сбой распознавания, а не созвон, на котором
        // никто не говорил. Разница видна только здесь.
        let transcriber = ExternalTranscriber(command: "engine -f {файл}",
                                              run: { _, _, _ in "   \n " })
        await #expect(throws: ExternalTranscriber.TranscriberError.engineSaidNothing) {
            try await transcriber.transcribe(samples: [0.1])
        }
    }

    @Test("ошибка движка доходит до пользователя его же словами")
    func engineFailureIsPropagated() async {
        let transcriber = ExternalTranscriber(
            command: "engine -f {файл}",
            run: { _, _, _ in
                throw ExternalTranscriber.TranscriberError.engineFailed("нет модели")
            })
        await #expect(throws: ExternalTranscriber.TranscriberError.engineFailed("нет модели")) {
            try await transcriber.transcribe(samples: [0.1])
        }
    }

    @Test("один битый байт не съедает всю расшифровку")
    func invalidUTF8DoesNotDiscardTheTranscript() async throws {
        // Найдено на живом прогоне: движок-заглушка подмешал в вывод бинарные
        // байты, строгий UTF-8 вернул nil, и весь текст пропал под сообщением
        // «движок промолчал». Настоящий движок с одним сбойным байтом стоил бы
        // человеку целого созвона.
        var mixed = Data("Решили выкатить в прод.".utf8)
        mixed.append(contentsOf: [0xFF, 0xFE])
        let transcriber = ExternalTranscriber(
            command: "engine -f {файл}",
            run: { _, _, _ in String(decoding: mixed, as: UTF8.self) })

        let text = try await transcriber.transcribe(samples: [0.1])
        #expect(text.contains("Решили выкатить в прод"))
    }

    @Test("временный файл убирается за собой")
    func temporaryFileIsRemoved() async throws {
        let seen = Box()
        let transcriber = ExternalTranscriber(command: "engine -f {файл}",
                                              run: { _, _, audio in
            seen.value = audio.path
            return "текст"
        })
        _ = try await transcriber.transcribe(samples: [0.1])
        // Расшифровки чужих созвонов не должны копиться во временной папке.
        #expect(!FileManager.default.fileExists(atPath: seen.value))
    }

    @Test("расшифровка проходит через конвейер и попадает в архив")
    func worksInsideThePipeline() async throws {
        let store = SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-ext-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }

        let transcriber = ExternalTranscriber(command: "engine -f {файл}",
                                              run: { _, _, _ in "Решили выкатить в prod." })
        let pipeline = MeetingPipeline(transcriber: transcriber, store: store,
                                       today: { "2026-07-24" }, makeIdentifier: { "s1" })
        try await pipeline.record(samples: [0.1], title: "Планёрка")

        // И словарь по дороге отработал: prod → прод.
        #expect(store.load().sessions.first?.digest.contains("прод") == true)
    }
}

/// Коробка под замком: замыкание помечено `Sendable`, и захват изменяемой
/// переменной напрямую был бы гонкой.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
