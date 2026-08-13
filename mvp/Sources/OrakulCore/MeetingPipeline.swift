import Foundation

/// Расшифровщик. Реализация зависит от платформы: на macOS одна, на Windows
/// другая — ядро о них не знает и знать не должно.
public protocol Transcriber: Sendable {
    /// Текст из 16 кГц моно. Бросает, если расшифровать не удалось.
    func transcribe(samples: [Float]) async throws -> String
}

/// Что происходит с созвоном от звука до строки в архиве.
///
/// Здесь сходятся все куски, и именно на таких стыках жили настоящие дефекты
/// английской версии: сервис читал общий архив вместо переданного, а все
/// юнит-тесты при этом оставались зелёными. Поэтому у конвейера нет ни одной
/// зависимости «изнутри» — расшифровщик, архив, часы и генератор
/// идентификаторов приходят снаружи и целиком подменяются в тесте.
public struct MeetingPipeline: Sendable {

    public enum PipelineError: Error, Equatable {
        /// Расшифровка пустая. Сохранять нечего, придумывать нечего.
        case nothingRecognised
    }

    let transcriber: any Transcriber
    let store: SessionStore
    /// День созвона. Приходит снаружи, иначе тест зависит от календаря.
    let today: @Sendable () -> String
    let makeIdentifier: @Sendable () -> String

    public init(transcriber: any Transcriber,
                store: SessionStore,
                today: @escaping @Sendable () -> String = MeetingPipeline.currentDay,
                makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transcriber = transcriber
        self.store = store
        self.today = today
        self.makeIdentifier = makeIdentifier
    }

    /// Сегодняшний день в формате архива.
    public static let currentDay: @Sendable () -> String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }

    /// Расшифровать созвон и положить его в архив.
    ///
    /// Порядок важен: словарь применяется ДО сохранения, потому что архив ищут,
    /// а не только показывают. Правка написания при каждом чтении означала бы,
    /// что поиск работает по одному тексту, а человек видит другой.
    @discardableResult
    public func record(samples: [Float], title: String) async throws -> RecallIndex.Session {
        let raw = try await transcriber.transcribe(samples: samples)
        let text = RussianLexicon.restore(TranscriptCleanup.strip(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PipelineError.nothingRecognised }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = RecallIndex.Session(
            id: makeIdentifier(),
            // Пустое название — это «Созвон», а не пустая строка в списке.
            title: trimmedTitle.isEmpty ? "Созвон" : trimmedTitle,
            date: today(),
            digest: text)

        try store.save(session)
        return session
    }
}
