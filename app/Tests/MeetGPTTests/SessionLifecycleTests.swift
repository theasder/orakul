import Foundation
import Testing
@testable import MeetGPT

/// Session lifecycle: a new recording must start a clean meeting so History
/// doesn't fill with tracks that each re-contain every earlier un-cleared
/// meeting. `resetForNewRecording()` is what `startRecording()` runs once
/// capture has actually begun (the audio path itself needs hardware, so we
/// drive the reset directly).
@MainActor
@Suite("Session lifecycle")
struct SessionLifecycleTests {
    private func meetingState() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.transcript = [
            TranscriptEntry(source: .mic, text: "meeting one, first line"),
            TranscriptEntry(source: .system, text: "meeting one, second line")
        ]
        state.meetingTitle = "Meeting One"
        state.callGoal = "close the Q3 renewal"
        state.suggestions = [Suggestion(title: "old idea", detail: "d", kind: .advice)]
        return state
    }

    // MARK: - Повторный импорт

    private func importedSession(title: String, at started: Date) -> SavedSession {
        SavedSession(id: UUID(), title: title, startedAt: started, savedAt: Date(),
                     goal: "", entries: [], aiResponse: "",
                     digest: "Решили поднять тариф на пятнадцать процентов.")
    }

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    @Test("тот же звонок, импортированный дважды, узнаётся")
    func reimportIsRecognised() throws {
        // Импорт строит запись с новым UUID и не хранит внешнего
        // идентификатора встречи, поэтому по идентификатору дубль не поймать.
        // Нажать «импортировать» второй раз, не поняв, сработало ли, — обычное
        // дело. Копии не просто лишние: мест в ответе три, и дубли вытесняют
        // из него РАЗНЫЕ звонки.
        let store = try scratchStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let first = importedSession(title: "Планёрка по тарифам", at: started)
        try store.save(first)

        let again = importedSession(title: "Планёрка по тарифам", at: started)
        let found = try #require(store.alreadyImported(again),
                                 "повторный импорт не узнан")
        #expect(found.id == first.id, "нашлась не та запись")
    }

    @Test("другой звонок в то же время импортируется")
    func differentMeetingSameInstantStillImports() throws {
        // Граница: два разных звонка могут начаться в одну секунду —
        // параллельные встречи бывают. Название их различает.
        let store = try scratchStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        try store.save(importedSession(title: "Планёрка по тарифам", at: started))

        #expect(store.alreadyImported(importedSession(title: "Найм", at: started)) == nil,
                "разный звонок принят за копию")
    }

    @Test("тот же звонок в другое время — не копия")
    func sameTitleDifferentInstantIsNotADuplicate() throws {
        // И обратное: планёрку называют одинаково каждую неделю.
        let store = try scratchStore()
        try store.save(importedSession(title: "Планёрка",
                                       at: Date(timeIntervalSince1970: 1_760_000_000)))

        #expect(store.alreadyImported(importedSession(
            title: "Планёрка", at: Date(timeIntervalSince1970: 1_760_604_800))) == nil,
                "звонок другой недели принят за копию")
    }

    @Test("повторное сохранение импорта не кладёт второй файл")
    func saveImportedIsIdempotent() throws {
        // Проверка «в исходнике есть слово alreadyImported» не отличала
        // «зовёт» от «зовёт и игнорирует»: мутация `if false, let existing =
        // …` её проходила. Поэтому решение переехало в хранилище, и здесь
        // проверяется результат — сколько записей легло на диск.
        let store = try scratchStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        let first = try store.saveImported(importedSession(title: "Планёрка", at: started))
        let second = try store.saveImported(importedSession(title: "Планёрка", at: started))

        #expect(second.id == first.id, "второй импорт завёл новую запись")
        #expect(store.list().count == 1, "в архиве \(store.list().count) копий вместо одной")
    }

    @Test("импорт идёт через saveImported, а не мимо него")
    func importDoesNotBypassTheCheck() throws {
        // Что эта проверка ЛОВИТ: возврат к прямому `save` в пути импорта —
        // единственная реалистичная регрессия, и она видна по тексту.
        // Чего она НЕ ловит: «позвал и выбросил результат». Это отдельно не
        // страшно — результат тут же идёт в `restoreSession`, и потеря
        // сломала бы восстановление звонка на экране.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetGPT/AppState.swift"),
            encoding: .utf8)
        let call = try #require(source.range(of: "firefliesImportMeeting"),
                                "импорт из Fireflies исчез — проверка ослепла")
        let after = String(source[call.upperBound...].prefix(400))

        #expect(after.contains("saveImported"),
                "импорт сохраняет звонок мимо проверки на повтор")
        #expect(!after.contains("sessionStore.save("),
                "импорт снова зовёт save напрямую — дубли вернутся")
    }

    @Test("разные звонки сохраняются оба")
    func saveImportedKeepsDistinctCalls() throws {
        let store = try scratchStore()
        let started = Date(timeIntervalSince1970: 1_760_000_000)
        _ = try store.saveImported(importedSession(title: "Планёрка", at: started))
        _ = try store.saveImported(importedSession(title: "Найм", at: started))
        #expect(store.list().count == 2, "разный звонок потерялся")
    }

    @Test("a new recording does NOT inherit the prior meeting's transcript")
    func doesNotInheritTranscript() {
        let state = meetingState()
        let firstID = state.currentSessionID

        state.resetForNewRecording()

        #expect(state.transcript.isEmpty)          // the merge bug: prior lines are gone
        #expect(state.currentSessionID != firstID) // its own History file
        #expect(state.meetingTitle == "")
        #expect(state.callGoal == "")
        #expect(state.suggestions.isEmpty)
        #expect(state.followUpPrompts.isEmpty)
    }

    @Test("calendar metadata names the meeting without duplicating it as the visible goal")
    func appliesCalendarMeetingName() {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.callGoal = "Дизайн-синк"

        state.applyCalendarAgenda(CalendarAgenda(
            title: "Дизайн-синк",
            summary: "Review the new flow",
            attendeeCount: 3
        ))

        #expect(state.meetingTitle == "Дизайн-синк")
        #expect(state.callGoal.isEmpty)
        #expect(state.suggestedGoal != "Дизайн-синк")
        #expect(state.effectiveCallGoal == "Дизайн-синк")

        state.meetingTitle = "Название пользователя"
        state.applyCalendarAgenda(CalendarAgenda(
            title: "Calendar overwrite",
            summary: "",
            attendeeCount: 2
        ))
        #expect(state.meetingTitle == "Название пользователя")
    }

    @Test("a new recording drops prior research results but keeps reusable context")
    func dropsEphemeralResearchContext() {
        let state = meetingState()
        state.contextFiles = [
            ImportedContextFile(name: "Research · Notion", text: "Old meeting"),
            ImportedContextFile(name: "Customer brief.pdf", text: "Reusable context"),
        ]

        state.resetForNewRecording()

        #expect(state.contextFiles.map(\.name) == ["Customer brief.pdf"])
    }

    @Test("persistCurrentSession is a no-op for a workspace that was never recorded")
    func skipsUnrecordedScratch() {
        let state = AppState(llm: MockLLMGateway(response: ""))
        // A transcript with no recordingStartedAt = AI-only scratch, not a meeting.
        state.transcript = [TranscriptEntry(source: .mic, text: "scratch")]
        state.savedSessions = []

        state.persistCurrentSession()

        // Nothing was written back into the published list.
        #expect(state.savedSessions.isEmpty)
    }

    @Test("stopping keeps session provenance for History; clearing removes it")
    func stopRetainsStartUntilClear() async {
        let state = AppState(
            transcriber: MockTranscriptionService(),
            llm: MockLLMGateway(response: "")
        )
        let startedAt = Date()
        let session = SavedSession(
            id: UUID(), title: "", startedAt: startedAt, savedAt: startedAt,
            goal: "", entries: [], aiResponse: "", digest: ""
        )
        state.restoreSession(session)

        // Exercise the real stop path without hardware capture. An empty
        // transcript also keeps this test away from SessionStore.shared.
        state.status = .recording
        state.toggleRecording()
        await waitUntil { state.status == .idle }

        #expect(state.recordingStartedAt == startedAt)
        state.clearAll()
        #expect(state.recordingStartedAt == nil)
    }

    @Test("restoring History synchronously releases a running AI and Fact Check")
    func restoreCancelsAIState() {
        let state = meetingState()
        state.aiStreaming = true
        state.factChecking = true
        state.showFactCheck = true
        state.aiStage = "Verify factual claims"
        state.aiTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        let saved = SavedSession(
            id: UUID(), title: "Saved", startedAt: Date(), savedAt: Date(),
            goal: "Review", entries: [], aiResponse: "Prior answer",
            aiResponsePrompt: "What did we decide?",
            aiResponseExportTitle: "Prior Decision",
            digest: "")

        state.restoreSession(saved)

        #expect(!state.aiStreaming)
        #expect(!state.factChecking)
        #expect(!state.showFactCheck)
        #expect(state.aiTask == nil)
        #expect(state.workflowSteps.isEmpty)
        #expect(state.aiResponse == "Prior answer")
        #expect(state.aiResponsePrompt == "What did we decide?")
        #expect(state.aiResponseExportTitle == "Prior Decision")
    }

    @Test("Clear releases a canceled Fact Check so it can be run again")
    func clearCancelsFactCheckState() {
        let state = meetingState()
        state.aiStreaming = true
        state.factChecking = true
        state.showFactCheck = true
        state.aiStage = "Verify factual claims"
        state.aiTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }

        state.clearAll()

        #expect(!state.aiStreaming)
        #expect(!state.factChecking)
        #expect(!state.showFactCheck)
        #expect(state.aiTask == nil)
        #expect(state.workflowSteps.isEmpty)
        #expect(state.aiResponsePrompt.isEmpty)
        #expect(state.aiResponseExportTitle == nil)
    }
}
