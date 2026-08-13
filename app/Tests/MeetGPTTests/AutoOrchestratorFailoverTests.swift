import Foundation
import Testing
@testable import MeetGPT

private final class FailoverScriptGateway: LLMGateway, @unchecked Sendable {
    struct Step {
        let deltas: [String]
        let result: Result<String, Error>
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var models: [LLMModel] = []
    private var outputBudgets: [Int?] = []

    init(_ steps: [Step]) { self.steps = steps }

    var calledModels: [LLMModel] {
        lock.lock(); defer { lock.unlock() }
        return models
    }

    var calledOutputBudgets: [Int?] {
        lock.lock(); defer { lock.unlock() }
        return outputBudgets
    }

    private func takeStep(for model: LLMModel, maxOutputTokens: Int?) -> Step {
        lock.lock(); defer { lock.unlock() }
        models.append(model)
        outputBudgets.append(maxOutputTokens)
        return steps.removeFirst()
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let step = takeStep(for: model, maxOutputTokens: nil)
        step.deltas.forEach(onDelta)
        return try step.result.get()
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let step = takeStep(for: model, maxOutputTokens: maxOutputTokens)
        step.deltas.forEach(onDelta)
        return try step.result.get()
    }
}

private final class ConcurrentDeltaFailureGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    private func nextCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let call = nextCall()
        if call == 1 {
            DispatchQueue.concurrentPerform(iterations: 32) { _ in onDelta("x") }
            throw LLMError.http("OpenAI", 503, "stream failed")
        }
        onDelta("duplicate")
        return "duplicate"
    }
}

@Suite("Direct-provider orchestration failover", .serialized)
struct AutoOrchestratorFailoverTests {

    private let openAI = LLMModel(id: "test-openai", label: "OpenAI test",
                                  provider: .openAI, minTier: .free, supportsVision: true)
    private let google = LLMModel(id: "test-google", label: "Google test",
                                  provider: .google, minTier: .free, supportsVision: true)
    private let anthropic = LLMModel(id: "test-anthropic", label: "Anthropic test",
                                     provider: .anthropic, minTier: .free, supportsVision: true)

    private func orchestrator(_ gateway: FailoverScriptGateway,
                              selection: String,
                              direct: Bool = true,
                              fallbacks: [LLMModel]? = nil) -> AutoOrchestrator {
        let resolvedFallbacks = fallbacks ?? [google, anthropic]
        return AutoOrchestrator(
            inner: gateway,
            selectionProvider: { selection },
            tierProvider: { .premium },
            directClientMode: { direct },
            fallbackResolver: { _, _, _ in resolvedFallbacks })
    }

    private func errorSource(for provider: LLMProvider) -> String {
        provider == .google ? "Gemini" : provider.label
    }

    @Test("captured provider-pinned Auto selection beats a later live setting")
    func capturedProviderPinWins() async throws {
        // Маршрутизация смотрит на наличие ключа: без него пул пуст
        // и закреплённый провайдер теряется на запасном пути.
        try await withSeededProviderKeys {
            let gateway = FailoverScriptGateway([
                .init(deltas: ["ok"], result: .success("ok")),
            ])
            let captured = LLMModel(
                id: LLMCatalog.auto.id, label: LLMCatalog.auto.label,
                provider: .anthropic, minTier: .free, supportsVision: true,
                requestSelectionID: "auto:anthropic")
            let sut = AutoOrchestrator(
                inner: gateway,
                selectionProvider: { "auto:openAI" },
                tierProvider: { .ultra },
                directClientMode: { false },
                fallbackResolver: { _, _, _ in [] })

            _ = try await sut.streamChat(
                system: "s", user: "short", images: [], model: captured,
                onDelta: { _ in })

            #expect(gateway.calledModels.count == 1)
            #expect(gateway.calledModels.first?.provider == .anthropic)
        }
    }

