import Foundation
import Testing
@testable import MeetGPT

/// Вопрос не должен морозить окно.
///
/// `AppState` — `@MainActor`, и кросс-встречный поиск стоял в `run(prompt:)`
/// синхронно: каждый вопрос «что мы решили…» читал с диска ВСЕ сохранённые
/// звонки и считал по ним эмбеддинги, пока интерфейс стоял. Собственный замер
/// приложения даёт на это 2.26 с при 250 звонках — столько окно и не отвечало,
/// ровно в тот момент, когда человек только что задал вопрос на звонке.
///
/// Проверяется синхронная часть: сколько времени `ask` держит главный актор,
/// прежде чем вернуть управление. Сам ответ приходит потом и здесь не ждётся.
@MainActor
@Suite("Вопрос не морозит окно")
struct AskDoesNotBlockTests {

    private func populatedStore(sessions: Int) throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-block-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        for index in 0..<sessions {
            let started = Date().addingTimeInterval(-Double(index) * 86_400)
            let entries = (0..<40).map { line in
                TranscriptEntry(id: UUID(), source: .system,
                                text: "Строка \(line) обсуждения про тарифы и что это значит для квартала.",
                                timestamp: started, speaker: "Спикер\(line % 4)")
            }
            try store.save(SavedSession(
                id: UUID(), title: "Синк \(index)", startedAt: started, savedAt: started,
                goal: "", entries: entries, aiResponse: "",
                digest: "Решили двигаться дальше по тарифам.\n\nОткрытый вопрос про бюджет."))
        }
        return store
    }

    @Test("синхронная часть вопроса не ждёт чтения всего архива")
    func askReturnsWithoutReadingTheArchive() throws {
        let store = try populatedStore(sessions: 250)
        let state = AppState(llm: MockLLMGateway(response: "ответ"),
                             credentialStore: InMemoryKeychain(),
                             sessionStore: store)

        // Во время звонка уточняющие вопросы отключены, и `ask` идёт прямо в
        // `run` — тот самый путь, где заморозка и была заметна. Без этого
        // вопрос уходит в фоновую оценку уточнений, и замер меряет пустоту:
        // первая версия этой проверки так и показывала 0.00 с в обоих случаях.
        state.applyTestWorkspace(recording: true)

        let began = Date()
        state.ask("что мы решили по тарифам")
        let held = Date().timeIntervalSince(began)
        state.aiTask?.cancel()

        // Порог грубый нарочно: ловится не «на 20% медленнее», а возврат
        // синхронного чтения архива — до починки эта строка стоила секунды.
        // Замерено на 250 звонках: с починкой 0.01 с, без неё 0.61 с. Порог
        // между ними и с запасом от шума — ловится возврат синхронного чтения,
        // а не пара лишних миллисекунд.
        let report = "вопрос держал главный актор " + String(format: "%.2f", held)
            + " с — архив снова читается синхронно"
        #expect(held < 0.25, "\(report)")
    }

    @Test("поиск по прошлым звонкам считается вне главного актора")
    func recallIsComputedOffTheMainActor() throws {
        // Структурно: `Task { }` внутри @MainActor-контекста наследует его
        // изоляцию, поэтому оторванная задача здесь не украшение, а условие.
        let source = try String(contentsOfFile: Self.appStatePath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let call = try #require(code.range(of: "DecisionRecallContext.block(for: prompt"),
                                "кросс-встречный поиск исчез из пути вопроса")
        let before = String(code[..<call.lowerBound].suffix(220))
        #expect(before.contains("Task.detached"),
                "поиск снова считается на главном акторе")
    }

    static let appStatePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MeetGPT/AppState.swift").path
}
