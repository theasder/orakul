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
    }

    let store: SessionStore
    let today: @Sendable () -> String
    let makeIdentifier: @Sendable () -> String
    let readFile: @Sendable (String) -> String?

    public init(store: SessionStore,
                today: @escaping @Sendable () -> String = MeetingPipeline.currentDay,
                makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString },
                readFile: @escaping @Sendable (String) -> String? = {
                    try? String(contentsOfFile: $0, encoding: .utf8)
                }) {
        self.store = store
        self.today = today
        self.makeIdentifier = makeIdentifier
        self.readFile = readFile
    }

    public static let usage = """
    orakul — поиск по своим созвонам, на русском и без сети

      orakul добавить <файл> [название]   расшифровка из файла в архив
      orakul найти <вопрос>               что решили по этому поводу
      orakul список                       что вообще есть в архиве
      orakul удалить <идентификатор>      убрать одну встречу

    Архив — обычные JSON-файлы: их можно читать и без нас.
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

        let text = RussianLexicon.restore(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Result(output: "Файл пустой — сохранять нечего.", exitCode: 1)
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

    private func search(_ arguments: [String]) -> Result {
        let query = arguments.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Result(output: "Нужен вопрос: orakul найти что решили по тарифам", exitCode: 2)
        }
        // Ответ собирает RecallAnswer — тот же текст, что увидит пользователь
        // приложения. Двух разных «форматов ответа» у продукта быть не должно.
        let answer = RecallAnswer.compose(query: query, hits: store.index().search(query))
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
            try store.delete(id: id)
        } catch {
            return Result(output: "Не смог удалить: \(error)", exitCode: 1)
        }
        return Result(output: "Удалено: \(id)", exitCode: 0)
    }
}
