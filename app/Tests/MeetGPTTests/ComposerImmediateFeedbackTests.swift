import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// Holds the clarification request open so the assertion is made during the
/// exact interval that used to leave a cleared composer and no visible turn.
private final class DelayedClarificationGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var clarificationContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    var callCount: Int { lock.withLock { calls } }
    var clarificationIsWaiting: Bool {
        lock.withLock { clarificationContinuation != nil }
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 {
            await withCheckedContinuation { continuation in
                let releaseNow = lock.withLock {
                    if releaseRequested { return true }
                    clarificationContinuation = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
            return #"{"needed":false}"#
        }

        let answer = "The launch plan is ready."
        onDelta(answer)
        return answer
    }

    func releaseClarification() {
        let continuation = lock.withLock {
            releaseRequested = true
            let value = clarificationContinuation
            clarificationContinuation = nil
            return value
        }
        continuation?.resume()
    }
}

/// First request produces a real clarification card; the replacement request
/// needs no clarification and receives a normal answer. This models the exact
/// rapid-input sequence that previously left the first card actionable over the
/// second answer.
private final class SupersededClarificationGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var assessmentCount = 0

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        if system.contains("You decide whether a request to a meeting co-pilot") {
            let sequence = lock.withLock {
                assessmentCount += 1
                return assessmentCount
            }
            if sequence == 1 {
                return #"{"needed":true,"questions":[{"header":"Target","question":"Which launch should this cover?","multiSelect":false,"options":[{"label":"Mobile","detail":"iOS and Android"},{"label":"Web","detail":"Browser release"}]}]}"#
            }
            return #"{"needed":false}"#
        }

        let answer = "The replacement request owns this answer."
        onDelta(answer)
        return answer
    }
}

