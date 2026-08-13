import Foundation

/// A finished (or in-progress) meeting session persisted to disk — before this
/// existed, the entire product output (transcript, AI answers, digest) died on
/// quit (launch loop M3). One JSON file per session under Application Support.
struct SavedSession: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var startedAt: Date
    var savedAt: Date
    var goal: String
    /// Optional for recordings saved before tutorials/videos could be labeled.
    /// The explicit selection is persisted; automatic inference can be
    /// recomputed from the saved title when the session is reopened.
    var recordingContext: RecordingContextSelection? = nil
    var entries: [TranscriptEntry]
    /// Uniform engine for sessions recorded entirely on one backend. Optional
    /// for old files and mixed-engine calls; entries carry exact provenance.
    var transcriptionEngine: TranscriptionEngine? = nil
    var aiResponse: String
    /// Optional for backward compatibility with sessions saved before answer
    /// provenance and DOCX export were introduced.
    var aiResponsePrompt: String? = nil
    /// Cached LLM-created export title so reopening and re-exporting a session
    /// does not spend another model call.
    var aiResponseExportTitle: String? = nil
    /// Earlier turns of the assistant dialog, oldest first. OPTIONAL, like the
    /// fields above it: Swift's synthesized decoder ignores a property default
    /// for a non-optional type, so a plain `= []` would make every session
    /// saved before this field existed fail to decode.
    var aiHistory: [AIExchange]? = nil
    /// The context panel — imported documents and the free-text notes — as it
    /// stood for THIS meeting. Previously absent entirely, so opening another
    /// call from History left the previous meeting's documents in place and
    /// silently grounded the new one in them.
    ///
    /// Optional for the same reason as the fields above: a synthesized decoder
    /// ignores property defaults for non-optional types, so `= []` would make
    /// every already-saved session fail to load.
    var contextFiles: [ImportedContextFile]? = nil
    var contextNotes: String? = nil
    /// Blind-spot suggestions surfaced during THIS call. They were generated
    /// live and never written down, so every one was lost the moment the call
    /// ended — reopening a meeting from History showed none of the risks and
    /// questions the co-pilot had raised in it.
    ///
    /// Optional like the fields above: a synthesized decoder ignores property
    /// defaults for non-optional types, so `= []` would break every session
    /// already on disk.
    var suggestions: [Suggestion]? = nil
    var digest: String

    // MARK: - Workflow output that used to die with the call
    //
    // Blind spots were persisted; the rest of the co-pilot's output was not.
    // Fact-check verdicts, the two watch notes and the Efficiency Engine's
    // scored action items existed only as live state or as prose inside an
    // answer, so reopening a call from History showed none of them — and the
    // reflection eval, which can only judge what a session records, could not
    // measure the workflows most worth measuring.
    //
    // OPTIONAL for the same reason as every field above: a synthesized decoder
    // ignores property defaults for non-optional types, so `= []` here would
    // fail to decode every session already on disk and take the meeting with it.

    /// Fact-check verdicts for THIS call.
    var factClaims: [FactClaim]? = nil
    /// The rhetoric watch's last note.
    var rhetoricNote: String? = nil
    /// The facilitation watch's last note.
    var facilitationNote: String? = nil
    /// The Efficiency Engine follow-up produced when a decision was filed.
    var followUp: SavedFollowUp? = nil

    /// Sidebar label: the title when set, else the date.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startedAt)
    }
}

/// Disk store for sessions: one pretty-printed JSON per session, filename =
/// UUID. The root directory is injectable for tests; the shared instance lives
/// in Application Support (works sandboxed and unsandboxed).
struct SessionStore {
    let root: URL

