import Foundation

/// Архив созвонов на диске.
///
/// Три решения, каждое из которых кому-то уже стоило данных:
///
/// 1. **Один файл на встречу.** Общий индекс удобнее ровно до первой
///    повреждённой записи: тогда теряется весь архив, а не одна встреча.
/// 2. **Атомарная запись.** Сначала во временный файл, потом переименование.
///    Приложение, убитое посреди записи, оставляет целой старую версию, а не
///    половину новой.
/// 3. **Битый файл не останавливает загрузку.** Он пропускается и попадает в
///    `skipped`, потому что «архив не открылся» — худший возможный ответ
///    человеку, у которого там год работы.
///
/// Формат — читаемый человеком JSON: это его записи, и он должен иметь
/// возможность посмотреть их без нашего приложения.
public struct SessionStore: Sendable {

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public enum StoreError: Error, Equatable {
        case identifierUnusableAsFilename(String)
    }

    /// Результат загрузки: что прочиталось и что не смогло.
    public struct Archive: Sendable {
        public let sessions: [RecallIndex.Session]
        /// Имена файлов, которые не разобрались. Пустой список — норма;
        /// непустой обязан быть виден, а не проглочен.
        public let skipped: [String]
    }

    // MARK: - Запись

    /// Сохраняет встречу. Идентификатор становится именем файла, поэтому он
    /// проверяется: путь с «..» или косой чертой — это запись мимо архива.
    public func save(_ session: RecallIndex.Session) throws {
        guard isUsableAsFilename(session.id) else {
            throw StoreError.identifierUnusableAsFilename(session.id)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(session)

        // Временный файл рядом, а не в /tmp: переименование обязано остаться в
        // пределах одной файловой системы, иначе это копирование, и атомарность
        // теряется ровно там, где она нужна.
        let destination = url(for: session.id)
        let temporary = root.appendingPathComponent(".\(session.id).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    public func delete(id: String) throws {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Чтение

    /// Весь архив, свежие встречи первыми.
    public func load() -> Archive {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else {
            return Archive(sessions: [], skipped: [])
        }

        var sessions: [RecallIndex.Session] = []
        var skipped: [String] = []
        let decoder = JSONDecoder()

        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(RecallIndex.Session.self, from: data) else {
                skipped.append(name)
                continue
            }
            sessions.append(session)
        }

        // По убыванию даты; при равных датах — по идентификатору, чтобы порядок
        // не зависел от того, в каком виде файловая система вернула имена.
        sessions.sort { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
        return Archive(sessions: sessions, skipped: skipped)
    }

    /// Индекс поиска по всему архиву.
    public func index() -> RecallIndex {
        RecallIndex(sessions: load().sessions)
    }

    // MARK: - Внутреннее

    func url(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    /// Идентификатор, безопасный как имя файла.
    func isUsableAsFilename(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix(".") else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\:\0")
        return id.rangeOfCharacter(from: forbidden) == nil
    }
}
