import Foundation
import Testing
@testable import MeetGPT

private final class UserFacingBudgetGateway: LLMGateway, @unchecked Sendable {
    struct Call {
        let system: String
        let modelID: String
        let maxOutputTokens: Int?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let response: (String, String, LLMModel) -> String

    init(response: @escaping (String, String, LLMModel) -> String) {
        self.response = response
    }

    convenience init(response: String) {
        self.init { _, _, _ in response }
    }

    var calls: [Call] { lock.withLock { recorded } }

    private func complete(system: String, user: String, model: LLMModel,
                          maxOutputTokens: Int?,
                          onDelta: @escaping (String) -> Void) -> String {
        lock.withLock {
            recorded.append(Call(system: system, modelID: model.id,
                                 maxOutputTokens: maxOutputTokens))
        }
        let text = response(system, user, model)
        onDelta(text)
        return text
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        complete(system: system, user: user, model: model,
                 maxOutputTokens: nil, onDelta: onDelta)
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        complete(system: system, user: user, model: model,
                 maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }
}

@MainActor
@Suite("Explicit user-facing output budgets")
struct UserFacingOutputBudgetTests {
    private let model = LLMModel(
        id: "gpt-5.4", label: "GPT-5.4", provider: .openAI,
        minTier: .free, supportsVision: true)

    private func settle(_ state: AppState) async {
        await state.aiTask?.value
        for _ in 0..<200 where state.aiStreaming {
            await Task.yield()
        }
    }

    @Test("ordinary visible answers use 8k while their follow-up epilogue stays small")
    func ordinaryAnswerAndFollowUp() async {
        let gateway = UserFacingBudgetGateway(response: "A complete visible answer.")
        let state = AppState(llm: gateway)
        state.transcript = [TranscriptEntry(source: .mic, text: "Context")]
        state.runPrompt(.custom(icon: "✨", title: "Test", prompt: "Answer fully"))
        await settle(state)

        for _ in 0..<2_000 where gateway.calls.count < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let calls = gateway.calls
        #expect(calls.first?.maxOutputTokens == OutputTokenBudget.explicitUserFacing)
        #expect(calls.dropFirst().contains { $0.maxOutputTokens == nil },
                "the silent follow-up generator must keep its default small budget")
    }

    @Test("a workflow audit keeps the full visible-answer ceiling")
    func refinedAnswer() async throws {
        let gateway = UserFacingBudgetGateway(response: "A grounded final answer.")
        let state = AppState(llm: gateway)
        state.transcript = [TranscriptEntry(
            source: .system, text: "We committed to ship the fix Friday.")]
        let prompt = try #require(QuickPrompts.all.first { $0.id == "commitments" })

        state.runPrompt(prompt)
        await settle(state)

        let visibleCalls = Array(gateway.calls.prefix(2))
        #expect(visibleCalls.count == 2)
        #expect(visibleCalls.allSatisfy {
            $0.maxOutputTokens == OutputTokenBudget.explicitUserFacing
        })
    }

    @Test("structured draft and targeted repair both reserve a complete artifact")
    func structuredButtons() async throws {
        let json = #"{"dacis":[],"items":[{"task":"Ship","owner":"[OWNER?]","due":"[DUE?]","doneCheck":"Given a build, when tests pass, then ship","dependency":null,"sourceRef":"00:00","tracked":false}],"slackSummary":"Ship after tests."}"#
        let draftGateway = UserFacingBudgetGateway(response: json)
        _ = try await StructuredButtonService.draft(
            kind: .tasks, transcript: "Ship after tests", context: "",
            extraGuidance: nil, gateway: draftGateway, model: model)
        #expect(draftGateway.calls.map(\.maxOutputTokens) == [
            OutputTokenBudget.explicitUserFacing,
        ])

        let artifact = TasksArtifact(
            dacis: nil,
            items: [.init(
                task: "Ship", owner: "Invented Owner", due: "[DUE?]",
                doneCheck: nil, dependency: nil, sourceRef: nil, tracked: false)],
            slackSummary: nil)
        let repairGateway = UserFacingBudgetGateway(response: json)
        let repaired = await StructuredButtonService.repair(
            kind: .tasks, artifact: .tasks(artifact),
            violations: [.init(field: "items[0].owner", message: "not grounded")],
            transcript: "Ship after tests", gateway: repairGateway, model: model)

        #expect(repaired != nil)
        #expect(repairGateway.calls.map(\.maxOutputTokens) == [
            OutputTokenBudget.explicitUserFacing,
        ])
    }

    @Test("council members stay small and only the chairman inherits 8k")
    func ensembleChairmanOnly() async throws {
        let gateway = UserFacingBudgetGateway { system, _, model in
            system.contains("chairman of a model council")
                ? "final synthesis"
                : "proposal from \(model.id)"
        }
        let members = [
            EnsembleGateway.Member(provider: .openAI, modelID: "member-openai"),
            EnsembleGateway.Member(provider: .anthropic, modelID: "member-anthropic"),
        ]
        let chairman = EnsembleGateway.Member(provider: .google, modelID: "chairman-google")
        let ensemble = EnsembleGateway(
            members: members, chairman: chairman, gateway: gateway)

        let answer = try await ensemble.streamChat(
            system: "system", user: "question", images: [], model: model,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) { _ in }

        #expect(answer == "final synthesis")
        let calls = gateway.calls
        let panel = calls.filter { $0.modelID.hasPrefix("member-") }
        let synthesis = calls.filter { $0.modelID == "chairman-google" }
        #expect(panel.count == 2)
        #expect(panel.allSatisfy { $0.maxOutputTokens == nil })
        #expect(synthesis.count == 1)
        #expect(synthesis.first?.maxOutputTokens == OutputTokenBudget.explicitUserFacing)
    }
}