    static let shared: SessionStore = {
        // Under test the shared store is redirected to a scratch directory.
        // Opening a call now SAVES the outgoing one, so any test that restores
        // two sessions writes — and with the real path that would deposit
        // fixture meetings into the user's actual history. Tests that assert on
        // persistence inject their own root; this only makes the default safe.
        if AppState.isUnderTest {
            return SessionStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("cruxwing-tests/Sessions", isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SessionStore(root: base.appendingPathComponent("MeetGPT/Sessions", isDirectory: true))
    }()

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    /// Write (or overwrite) a session. Errors are surfaced to the caller —
    /// losing a meeting silently is exactly what this store exists to prevent.
    func save(_ session: SavedSession) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: url(for: session.id), options: .atomic)
    }

    /// All sessions, newest first. Unreadable files are skipped, never fatal.
    func list() -> [SavedSession] { listWithUnreadable().sessions }

    /// Sessions plus the names of files that would not decode.
    ///
    /// Пропустить нечитаемый файл — правильно: один испорченный звонок не
    /// должен ронять весь архив. Но пропустить МОЛЧА — нет. Раньше здесь стоял
    /// `compactMap { try? decode }`, и имя такого файла не сохранялось никуда:
    /// приложение отвечало «в сохранённых звонках об этом не говорили» поверх
    /// архива, часть которого не открылась, и человек уходил уверенным, что не
    /// обсуждали.
    ///
    /// Случай не выдуманный: страница зовёт открывать архив руками — «обычные
    /// JSON-файлы, их можно читать и без нас», — а значит, испорченный файл
    /// появится. Командная строка про такой файл уже говорит.
    func listWithUnreadable() -> (sessions: [SavedSession], unreadable: [String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return ([], []) }

        var sessions: [SavedSession] = []
        var unreadable: [String] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(SavedSession.self, from: data) else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            sessions.append(session)
        }
        return (sessions.sorted { $0.startedAt > $1.startedAt }, unreadable.sorted())
    }

    /// Уже импортированный звонок с тем же началом и названием, если он есть.
    ///
    /// Импорт из Fireflies строит `SavedSession(id: UUID(), …)` — каждый раз
    /// новый идентификатор, и внешнего идентификатора встречи в записи не
    /// хранится. Нажать «импортировать» второй раз, не поняв, сработало ли в
    /// первый, — обычное дело, и в архиве появлялась вторая копия.
    ///
    /// Копии не просто занимают место: ответ показывает не больше трёх звонков
    /// (`RecallAnswer.maximumMeetings`), поэтому дубли вытесняют из ответа
    /// РАЗНЫЕ звонки. Та же беда, что была у `orakul добавить`.
    ///
    /// Ключ — начало встречи и название. `startedAt` берётся из самой встречи,
    /// а не из момента импорта (см. `FirefliesPastCalls.session(for:)`), то
    /// есть при повторном импорте он тот же. Двух разных звонков с совпадающей
    /// секундой начала И названием не бывает.
    func alreadyImported(_ candidate: SavedSession) -> SavedSession? {
        list().first { $0.startedAt == candidate.startedAt && $0.title == candidate.title }
    }

    /// Сохранить импортированный звонок — или вернуть уже заведённый.
    ///
    /// Решение живёт здесь, а не в вызывающем: пока оно стояло в `AppState`,
    /// мутация, отключавшая проверку, не роняла ни один тест. Путь импорта
    /// требует сети и менеджера, тестом его не пройти, а проверка «в исходнике
    /// есть слово alreadyImported» не отличает «зовёт» от «зовёт и
    /// игнорирует». Здесь же это обычная функция, и повторный вызов проверяется
    /// напрямую — по тому, сколько файлов легло на диск.
    @discardableResult
    func saveImported(_ session: SavedSession) throws -> SavedSession {
        if let existing = alreadyImported(session) { return existing }
        try save(session)
        return session
    }

    func load(id: UUID) -> SavedSession? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? decoder.decode(SavedSession.self, from: data)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Remove every saved session (the History "clear all" action). Deletes the
    /// JSON files directly so even a corrupt/unlisted file is cleared.
    func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
