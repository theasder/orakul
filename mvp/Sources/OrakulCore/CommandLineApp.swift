import Foundation

/// Командная строка orakul: то, что можно запустить уже сегодня.
///
/// Захвата звука ещё нет, но всё, что происходит с созвоном ПОСЛЕ расшифровки,
/// работает — и это можно попробовать на своих текстах, не дожидаясь
/// приложения. Для проекта, который меряется звёздами, разница между
/// «библиотека с тестами» и «команда, которую можно выполнить» решающая.
///
/// Разбор аргументов и текст вывода живут здесь, а не в `main.swift`: иначе их
/// нельзя проверить тестом, и первым, что сломается у человека, окажется
/// сообщение об ошибке.
public struct CommandLineApp {

    public struct Result: Equatable, Sendable {
        public let output: String
        /// Ненулевой код — «команда не сделала того, что просили».
        public let exitCode: Int32

        public init(output: String, exitCode: Int32) {
            self.output = output
            self.exitCode = exitCode
        }
    }

    let store: SessionStore
    let today: @Sendable () -> String
    let makeIdentifier: @Sendable () -> String
    let readFile: @Sendable (String) -> String?
    let readAudio: @Sendable (String) -> Data?
    /// Чем расшифровывать. Пусто — команда расшифровки объяснит, как настроить.
    let engineCommand: String?

    public init(store: SessionStore,
                today: @escaping @Sendable () -> String = MeetingPipeline.currentDay,
                makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
                readFile: @escaping @Sendable (String) -> String? = {
                    // Не строго UTF-8: русский транскрипт часто приходит в
                    // CP1251 или UTF-16, и отказ читать его выглядел как
                    // «файла нет». Разбор — в TranscriptFile.
                    TranscriptFile.read($0)
                },
                readAudio: @escaping @Sendable (String) -> Data? = {
                    try? Data(contentsOf: URL(fileURLWithPath: $0))
                },
                engineCommand: String? = ProcessInfo.processInfo.environment["ORAKUL_ENGINE"],
                transcriberFactory: (@Sendable (String) -> any Transcriber)? = nil) {
        self.store = store
        self.today = today
        self.makeIdentifier = makeIdentifier
        self.readFile = readFile
        self.readAudio = readAudio
        self.engineCommand = engineCommand
        self.makeTranscriber = transcriberFactory ?? { ExternalTranscriber(command: $0) }
    }

    let makeTranscriber: @Sendable (String) -> any Transcriber

    public static let usage = """
    orakul — поиск по своим созвонам, на русском и без сети

      orakul добавить <файл> [название]   готовая расшифровка в архив
      orakul расшифровать <wav> [название] расшифровать запись и положить в архив
      orakul найти <вопрос>               что решили по этому поводу
      orakul список                       что вообще есть в архиве
      orakul удалить <идентификатор>      убрать одну встречу
      orakul спросить <сервис> <вопрос>   спросить подключённый сервис

    Архив — обычные JSON-файлы: их можно читать и без нас.
    Сервисы: \(ConnectorQuery.services.joined(separator: ", ")).
    Токен — в ORAKUL_TOKEN. В ORAKUL_HOST — второе, что просит сервис: адрес
    своего сервера, организация Яндекс Трекера, адрес команды Kaiten. В
    ORAKUL_SCOPE — где искать: команда в мессенджере, репозитории для GitHub.
    Расшифровка идёт вашим движком: ORAKUL_ENGINE="whisper-cli -l ru -otxt -f {файл}"
    """

    /// Выполнить команду. Аргументы — без имени программы.
    public func run(_ arguments: [String]) -> Result {
        guard let command = arguments.first else {
            // Запуск без аргументов — не ошибка, а вопрос «что ты умеешь».
            return Result(output: Self.usage, exitCode: 0)
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "добавить", "add":
            return add(rest)
        case "расшифровать", "transcribe":
            return transcribe(rest)
        case "найти", "search":
            return search(rest)
        case "список", "list":
            return list()
        case "удалить", "delete":
            return delete(rest)
        case "помощь", "help", "--help", "-h":
            return Result(output: Self.usage, exitCode: 0)
        default:
            return Result(output: "Не знаю команду «\(command)».\n\n\(Self.usage)", exitCode: 2)
        }
    }

    // MARK: - Команды