@MainActor
@Suite("Composer immediate feedback", .serialized)
struct ComposerImmediateFeedbackTests {
    @Test("COMPOSER-PROMPT-ECHO-IMMEDIATE: Send publishes the turn before clarification finishes")
    func promptEchoesBeforeAsyncClarification() async throws {
        let previousClarificationSetting = Config.clarifyingQuestionsEnabled
        Config.clarifyingQuestionsEnabled = true
        defer { Config.clarifyingQuestionsEnabled = previousClarificationSetting }

        let gateway = DelayedClarificationGateway()
        let state = AppState(llm: gateway)
        let now = Date()
        state.restoreSession(SavedSession(
            id: UUID(), title: "Launch", startedAt: now, savedAt: now,
            goal: "", entries: [], aiResponse: "The prior answer remains readable.",
            aiResponsePrompt: "What was the prior decision?", digest: ""
        ))

        let prompt = "Explain the implications for the launch"
        state.ask(prompt)

        // No yield: these are the synchronous guarantees required by Send.
        #expect(state.submittedPromptPreview == prompt)
        #expect(state.aiResponsePrompt == "What was the prior decision?")
        #expect(state.clarifying)
        let inspected = try ResponseView().environmentObject(state).inspect()
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityLabel: "Вы спросили: \(prompt)")
        }
        #expect(throws: Never.self) {
            try inspected.find(text: "The prior answer remains readable.")
        }
        #expect(throws: Never.self) {
            try inspected.find(text: "Уточняю вопрос…")
        }

        for _ in 0..<500 {
            if gateway.clarificationIsWaiting { break }
            await Task.yield()
        }
        #expect(gateway.clarificationIsWaiting)
        gateway.releaseClarification()

        for _ in 0..<1_000 {
            if state.aiResponsePrompt == prompt && !state.aiStreaming { break }
            await Task.yield()
        }
        await state.aiTask?.value
        #expect(state.submittedPromptPreview == nil)
        #expect(state.aiResponsePrompt == prompt)
        #expect(state.aiResponse.contains("launch plan is ready"))
    }

    @Test("COMPOSER-PROMPT-SUPERSEDES-CLARIFICATION: a later Send removes the stale card before answering")
    func laterPromptSupersedesClarificationCard() async throws {
        let previousClarificationSetting = Config.clarifyingQuestionsEnabled
        Config.clarifyingQuestionsEnabled = true
        defer { Config.clarifyingQuestionsEnabled = previousClarificationSetting }

        let state = AppState(llm: SupersededClarificationGateway())
        let firstPrompt = "Draft a launch plan"
        state.ask(firstPrompt)
        for _ in 0..<1_000 where state.pendingClarification == nil {
            await Task.yield()
        }
        let stale = try #require(state.pendingClarification)
        #expect(stale.prompt == firstPrompt)

        let replacement = "List the launch blockers instead"
        state.ask(replacement)

        // No yield: accepting Send atomically replaces the old turn's card and
        // publishes the new turn. An attempted late click is now a no-op.
        #expect(state.pendingClarification == nil)
        #expect(state.submittedPromptPreview == replacement)
        state.resolveClarification([
            ClarificationAnswer(
                questionID: stale.questions[0].id,
                selected: [stale.questions[0].options[0].id])
        ])
        #expect(state.pendingClarification == nil)
        #expect(state.submittedPromptPreview == replacement)
        let inspected = try ResponseView().environmentObject(state).inspect()
        #expect(throws: Never.self) {
            try inspected.find(viewWithAccessibilityLabel: "Вы спросили: \(replacement)")
        }

        for _ in 0..<2_000 {
            if state.aiResponsePrompt == replacement && !state.aiStreaming { break }
            await Task.yield()
        }
        await state.aiTask?.value
        #expect(state.aiResponsePrompt == replacement)
        #expect(state.aiResponse.contains("replacement request owns"))
        #expect(!state.aiResponsePrompt.contains(firstPrompt))
    }

    @Test("COMPOSER-QUICK-PROMPT-SUPERSEDES-CLARIFICATION: a button invalidates an older composer card")
    func quickPromptSupersedesClarificationCard() async throws {
        let state = AppState(llm: MockLLMGateway(response: "Button answer"))
        let question = ClarifyingQuestion(
            question: "Which launch should this cover?",
            header: "Target",
            options: [
                .init(label: "Mobile", detail: nil),
                .init(label: "Web", detail: nil),
            ])
        state.pendingClarification = PendingClarification(
            prompt: "Draft a launch plan", images: [], questions: [question])
        let button = QuickPrompt.custom(
            id: "replacement-button", icon: "➡️", title: "Find blockers",
            prompt: "List the launch blockers.")

        state.runPrompt(button)

        #expect(state.pendingClarification == nil)
        #expect(!state.clarifying)
        #expect(state.aiResponsePrompt == button.prompt)
        await state.aiTask?.value
    }

    @Test("COMPOSER-ATTACHMENT-IMMEDIATE: selected filenames exist before async import")
    func attachmentStagesSynchronouslyAndBecomesReady() throws {
        var feedback = ComposerAttachmentFeedback()
        let url = URL(fileURLWithPath: "/tmp/customer-roadmap.pdf")

        let ids = feedback.stage(urls: [url], kind: .file)

        #expect(ids.count == 1)
        #expect(feedback.items.count == 1)
        #expect(feedback.items[0].name == "customer-roadmap.pdf")
        #expect(feedback.items[0].phase == .importing)
        #expect(feedback.hasImportingItems)
        let importingChip = ComposerAttachmentStatusChip(
            item: feedback.items[0], onRemove: {})
        #expect(throws: Never.self) {
            try importingChip.inspect().find(text: "customer-roadmap.pdf")
        }
        #expect(throws: Never.self) {
            try importingChip.inspect().find(text: "Загружаю…")
        }

        let context = ImportedContextFile(
            name: "customer-roadmap.pdf", text: "Launch milestones")
        feedback.finishContext(ids: ids, imported: [context])

        #expect(feedback.items[0].phase == .ready(contextFileID: context.id))
        #expect(!feedback.hasImportingItems)
        let readyChip = ComposerAttachmentStatusChip(
            item: feedback.items[0], onRemove: {})
        #expect(throws: Never.self) { try readyChip.inspect().find(text: "Готово") }

        feedback.reconcile(contextFileIDs: [])
        #expect(feedback.items.isEmpty)
    }

    @Test("COMPOSER-FOLDER-IMMEDIATE: a folder is cancellable while indexing and persistent when ready")
    func folderStagesImmediatelyAndUsesPersistentChip() throws {
        var feedback = ComposerAttachmentFeedback()
        let url = URL(fileURLWithPath: "/redacted/customer-project", isDirectory: true)

        let ids = feedback.stage(urls: [url], kind: .folder)

        #expect(ids.count == 1)
        #expect(feedback.items[0].kind == .folder)
        #expect(feedback.items[0].phase == .importing)
        let indexing = ComposerAttachmentStatusChip(
            item: feedback.items[0], onRemove: {})
        #expect(throws: Never.self) { try indexing.inspect().find(text: "Строю индекс…") }
        #expect(throws: Never.self) {
            try indexing.inspect().find(viewWithAccessibilityLabel: "Отменить customer-project")
        }

        let folder = ContextFolder(
            name: "customer-project", path: "/redacted/customer-project",
            bookmark: Data(), files: [
                ImportedContextFile(name: "README.md", text: "Roadmap")
            ])
        feedback.finishFolders(ids: ids, imported: [folder])
        // Success replaces the ephemeral progress item with AppState's standing
        // folder chip, so it survives Send and view reconstruction.
        #expect(feedback.items.isEmpty)

        let persistent = ComposerFolderChip(folder: folder, onRemove: {})
        #expect(throws: Never.self) { try persistent.inspect().find(text: "customer-project") }
        #expect(throws: Never.self) { try persistent.inspect().find(text: "1 indexed") }
        #expect(throws: Never.self) {
            try persistent.inspect().find(viewWithAccessibilityLabel: "Убрать папку customer-project")
        }
    }

    @Test("COMPOSER-FOLDER-ERROR: a failed folder remains visibly removable")
    func failedFolderIsVisible() throws {
        var feedback = ComposerAttachmentFeedback()
        let ids = feedback.stage(
            urls: [URL(fileURLWithPath: "/redacted/unreadable", isDirectory: true)],
            kind: .folder)

        feedback.finishFolders(ids: ids, imported: [])

        #expect(feedback.items.count == 1)
        #expect(feedback.items[0].phase == .failed)
        let chip = ComposerAttachmentStatusChip(item: feedback.items[0], onRemove: {})
        #expect(throws: Never.self) { try chip.inspect().find(text: "Импорт не удался") }
        #expect(throws: Never.self) {
            try chip.inspect().find(viewWithAccessibilityLabel: "Убрать unreadable")
        }
    }

    @Test("COMPOSER-ATTACHMENT-ERROR: partial image imports retain only failed feedback")
    func imageCompletionReplacesSuccessAndKeepsFailure() {
        var feedback = ComposerAttachmentFeedback()
        let urls = [
            URL(fileURLWithPath: "/tmp/diagram.png"),
            URL(fileURLWithPath: "/tmp/oversize.png"),
        ]
        let ids = feedback.stage(urls: urls, kind: .image)

        feedback.finishImages(
            ids: ids,
            imported: [Attachment(name: "diagram.png", imageData: Data([0x01]))])

        #expect(feedback.items.count == 1)
        #expect(feedback.items[0].name == "oversize.png")
        #expect(feedback.items[0].phase == .failed)
        #expect(!feedback.hasImportingItems)
    }
}
