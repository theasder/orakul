import Foundation
import Testing
@testable import OrakulCore

/// Командная строка — первое, что человек трогает руками, и единственное, что
/// он видит, когда что-то пошло не так. Сообщение об ошибке здесь такая же
/// часть продукта, как поиск.
@Suite("Командная строка")
struct CommandLineAppTests {

    // MARK: - Первые пять минут

    @Test("удаление несуществующего не выдаётся за успех")
    func deletingWhatIsNotThereFails() throws {
        // Было: «Удалено: нет-такого» и код возврата ноль. То есть команда
        // сообщала об удалении записи, которой никогда не было, — и `orakul
        // удалить $id && дальше` продолжал работу по опечатке в
        // идентификаторе. Хранилище молча пропускает отсутствующий файл, а
        // команда трактовала отсутствие ошибки как выполненную работу.
        let (app, _) = makeApp()
        let result = app.run(["удалить", "нет-такого-идентификатора"])

        #expect(result.exitCode != 0, "удаление пустоты вернуло успех")
        #expect(!result.output.contains("Удалено"),
                "сказано «удалено» про то, чего не было: «\(result.output)»")
        #expect(result.output.contains("нет-такого-идентификатора"),
                "не названо, что именно не нашлось")
    }

    @Test("удаление существующего по-прежнему успех")
    func deletingWhatIsThereSucceeds() throws {
        // Обратная сторона: если ужесточить проверку неаккуратно, перестанет
        // работать обычное удаление.
        let (app, _) = makeApp(files: ["з.txt": "Аня: Решили поднять лимиты."])
        let added = app.run(["добавить", "з.txt", "Планёрка"])
        let id = try #require(added.output.split(separator: "(").last?.dropLast(),
                              "не разобрать идентификатор из «\(added.output)»")

        let result = app.run(["удалить", String(id)])
        #expect(result.exitCode == 0, "обычное удаление сломалось: «\(result.output)»")
        #expect(result.output.contains("Удалено"))
    }

    @Test("пустой архив не выдаётся за архив без совпадений")
    func emptyArchiveSaysSo() {
        // «В сохранённых звонках об этом не говорили» — правда, когда звонки
        // есть. На пустом архиве это утверждение о несуществующих записях, и
        // первым, кто его читает, оказывается человек, запустивший `найти`
        // раньше `добавить`. `список` эту разницу уже проводит.
        let (app, _) = makeApp()
        let result = app.run(["найти", "что", "решили", "по", "тарифам"])

        #expect(result.output.contains("пуст"),
                "на пустом архиве ответ про несуществующие звонки: «\(result.output)»")
        #expect(result.output.contains("добавить"),
                "не сказано, что делать дальше: «\(result.output)»")
        #expect(result.exitCode == 0, "пустой архив — не сбой")
    }

    @Test("архив не пуст, но совпадений нет — прежний ответ")
    func nonEmptyArchiveKeepsTheHonestAnswer() {
        // Именно тот случай, ради которого фраза и написана: звонки есть,
        // просто про это не говорили. Придумывать ответ по-прежнему нельзя.
        let (app, _) = makeApp(files: ["з.txt": "Аня: Обсудили дизайн главной."])
        _ = app.run(["добавить", "з.txt", "Планёрка по дизайну"])

        let result = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(result.output.contains("не говорили"),
                "потеряли честный ответ при непустом архиве: «\(result.output)»")
        #expect(!result.output.contains("пуст"), "непустой архив назван пустым")
    }

    private struct StubEngine: Transcriber {
        let text: String
        func transcribe(samples: [Float]) async throws -> String { text }
    }

    private func makeApp(files: [String: String] = [:],
                         audio: [String: Data] = [:],
                         engine: String? = nil,
                         recognised: String = "Решили выкатить в прод.")
        -> (app: CommandLineApp, store: SessionStore) {
        let store = SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-cli-\(UUID().uuidString)", isDirectory: true))
        let counter = Numbers()
        let app = CommandLineApp(
            store: store,
            today: { "2026-07-24" },
            makeIdentifier: { counter.next() },
            readFile: { files[$0] },
            readAudio: { audio[$0] },
            engineCommand: engine,
            transcriberFactory: { _ in StubEngine(text: recognised) })
        return (app, store)
    }

    private func cleanUp(_ store: SessionStore) {
        try? FileManager.default.removeItem(at: store.root)
    }

    @Test("без аргументов показывает, что умеет, и это не ошибка")
    func usageIsNotAnError() {
        let (app, store) = makeApp()
        defer { cleanUp(store) }

        let result = app.run([])
        #expect(result.exitCode == 0, "человек, спросивший «что ты умеешь», не ошибся")
        #expect(result.output.contains("orakul найти"))
    }

    @Test("незнакомая команда не молчит и показывает список команд")
    func unknownCommandExplains() {
        let (app, store) = makeApp()
        defer { cleanUp(store) }

        let result = app.run(["всё-сломать"])
        #expect(result.exitCode == 2)
        #expect(result.output.contains("Не знаю команду"))
        #expect(result.output.contains("orakul найти"), "рядом с отказом обязан быть список команд")
    }

    @Test("добавить и найти — весь путь за две команды")
    func addThenSearch() {
        let (app, store) = makeApp(files: [
            "planerka.txt": "Решили перейти на оплату за использование.",
        ])
        defer { cleanUp(store) }

        let added = app.run(["добавить", "planerka.txt", "Планёрка по тарифам"])
        #expect(added.exitCode == 0)
        #expect(added.output.contains("Планёрка по тарифам"))

        let found = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(found.exitCode == 0)
        #expect(found.output.contains("«Планёрка по тарифам», 24 июля 2026"))
        #expect(found.output.contains("оплату за использование"))
    }

    @Test("английские команды тоже работают")
    func englishAliases() {
        let (app, store) = makeApp(files: ["a.txt": "Решили выкатить релиз."])
        defer { cleanUp(store) }

        #expect(app.run(["add", "a.txt", "Созвон"]).exitCode == 0)
        #expect(app.run(["list"]).output.contains("Созвон"))
        #expect(app.run(["search", "релиз"]).output.contains("релиз"))
    }

    @Test("словарь применяется при добавлении, а не при показе")
    func lexiconRunsOnAdd() {
        let (app, store) = makeApp(files: ["a.txt": "Выкатили в prod и дёрнули api."])
        defer { cleanUp(store) }

        _ = app.run(["добавить", "a.txt", "Созвон"])
        let saved = store.load().sessions.first
        #expect(saved?.digest.contains("прод") == true)
        #expect(saved?.digest.contains("API") == true)
    }

    @Test("без названия берётся имя файла, а не «Созвон» на весь список")
    func titleFallsBackToFilename() {
        let (app, store) = makeApp(files: ["/tmp/планёрка-по-тарифам.txt": "Решили."])
        defer { cleanUp(store) }

        _ = app.run(["добавить", "/tmp/планёрка-по-тарифам.txt"])
        #expect(store.load().sessions.first?.title == "планёрка-по-тарифам")
    }

    @Test("нечитаемый файл объясняется, а не роняет команду молча")
    func missingFileIsExplained() {
        let (app, store) = makeApp()
        defer { cleanUp(store) }

        let result = app.run(["добавить", "нет-такого.txt"])
        #expect(result.exitCode == 1)
        #expect(result.output.contains("нет-такого.txt"), "в сообщении обязан быть путь")
        #expect(store.load().sessions.isEmpty)
    }

    @Test("пустой файл не создаёт пустую встречу")
    func emptyFileSavesNothing() {
        let (app, store) = makeApp(files: ["пусто.txt": "   \n  "])
        defer { cleanUp(store) }

        #expect(app.run(["добавить", "пусто.txt"]).exitCode == 1)
        #expect(store.load().sessions.isEmpty)
    }

    @Test("ничего не найдено — это ответ, а не сбой")
    func nothingFoundIsSuccess() {
        let (app, store) = makeApp(files: ["a.txt": "Решили выкатить релиз."])
        defer { cleanUp(store) }
        _ = app.run(["добавить", "a.txt", "Созвон"])

        let result = app.run(["найти", "когда", "корпоратив"])
        // Нулевой код возврата важен: иначе скрипт, вызвавший orakul, решит,
        // что программа сломалась, хотя она честно ответила «не знаю».
        #expect(result.exitCode == 0)
        #expect(result.output.contains("придумывать не буду"))
    }

    @Test("вопрос без слов отклоняется с подсказкой")
    func emptyQueryIsRejected() {
        let (app, store) = makeApp()
        defer { cleanUp(store) }

        let result = app.run(["найти"])
        #expect(result.exitCode == 2)
        #expect(result.output.contains("Нужен вопрос"))
    }

    @Test("пустой архив предлагает следующий шаг, а не пустую строку")
    func emptyArchiveSuggestsWhatToDo() {
        let (app, store) = makeApp()
        defer { cleanUp(store) }

        let result = app.run(["список"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Архив пуст"))
        #expect(result.output.contains("добавить"))
    }

    @Test("непрочитанные файлы видны в списке")
    func skippedFilesAreVisible() throws {
        let (app, store) = makeApp(files: ["a.txt": "Решили."])
        defer { cleanUp(store) }
        _ = app.run(["добавить", "a.txt", "Созвон"])
        try Data("{ битый".utf8).write(to: store.root.appendingPathComponent("bad.json"))

        let result = app.run(["список"])
        #expect(result.output.contains("Не смог прочитать"))
        #expect(result.output.contains("bad.json"), "тихо потерянная встреча — худший исход")
    }

    @Test("запись расшифровывается и попадает в архив одной командой")
    func transcribeEndToEnd() {
        let wav = WAVFile.encode(samples: [0.1, -0.1, 0.2])
        let (app, store) = makeApp(audio: ["созвон.wav": wav],
                                   engine: "whisper -f {файл}",
                                   recognised: "Решили выкатить в prod.")
        defer { cleanUp(store) }

        let result = app.run(["расшифровать", "созвон.wav", "Планёрка"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Расшифровано"))

        // И сразу ищется — вся цепочка целиком, включая словарь.
        let found = app.run(["найти", "что решили про прод"])
        #expect(found.output.contains("Планёрка"))
        #expect(store.load().sessions.first?.digest.contains("прод") == true)
    }

    @Test("без настроенного движка команда объясняет, как его задать")
    func missingEngineExplainsItself() {
        let (app, store) = makeApp(audio: ["a.wav": WAVFile.encode(samples: [0.1])],
                                   engine: nil)
        defer { cleanUp(store) }

        let result = app.run(["расшифровать", "a.wav"])
        #expect(result.exitCode == 2)
        #expect(result.output.contains("ORAKUL_ENGINE"), "нужна готовая строка настройки")
        #expect(store.load().sessions.isEmpty)
    }

    @Test("чужая частота записи объясняется вместе с командой конвертации")
    func wrongSampleRateIsActionable() {
        let wav = WAVFile.encode(samples: [0.1], sampleRate: 44_100)
        let (app, store) = makeApp(audio: ["a.wav": wav], engine: "whisper -f {файл}")
        defer { cleanUp(store) }

        let result = app.run(["расшифровать", "a.wav"])
        #expect(result.exitCode == 1)
        #expect(result.output.contains("44100"), "человек должен узнать частоту своего файла")
        #expect(result.output.contains("ffmpeg"), "к отказу нужна команда, которой это чинится")
    }

    @Test("не-WAV не уходит движку впустую")
    func nonWavIsRejectedBeforeTheEngine() {
        let (app, store) = makeApp(audio: ["a.wav": Data("не запись".utf8)],
                                   engine: "whisper -f {файл}")
        defer { cleanUp(store) }

        let result = app.run(["расшифровать", "a.wav"])
        #expect(result.exitCode == 1)
        #expect(result.output.contains("PCM"))
    }

    @Test("удаление убирает встречу и не трогает соседние")
    func deleteRemovesOne() throws {
        let (app, store) = makeApp(files: ["a.txt": "Решили.", "b.txt": "Тоже решили."])
        defer { cleanUp(store) }

        _ = app.run(["добавить", "a.txt", "Первый"])
        _ = app.run(["добавить", "b.txt", "Второй"])
        let id = try #require(store.load().sessions.first?.id)

        #expect(app.run(["удалить", id]).exitCode == 0)
        #expect(store.load().sessions.count == 1)
        #expect(app.run(["удалить"]).exitCode == 2)
    }
}

/// Счётчик под замком: генератор идентификаторов помечен `Sendable`, а захват
/// изменяемой переменной из такого замыкания — гонка, а не мелочь.
private final class Numbers: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return "s\(value)"
    }
}
