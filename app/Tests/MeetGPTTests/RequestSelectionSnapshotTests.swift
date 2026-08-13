import Foundation
import Testing
@testable import MeetGPT

private final class RequestSelectionSpyGateway: LLMGateway, @unchecked Sendable {
    struct Call {
        let model: LLMModel
        let maxOutputTokens: Int?
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(
            system: system, user: user, images: images, model: model,
            maxOutputTokens: nil, onDelta: onDelta)
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        lock.withLock {
            recordedCalls.append(Call(model: model, maxOutputTokens: maxOutputTokens))
        }
        onDelta("complete")
        return "complete"
    }
}

@Suite("Immutable request-selection snapshots", .serialized)
struct RequestSelectionSnapshotTests {

    private func orchestrator(
        gateway: RequestSelectionSpyGateway,
        liveSelection: @escaping () -> String
    ) -> AutoOrchestrator {
        AutoOrchestrator(
            inner: gateway,
            selectionProvider: liveSelection,
            tierProvider: { .ultra },
            directClientMode: { false },
            fallbackResolver: { _, _, _ in [] })
    }

    private var capturedAnthropicAuto: LLMModel {
        LLMModel(
            id: LLMCatalog.auto.id,
            label: LLMCatalog.auto.label,
            provider: .anthropic,
            minTier: .free,
            supportsVision: true,
            requestSelectionID: "auto:\(LLMProvider.anthropic.rawValue)")
    }

    @Test("provider-pinned Auto keeps its vendor snapshot and full visible-answer budget")
    func providerPinnedAutoPreservesSelectionAndBudget() async throws {
        // Маршрутизация смотрит на наличие ключа: без него пул пуст
        // и закреплённый провайдер теряется на запасном пути.
        try await withSeededProviderKeys {
            let gateway = RequestSelectionSpyGateway()
            let sut = orchestrator(gateway: gateway) {
                "auto:\(LLMProvider.openAI.rawValue)"
            }

            _ = try await sut.streamChat(
                system: "system",
                user: "Give a complete answer.",
                images: [],
                model: capturedAnthropicAuto,
                maxOutputTokens: OutputTokenBudget.explicitUserFacing,
                onDelta: { _ in })

            let call = try #require(gateway.calls.first)
            #expect(call.model.provider == .anthropic)
            #expect(call.maxOutputTokens == OutputTokenBudget.explicitUserFacing)
        }
    }

    @Test("fast-audit snapshot cannot fall through to a live Auto selection")
    func fastAuditIsConcreteAcrossOrchestrator() async throws {
        let gateway = RequestSelectionSpyGateway()
        let audit = LLMCatalog.fastAudit(
            for: capturedAnthropicAuto, managed: true)
        let sut = orchestrator(gateway: gateway) {
            "auto:\(LLMProvider.anthropic.rawValue)"
        }

        #expect(audit.requestSelectionID == audit.id)
        _ = try await sut.streamChat(
            system: "audit",
            user: "Check the draft mechanically.",
            images: [],
            model: audit,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing,
            onDelta: { _ in })

        let call = try #require(gateway.calls.first)
        #expect(call.model.id == audit.id)
        #expect(call.model.provider == audit.provider)
        #expect(call.model.requestSelectionID == audit.id)
    }

    @Test("background work is self-pinned and cannot inherit provider Auto")
    func backgroundIsConcreteAcrossOrchestrator() async throws {
        let gateway = RequestSelectionSpyGateway()
        let background = LLMCatalog.background(
            for: capturedAnthropicAuto, managed: true)
        let sut = orchestrator(gateway: gateway) {
            "auto:\(LLMProvider.anthropic.rawValue)"
        }

        #expect(background.requestSelectionID == background.id)
        _ = try await sut.streamChat(
            system: "background",
            user: "Run a cheap automatic watch.",
            images: [],
            model: background,
            onDelta: { _ in })

        let call = try #require(gateway.calls.first)
        #expect(call.model.id == background.id)
        #expect(call.model.provider == background.provider)
        #expect(call.model.requestSelectionID == background.id)
        #expect(call.maxOutputTokens == nil)
    }
}