    private func add(_ arguments: [String]) -> Result {
        guard let path = arguments.first else {
            return Result(output: "Нужен файл с расшифровкой: orakul добавить <файл>", exitCode: 2)
        }
        guard let raw = readFile(path) else {
            return Result(output: "Не смог прочитать файл: \(path)", exitCode: 1)
        }

        let text = RussianLexicon.restore(TranscriptCleanup.strip(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Result(output: "Файл пустой — сохранять нечего.", exitCode: 1)
        }

        // Такая расшифровка уже может лежать в архиве.
        //
        // Повторить `добавить` на том же файле — дело одной стрелки вверх, а
        // ещё так делают скрипты при повторном импорте. Дубли не безобидны:
        // ответ показывает не больше трёх встреч (`RecallAnswer`), поэтому три
        // копии одного звонка занимают ВСЕ три места, и человек с полусотней
        // разных звонков видит один и тот же трижды.
        //
        // Сравнивается текст ПОСЛЕ той же обработки, что у новой записи, —
        // иначе одна и та же расшифровка, прочитанная в другой кодировке или с
        // другими переводами строк, не совпала бы сама с собой. Название не
        // сравнивается: планёрки называют одинаково каждую неделю.
        if let existing = store.load().sessions.first(where: { $0.digest == text }) {
            return Result(output: """
            Такая расшифровка уже есть: «\(existing.title)» (\(existing.id))
            Ничего не добавил. Посмотреть архив: orakul список
            """, exitCode: 0)   // в архиве лежит то, чего хотели, — это не сбой
        }

        let title = arguments.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let session = RecallIndex.Session(
            id: makeIdentifier(),
            // Без названия берём имя файла: «Созвон» во всём списке не поможет
            // никому, а имя файла человек когда-то выбрал сам.
            title: title.isEmpty
                ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                : title,
            date: today(),
            digest: text)

        do {
            try store.save(session)
        } catch {
            return Result(output: "Не смог сохранить: \(error)", exitCode: 1)
        }
        return Result(output: "Добавлено: «\(session.title)» (\(session.id))", exitCode: 0)
    }

    private func transcribe(_ arguments: [String]) -> Result {
        guard let path = arguments.first else {
            return Result(output: "Нужен файл записи: orakul расшифровать <wav>", exitCode: 2)
        }
        guard let command = engineCommand, !command.isEmpty else {
            // Молча ничего не делать здесь нельзя: человек ждёт расшифровку и
            // должен узнать, чего именно не хватает.
            return Result(output: """
            Не настроен движок распознавания. orakul не возит свою модель — он \
            запускает вашу:

              export ORAKUL_ENGINE="whisper-cli -m модель.bin -l ru -otxt -f {файл}"
            """, exitCode: 2)
        }
        guard let data = readAudio(path) else {
            return Result(output: "Не смог прочитать запись: \(path)", exitCode: 1)
        }

        let samples: [Float]
        do {
            samples = try WAVFile.decode(data)
        } catch WAVFile.DecodeError.unsupportedSampleRate(let rate) {
            // Пересчитывать частоту молча — значит тихо ухудшить распознавание.
            return Result(output: """
            Запись на \(rate) Гц, а движку нужно 16000. Переведите её заранее:

              ffmpeg -i \(path) -ar 16000 -ac 1 запись-16k.wav
            """, exitCode: 1)
        } catch {
            return Result(output: "Не понял формат записи: нужен WAV, PCM 16 бит.", exitCode: 1)
        }

        let title = arguments.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pipeline = MeetingPipeline(transcriber: makeTranscriber(command), store: store,
                                       today: today, makeIdentifier: makeIdentifier)

        // Расшифровка асинхронная, командная строка — нет. Ждём здесь, иначе
        // программа завершится раньше движка.
        let outcome = Semaphore<Result>()
        Task {
            do {
                let session = try await pipeline.record(
                    samples: samples,
                    title: title.isEmpty
                        ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                        : title)
                outcome.set(Result(output: "Расшифровано: «\(session.title)» (\(session.id))",
                                   exitCode: 0))
            } catch {
                outcome.set(Result(output: "Не смог расшифровать: \(error)", exitCode: 1))
            }
        }
        return outcome.wait()
    }

    private func search(_ arguments: [String]) -> Result {
        let query = arguments.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Result(output: "Нужен вопрос: orakul найти что решили по тарифам", exitCode: 2)
        }
        // Ответ собирает RecallAnswer — тот же текст, что увидит пользователь
        // приложения. Двух разных «форматов ответа» у продукта быть не должно,
        // поэтому и разницу «архив пуст» против «не говорили» проводит он же,
        // а не эта команда: у приложения на первом запуске ровно тот же случай.
        // Архив читается ОДИН раз: и чтобы отличить пустой от непустого, и
        // чтобы узнать, что не открылось. Дважды — это дважды обойти папку.
        let archive = store.load()
        let answer = RecallAnswer.compose(query: query,
                                          hits: store.index().search(query),
                                          archiveIsEmpty: archive.sessions.isEmpty,
                                          unreadable: archive.skipped)
        // Ничего не нашлось — это результат, а не сбой: код возврата нулевой.
        return Result(output: answer, exitCode: 0)
    }

    private func list() -> Result {
        let archive = store.load()
        guard !archive.sessions.isEmpty else {
            return Result(output: "Архив пуст. Добавьте расшифровку: orakul добавить <файл>",
                          exitCode: 0)
        }
        var lines = archive.sessions.map { "\($0.date)  \($0.id)  \($0.title)" }
        if !archive.skipped.isEmpty {
            // Пропущенные файлы обязаны быть видны: молчание здесь означает
            // тихо потерянную встречу.
            lines.append("")
            lines.append("Не смог прочитать: \(archive.skipped.joined(separator: ", "))")
        }
        return Result(output: lines.joined(separator: "\n"), exitCode: 0)
    }

    private func delete(_ arguments: [String]) -> Result {
        guard let id = arguments.first else {
            return Result(output: "Нужен идентификатор: orakul удалить <идентификатор>",
                          exitCode: 2)
        }
        do {
            guard try store.delete(id: id) else {
                return Result(output: """
                Такой встречи нет: \(id)
                Посмотреть, что есть: orakul список
                """, exitCode: 1)
            }
        } catch {
            return Result(output: "Не смог удалить: \(error)", exitCode: 1)
        }
        return Result(output: "Удалено: \(id)", exitCode: 0)
    }
}

/// Мостик из асинхронного мира в синхронную командную строку.
private final class Semaphore<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?

    func set(_ newValue: Value) {
        value = newValue
        semaphore.signal()
    }

    func wait() -> Value {
        semaphore.wait()
        return value!
    }
}
