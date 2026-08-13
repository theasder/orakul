import Foundation
import Testing
@testable import OrakulCore

/// Командная строка — первое, что человек трогает руками, и единственное, что
/// он видит, когда что-то пошло не так. Сообщение об ошибке здесь такая же
/// часть продукта, как поиск.
@Suite("Командная строка")
struct CommandLineAppTests {

    // MARK: - «Файл пустой», когда он не пустой

    @Test("файл из одних отметок времени не называется пустым")
    func fileWithOnlyTimestampsIsNotCalledEmpty() {
        // Экспорт субтитров без реплик — 69 байт разметки и ни одного слова.
        // Текст исчезает при чистке, и человек получал «Файл пустой —
        // сохранять нечего». Он открывает файл, видит там содержимое и не
        // понимает, кому верить.
        //
        // Тот же класс, что записан в плане: уверенная фраза об операции,
        // которой не было. Файл прочитан, он не пуст; пустым он стал у нас.
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:04.320

        00:00:04.320 --> 00:00:09.100
        """
        let (app, _) = makeApp(files: ["с.vtt": vtt])
        let result = app.run(["добавить", "с.vtt", "Планёрка"])

        #expect(!result.output.contains("Файл пустой"),
                "непустой файл назван пустым: «\(result.output)»")
        #expect(result.output.contains("реплик") || result.output.contains("текста"),
                "не сказано, чего в файле не нашлось: «\(result.output)»")
        #expect(result.exitCode != 0, "нечего сохранять — это отказ")
    }

    @Test("по-настоящему пустой файл так и называется")
    func genuinelyEmptyFileKeepsItsMessage() {
        // Граница: когда файл действительно пуст, прежняя фраза верна и
        // должна остаться — она короче и понятнее.
        let (app, _) = makeApp(files: ["п.txt": "   \n\n  "])
        let result = app.run(["добавить", "п.txt", "Планёрка"])
        #expect(result.output.contains("пуст"), "получилось: «\(result.output)»")
        #expect(result.exitCode != 0)
    }

    // MARK: - Название встречи

    @Test("перевод строки в названии не ломает список")
    func newlineInTitleDoesNotBreakTheList() {
        // `orakul список` — построчный вывод: дата, идентификатор, название.
        // Название приходит от человека как есть, и перевод строки в нём
        // разрывает запись надвое. Вторая половина выглядит как ЕЩЁ ОДНА
        // встреча — без даты и идентификатора, но отличить её нельзя ни
        // глазом, ни скриптом, а список зовут разбирать: архив у нас открытый.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли."])
        _ = app.run(["добавить", "з.txt", "Первая строка\nВторая строка"])

        let listing = app.run(["список"]).output
        let rows = listing.split(separator: "\n").filter { !$0.isEmpty }
        #expect(rows.count == 1, "одна встреча заняла \(rows.count) строк: «\(listing)»")
        #expect(listing.contains("Первая строка"), "название потерялось")
        #expect(listing.contains("Вторая строка"), "часть названия выброшена")
    }

    @Test("очень длинное название не затапливает строку")
    func veryLongTitleIsShortened() {
        // Скрипт, берущий первую строку расшифровки как название, легко
        // принесёт триста символов. Столбцы после этого не столбцы.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли."])
        _ = app.run(["добавить", "з.txt", String(repeating: "О", count: 300)])

        let listing = app.run(["список"]).output
        let longest = listing.split(separator: "\n").map(\.count).max() ?? 0
        #expect(longest < 200, "строка списка длиной \(longest) символов")
        #expect(listing.contains("…"), "обрезка не показана — текст пропал молча")
    }

    @Test("обычное название не трогаем")
    func ordinaryTitleIsUntouched() {
        // Граница: чистка не должна менять то, что человек написал.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли."])
        _ = app.run(["добавить", "з.txt", "Планёрка по тарифам"])
        #expect(app.run(["список"]).output.contains("Планёрка по тарифам"),
                "обычное название испорчено")
    }

    // MARK: - Повторное добавление

    @Test("та же расшифровка второй раз не заводит вторую встречу")
    func addingTheSameTranscriptTwiceIsNoticed() {
        // Повторить `добавить` на том же файле — дело одной стрелки вверх, а
        // ещё это делают скрипты при повторном импорте. Дубли не безобидны:
        // ответ показывает не больше трёх встреч, поэтому три копии одного
        // звонка занимают ВСЕ три места. Человек с полусотней разных звонков
        // видит один и тот же трижды и больше ничего.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли на пятнадцать процентов."])
        let first = app.run(["добавить", "з.txt", "Планёрка"])
        #expect(first.output.contains("Добавлено"))

        let second = app.run(["добавить", "з.txt", "Планёрка"])
        #expect(!second.output.contains("Добавлено"),
                "вторая копия завелась молча: «\(second.output)»")
        #expect(second.output.contains("уже есть"),
                "не сказано, что такая расшифровка уже в архиве: «\(second.output)»")
        // Уже лежит в архиве — это и есть то, чего человек хотел, не сбой.
        #expect(second.exitCode == 0, "повтор объявлен ошибкой")

        #expect(app.run(["список"]).output
            .components(separatedBy: "Планёрка").count - 1 == 1,
                "в архиве больше одной копии")
    }

    @Test("ответ не занимают копии одного звонка")
    func duplicatesDoNotCrowdOutTheAnswer() {
        // То, ради чего всё это: три места в ответе должны достаться трём
        // РАЗНЫМ звонкам.
        let (app, _) = makeApp(files: [
            "1.txt": "Аня: По тарифам подняли на пятнадцать процентов.",
            "2.txt": "Борис: По тарифам решили не трогать годовой.",
        ])
        _ = app.run(["добавить", "1.txt", "Первая"])
        _ = app.run(["добавить", "1.txt", "Повтор"])
        _ = app.run(["добавить", "2.txt", "Вторая"])

        let found = app.run(["найти", "что", "решили", "по", "тарифам"]).output
        #expect(found.contains("Первая") && found.contains("Вторая"),
                "разные звонки не попали в ответ: «\(found)»")
        #expect(!found.contains("Повтор"), "копия заняла место в ответе")
    }

    @Test("после удаления ту же расшифровку можно добавить снова")
    func deletingFreesTheTranscript() throws {
        // Обычный способ исправить неудачное название: удалить и добавить
        // заново. Проверка на дубль не должна этому мешать — иначе она чинит
        // одно и ломает другое, а человек остаётся без звонка вовсе.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли на пятнадцать."])
        let added = app.run(["добавить", "з.txt", "Опечатка в названии"])
        let id = try #require(added.output.split(separator: "(").last?.dropLast(),
                              "не разобрать идентификатор")
        #expect(app.run(["удалить", String(id)]).exitCode == 0)

        let again = app.run(["добавить", "з.txt", "Планёрка по тарифам"])
        #expect(again.output.contains("Добавлено"),
                "после удаления добавить не дали: «\(again.output)»")
        #expect(app.run(["найти", "что", "решили", "по", "тарифам"]).output
            .contains("Планёрка по тарифам"), "звонок не ищется после повторного добавления")
    }

    @Test("другой текст с тем же названием добавляется")
    func sameTitleDifferentTextStillAdds() {
        // Граница: одинаковое НАЗВАНИЕ — обычное дело, планёрки называют
        // одинаково каждую неделю. Отказ должен смотреть на текст.
        let (app, _) = makeApp(files: [
            "1.txt": "Аня: На этой неделе подняли лимиты.",
            "2.txt": "Аня: На следующей неделе выкатываем биллинг.",
        ])
        _ = app.run(["добавить", "1.txt", "Планёрка"])
        let second = app.run(["добавить", "2.txt", "Планёрка"])
        #expect(second.output.contains("Добавлено"),
                "разные расшифровки под одним названием не добавились: «\(second.output)»")
    }

    // MARK: - Кодировка расшифровки

    @Test("расшифровка в Windows-1251 читается, а не отвергается")
    func cp1251TranscriptIsRead() throws {
        // Продукт делается для русской команды, а в русском обиходе полно
        // файлов в CP1251: выгрузка из старого инструмента, текст, сохранённый
        // коллегой на Windows. `String(contentsOfFile:encoding: .utf8)` на
        // таком файле возвращает nil, и человек получал «Не смог прочитать
        // файл: <путь>» — сообщение, отправляющее проверять путь и права,
        // тогда как файл на месте и прекрасно читается.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("cp1251.txt")
        let text = "Аня: По тарифам решили поднять месячный на пятнадцать процентов."
        let data = try #require(text.data(using: .windowsCP1251), "нет кодировки CP1251")
        try data.write(to: path)

        let store = SessionStore(root: root.appendingPathComponent("архив", isDirectory: true))
        let app = CommandLineApp(store: store, today: { "2026-07-24" },
                                 makeIdentifier: { "1" })
        let added = app.run(["добавить", path.path, "Планёрка"])
        #expect(added.exitCode == 0, "CP1251 не прочитался: «\(added.output)»")

        // И текст должен быть текстом, а не мусором из перепутанных байтов.
        let found = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(found.output.contains("пятнадцать процентов"),
                "текст расшифровки испорчен: «\(found.output)»")
    }

    @Test("расшифровка в UTF-16 тоже читается")
    func utf16TranscriptIsRead() throws {
        // «Юникод» в блокноте Windows — это UTF-16 с меткой порядка байтов.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("utf16.txt")
        let text = "Борис: Годовой тариф не трогаем до декабря."
        try #require(text.data(using: .utf16)).write(to: path)

        let store = SessionStore(root: root.appendingPathComponent("архив", isDirectory: true))
        let app = CommandLineApp(store: store, today: { "2026-07-24" },
                                 makeIdentifier: { "1" })
        let added = app.run(["добавить", path.path, "Планёрка"])
        #expect(added.exitCode == 0, "UTF-16 не прочитался: «\(added.output)»")
        #expect(app.run(["найти", "годовой", "тариф"]).output.contains("до декабря"),
                "текст UTF-16 испорчен")
    }

    @Test("картинка по-прежнему отвергается")
    func binaryFileIsStillRefused() throws {
        // Граница, без которой запасная кодировка опасна.
        //
        // Байты взяты не случайные, а заголовок PNG: измерено, что Foundation
        // ОТКАЗЫВАЕТСЯ читать в CP1251 набор из всех 256 байт (там есть
        // неопределённый байт), и проверка на таком файле прошла бы сама
        // собой, ничего не проверив. А вот заголовок PNG в CP1251 читается
        // прекрасно — и даёт тридцать управляющих символов. Настоящий русский
        // текст в той же кодировке даёт ноль. Это и отличает их.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-enc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("картинка.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                 + (0..<40).map { UInt8($0) }).write(to: path)

        let store = SessionStore(root: root.appendingPathComponent("архив", isDirectory: true))
        let app = CommandLineApp(store: store, today: { "2026-07-24" },
                                 makeIdentifier: { "1" })
        let added = app.run(["добавить", path.path, "Планёрка"])
        #expect(added.exitCode != 0, "двоичный файл уехал в архив: «\(added.output)»")
    }

    // MARK: - Нечитаемые файлы архива

    @Test("поиск признаётся, что часть архива не прочиталась")
    func searchAdmitsUnreadableFiles() throws {
        // Страница зовёт открывать архив: «обычные JSON-файлы, их можно читать
        // и без нас». Раз зовёт — файл рано или поздно окажется испорченным:
        // недописанным при сбое, перекодированным редактором, недосинхро-
        // низированным. `orakul список` про такой файл говорит. `orakul найти`
        // молчал и отвечал «в сохранённых звонках об этом не говорили» —
        // уверенный отказ поверх архива, часть которого он не открыл.
        //
        // Для продукта, у которого честность ответа и есть продукт, это хуже
        // пустого результата: человек уходит уверенным, что не обсуждали.
        let (app, store) = makeApp(files: ["з.txt": "Аня: Обсудили дизайн главной."])
        _ = app.run(["добавить", "з.txt", "Планёрка по дизайну"])

        // Второй файл — «испорченный вручную».
        let broken = store.root.appendingPathComponent("сломанный.json")
        try Data("{\"id\": \"x\", \"tit".utf8).write(to: broken)

        let result = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(result.output.contains("сломанный.json"),
                "не назван файл, который не прочитался: «\(result.output)»")
        #expect(result.output.lowercased().contains("не смог прочитать")
                || result.output.lowercased().contains("не прочит"),
                "не сказано, что часть архива не открылась: «\(result.output)»")
    }

    @Test("находки при этом остаются находками")
    func unreadableFileDoesNotHideTheHits() throws {
        // Предупреждение не должно подменять ответ: то, что прочиталось,
        // человек обязан получить.
        let (app, store) = makeApp(files: ["з.txt": "Аня: По тарифам подняли на пятнадцать процентов."])
        _ = app.run(["добавить", "з.txt", "Планёрка по тарифам"])
        let broken = store.root.appendingPathComponent("сломанный.json")
        try Data("{".utf8).write(to: broken)

        let result = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(result.output.contains("Планёрка по тарифам"), "находка потерялась")
        #expect(result.output.contains("сломанный.json"), "предупреждение пропало")
    }

    @Test("на целом архиве поиск не жалуется")
    func cleanArchiveStaysQuiet() {
        // Граница: предупреждение, которое печатается всегда, перестают читать
        // за день. У целого архива вывод обязан остаться прежним.
        let (app, _) = makeApp(files: ["з.txt": "Аня: По тарифам подняли на пятнадцать."])
        _ = app.run(["добавить", "з.txt", "Планёрка"])

        let result = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(!result.output.lowercased().contains("не прочит"),
                "жалуется на целом архиве: «\(result.output)»")
    }

    @Test("посторонний файл в папке архива — не поломка")
    func foreignFileIsNotAFailure() throws {
        // В папке архива живут и чужие файлы — заметка, .DS_Store. Они не наши,
        // и объявлять их непрочитанными значит пугать на ровном месте.
        let (app, store) = makeApp(files: ["з.txt": "Аня: По тарифам подняли."])
        _ = app.run(["добавить", "з.txt", "Планёрка"])
        try Data("заметка".utf8).write(to: store.root.appendingPathComponent("заметки.txt"))

        let result = app.run(["найти", "что", "решили", "по", "тарифам"])
        #expect(!result.output.contains("заметки.txt"), "чужой файл выдан за поломку")
    }

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

@Suite("Слово продукта одно на всех поверхностях")
struct ProductVocabularyTests {
    /// Страница проверяет это про себя с самого начала: продукт говорит
    /// «звонок». В командной строке при этом стояло «поиск по своим
    /// созвонам» — первая строка, которую видит каждый, кто запустил `orakul`,
    /// и единственное место, где слово расходилось.
    ///
    /// Проверяется текст для человека, а не комментарии: в исходниках ядра
    /// «созвон» встречается три десятка раз, и это нормально — читают их
    /// разработчики, а не пользователи.
    @Test("в текстах командной строки нет «созвон»")
    func commandLineSpeaksTheProductWord() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OrakulCore")
        let manager = FileManager.default
        let walker = try #require(manager.enumerator(atPath: root.path))

        var offenders: [String] = []
        var scanned = 0
        for case let path as String in walker where path.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            scanned += 1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Кавычка как признак «это текст» не годится: подсказка и
                // сообщения об ошибках лежат в многострочных блоках, где
                // кавычек на строке нет. Первая версия проверки требовала
                // кавычку и пропустила «Такой встречи нет» — мутация прошла
                // зелёной. Русские слова вне комментариев в Swift и есть текст
                // для человека: имена типов и переменных здесь латиницей.
                // Два слова, одно правило: у записанного звонка одно имя.
                // Страница проверяет ровно это — «созвон» и «встреча» там
                // запрещены оба, потому что читаются как два разных продукта.
                for second in ["созвон", "встреч"] where line.lowercased().contains(second) {
                    offenders.append("\(path): \(trimmed.prefix(60))")
                }
            }
        }
        #expect(scanned > 10, "обход нашёл \(scanned) файлов — проверка была бы фиктивной")
        #expect(offenders.isEmpty,
                "продукт говорит «звонок», а здесь «созвон»:\n\(offenders.joined(separator: "\n"))")
    }

    @Test("подсказка командной строки говорит «звонкам»")
    func usageUsesTheProductWord() {
        #expect(CommandLineApp.usage.contains("звонкам"))
        #expect(!CommandLineApp.usage.lowercased().contains("созвон"))
        #expect(!CommandLineApp.usage.lowercased().contains("встреч"),
                "«встреча» — второе имя тому же звонку")
    }
}
