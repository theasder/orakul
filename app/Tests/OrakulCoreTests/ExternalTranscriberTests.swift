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