    @Test("a selected provider's HTTP 402 falls back before output without duplicate deltas")
    func selectedProviderFundingFallback() async throws {
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("OpenAI", 402, #"{"error":"not enough funds"}"#))),
            .init(deltas: ["funded ", "answer"], result: .success("funded answer")),
        ])
        let sut = orchestrator(gateway, selection: openAI.id)
        var deltas: [String] = []

        let answer = try await sut.streamChat(
            system: "s", user: "u", images: [], model: openAI,
            maxOutputTokens: 321, onDelta: { deltas.append($0) })

        #expect(answer == "funded answer")
        #expect(deltas == ["funded ", "answer"])
        #expect(gateway.calledModels.map(\.provider) == [.openAI, .google])
        #expect(gateway.calledOutputBudgets == [321, 321])
    }

    @Test("Auto recovers from a funding 429 on a different configured vendor")
    func autoFundingFallback() async throws {
        let routed = AutoOrchestrator.route(.light, tier: .premium, hasImages: false)
        let routedCost = CreditCostEstimate.credits(
            model: routed.id, inputTokens: 100)
        // Drawn from the pool `route` ACTUALLY used — configured providers only.
        // Reading LLMCatalog.available(for:) instead ignores configuration, and
        // since provider configuration is global state that other suites mutate
        // in parallel, the two disagreed intermittently and this #require failed
        // roughly one run in twenty.
        let configuredPool = LLMCatalog.available(for: .premium)
            .filter { $0.provider.isConfigured }
        guard let budgetSafeFallback = configuredPool.first(where: {
            $0.provider != routed.provider
                && CreditCostEstimate.credits(model: $0.id, inputTokens: 100) <= routedCost
        }) else {
            // Only one provider configured in this environment: there is no
            // second vendor to fail over to, so there is nothing to assert.
            return
        }
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http(errorSource(for: routed.provider), 429,
                              #"{"code":"insufficient_quota"}"#))),
            .init(deltas: ["ok"], result: .success("ok")),
        ])
        // The fallback is a real catalog model at or below the routed model's
        // tariff; a stronger alternate would now be (correctly) refused.
        let sut = orchestrator(gateway, selection: LLMCatalog.autoID,
                               fallbacks: [budgetSafeFallback])
        var deltas: [String] = []

        let answer = try await sut.streamChat(
            system: "s", user: "short", images: [], model: LLMCatalog.auto,
            onDelta: { deltas.append($0) })

        #expect(answer == "ok")
        #expect(deltas == ["ok"])
        #expect(gateway.calledModels.count == 2)
        #expect(gateway.calledModels[0].provider != gateway.calledModels[1].provider)
    }

    @Test("pre-output timeout and 5xx failures can use another vendor")
    func transientFallback() async throws {
        func assertFallback(_ error: Error) async throws {
            let gateway = FailoverScriptGateway([
                .init(deltas: [], result: .failure(error)),
                .init(deltas: ["recovered"], result: .success("recovered")),
            ])
            let sut = orchestrator(gateway, selection: openAI.id)

            let answer = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })

            #expect(answer == "recovered")
            #expect(gateway.calledModels.map(\.provider) == [.openAI, .google])
        }

        try await assertFallback(LLMError.http("OpenAI", 503, "upstream unavailable"))
        try await assertFallback(URLError(.timedOut))
    }

    @Test("no vendor is retried after the first non-empty output delta")
    func noFallbackAfterOutput() async {
        let original = LLMError.http(
            "OpenAI", 503, "stream broke account=customer-secret sk-proj-tail")
        let gateway = FailoverScriptGateway([
            .init(deltas: ["partial"], result: .failure(original)),
            .init(deltas: ["duplicate"], result: .success("duplicate")),
        ])
        let sut = orchestrator(gateway, selection: openAI.id)
        var deltas: [String] = []

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI,
                onDelta: { deltas.append($0) })
            Issue.record("expected the interrupted provider error")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            guard error.outputStarted,
                  error.attempts == [.init(provider: .openAI, category: .unavailable)] else {
                Issue.record("unexpected error: \(type(of: error))")
                return
            }
            #expect(!error.localizedDescription.contains("customer-secret"))
            #expect(!error.localizedDescription.contains("sk-proj-tail"))
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }

        #expect(deltas == ["partial"])
        #expect(gateway.calledModels.map(\.provider) == [.openAI])
    }

    @Test("the output-started retry barrier is safe across concurrent callbacks")
    func concurrentOutputBarrier() async {
        let gateway = ConcurrentDeltaFailureGateway()
        let sut = AutoOrchestrator(
            inner: gateway,
            selectionProvider: { self.openAI.id },
            tierProvider: { .premium },
            directClientMode: { true },
            fallbackResolver: { _, _, _ in [self.google] })

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected stream failure")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            guard error.outputStarted,
                  error.attempts == [.init(provider: .openAI, category: .unavailable)] else {
                Issue.record("unexpected error: \(type(of: error))")
                return
            }
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(gateway.callCount == 1)
    }

    @Test("one configured provider never exposes a raw funding body")
    func safeSingleProviderFailure() async {
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("OpenAI", 402,
                              "billing account customer-secret sk-proj-tail"))),
        ])
        let sut = orchestrator(gateway, selection: openAI.id, fallbacks: [])

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected bounded provider failure")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            #expect(!error.outputStarted)
            #expect(error.attempts == [.init(provider: .openAI, category: .funding)])
            #expect(!error.localizedDescription.contains("customer-secret"))
            #expect(!error.localizedDescription.contains("sk-proj-tail"))
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("non-retryable direct-provider rejections are sanitized without fallback")
    func safeRequestRejection() async {
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("OpenAI", 400, "private request echo customer-secret"))),
            .init(deltas: ["must not run"], result: .success("must not run")),
        ])
        let sut = orchestrator(gateway, selection: openAI.id)

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected bounded rejection")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            #expect(!error.outputStarted)
            #expect(error.attempts == [.init(provider: .openAI, category: .rejected)])
            #expect(!error.localizedDescription.contains("customer-secret"))
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("direct fallback never silently upgrades beyond the selected model's tariff")
    func fallbackRespectsSelectedCostCeiling() async throws {
        let cheap = try #require(LLMCatalog.model(id: "deepseek-v4-pro"))
        let expensive = try #require(LLMCatalog.model(id: "gpt-5.5"))
        #expect(CreditCostEstimate.credits(model: cheap.id, inputTokens: 100) == 1)
        #expect(CreditCostEstimate.credits(model: expensive.id, inputTokens: 100) == 7)
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("DeepSeek", 402, "insufficient funds private-body"))),
            .init(deltas: ["must not run"], result: .success("must not run")),
        ])
        let sut = orchestrator(gateway, selection: cheap.id, fallbacks: [expensive])

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: cheap, onDelta: { _ in })
            Issue.record("expected bounded provider failure")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            #expect(error.attempts == [.init(provider: .deepSeek, category: .funding)])
            #expect(!error.localizedDescription.contains("private-body"))
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("8k output surcharge participates in fallback tariff eligibility")
    func fallbackRespectsOutputBudgetCost() async throws {
        let primary = try #require(LLMCatalog.model(id: "gpt-5.4-mini"))
        let expensiveAtEightK = try #require(LLMCatalog.model(id: "gemini-3.5-flash"))
        #expect(CreditCostEstimate.credits(
            model: primary.id, inputTokens: 100,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) == 2)
        #expect(CreditCostEstimate.credits(
            model: expensiveAtEightK.id, inputTokens: 100,
            maxOutputTokens: OutputTokenBudget.explicitUserFacing) == 3)
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("OpenAI", 402, "insufficient funds"))),
            .init(deltas: ["must not run"], result: .success("must not run")),
        ])
        let sut = orchestrator(
            gateway, selection: primary.id, fallbacks: [expensiveAtEightK])

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: primary,
                maxOutputTokens: OutputTokenBudget.explicitUserFacing) { _ in }
            Issue.record("expected the over-tariff fallback to be refused")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            #expect(error.attempts == [
                .init(provider: .openAI, category: .funding),
            ])
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("aggregate failure is bounded and never exposes upstream bodies")
    func safeAggregateFailure() async {
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(
                LLMError.http("OpenAI", 402, "secret-account-id primary-body"))),
            .init(deltas: [], result: .failure(
                LLMError.http("Gemini", 503, "private-google-body"))),
            .init(deltas: [], result: .failure(
                LLMError.http("Anthropic", 401, "sk-ant-secret"))),
        ])
        let sut = orchestrator(gateway, selection: openAI.id)

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected aggregate failure")
        } catch let error as AutoOrchestrator.ProviderFailoverError {
            let message = error.localizedDescription
            #expect(error.attempts.count == 3)
            #expect(!error.outputStarted)
            #expect(message.contains("OpenAI (funding)"))
            #expect(message.contains("Google (unavailable)"))
            #expect(message.contains("Anthropic (authentication)"))
            #expect(!message.contains("secret-account-id"))
            #expect(!message.contains("private-google-body"))
            #expect(!message.contains("sk-ant-secret"))
        } catch {
            Issue.record("unexpected error: \(type(of: error))")
        }
    }

    @Test("Backend session 401 and Cruxwing credit-cap 429 are preserved",
          arguments: [401, 429])
    func backendErrorsDoNotFailOver(status: Int) async {
        let body = status == 429
            ? "You need 2 compute credits, but only 0 remain this period."
            : "session expired"
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(LLMError.http("Backend", status, body))),
            .init(deltas: ["must not run"], result: .success("must not run")),
        ])
        let sut = orchestrator(gateway, selection: openAI.id)

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected backend error")
        } catch {
            guard case LLMError.http("Backend", let actualStatus, let actualBody) = error else {
                Issue.record("backend error was replaced")
                return
            }
            #expect(actualStatus == status)
            #expect(actualBody == body)
            if status == 429 {
                #expect(CreditExhaustion.quotaMessage(from: error) == body)
            }
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("managed mode never converts a provider-shaped failure into client failover")
    func managedModeDoesNotFailOver() async {
        let gateway = FailoverScriptGateway([
            .init(deltas: [], result: .failure(LLMError.http("OpenAI", 402, "funds"))),
            .init(deltas: ["must not run"], result: .success("must not run")),
        ])
        let sut = orchestrator(gateway, selection: openAI.id, direct: false)

        do {
            _ = try await sut.streamChat(
                system: "s", user: "u", images: [], model: openAI, onDelta: { _ in })
            Issue.record("expected original error")
        } catch {
            guard case LLMError.http("OpenAI", 402, _) = error else {
                Issue.record("original error was replaced")
                return
            }
        }
        #expect(gateway.calledModels.count == 1)
    }

    @Test("classification distinguishes provider funds from Cruxwing credits")
    func classification() {
        #expect(AutoOrchestrator.failoverCategory(
            for: LLMError.http("OpenAI", 402, ""), provider: .openAI) == .funding)
        #expect(AutoOrchestrator.failoverCategory(
            for: LLMError.http("OpenAI", 429, "insufficient_quota"),
            provider: .openAI) == .funding)
        #expect(AutoOrchestrator.failoverCategory(
            for: LLMError.http("OpenAI", 429, "requests per minute"),
            provider: .openAI) == .rateLimited)
        #expect(AutoOrchestrator.failoverCategory(
            for: LLMError.http("Backend", 429, "compute credits"),
            provider: .openAI) == nil)
        #expect(AutoOrchestrator.failoverCategory(
            for: LLMError.http("Orchestrate", 401, "sign in"),
            provider: .openAI) == nil)
        #expect(AutoOrchestrator.failoverCategory(
            for: URLError(.cancelled), provider: .openAI) == nil)
    }
}
