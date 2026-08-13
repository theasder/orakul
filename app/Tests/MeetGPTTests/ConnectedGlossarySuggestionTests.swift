import AppKit
import Foundation
import Testing
@testable import MeetGPT

private final class ConnectedGlossaryGateway: LLMGateway, @unchecked Sendable {
    struct Call: Equatable {
        let system: String
        let user: String
        let model: String
        let maxOutputTokens: Int?
    }
    enum Failure: Error { case unavailable }

    private let lock = NSLock()
    private var storage: [Call] = []
    let response: String
    let fails: Bool

    init(response: String, fails: Bool = false) {
        self.response = response
        self.fails = fails
    }

    var calls: [Call] { lock.withLock { storage } }

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
            storage.append(Call(
                system: system, user: user, model: model.id,
                maxOutputTokens: maxOutputTokens))
        }
        if fails { throw Failure.unavailable }
        onDelta(response)
        return response
    }
}

@MainActor
@Suite("Connected-app transcription glossary suggestions", .serialized)
struct ConnectedGlossarySuggestionTests {
    private let snippets = [
        GroundingSnippet(
            serverName: "Notion", toolName: "search",
            text: "Project Falcon uses Kubernetes, OpenTelemetry, RAG, and SLO-99.95."),
        GroundingSnippet(
            serverName: "Linear", toolName: "search",
            text: "Ada Lovelace owns Project Falcon and the VectorBridge API."),
    ]

    private func preserveConfig(_ body: () async throws -> Void) async rethrows {
        let glossary = Config.transcriptionGlossary
        let grounding = Config.connectedAppsGroundingEnabled
        let googleTokens = Config.googleTokens
        defer {
            Config.transcriptionGlossary = glossary
            Config.connectedAppsGroundingEnabled = grounding
            Config.googleTokens = googleTokens
        }
        try await body()
    }

    @Test("bounded prompt strips credentials and cannot contain a live transcript")
    func promptPrivacyAndBounds() throws {
        let secretTranscript = "CALL-TRANSCRIPT-SECRET-DO-NOT-SEND"
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"
        let unsafe = GroundingSnippet(
            serverName: "CRM", toolName: "search",
            text: """
            Project Falcon and Kubernetes.
            Authorization: Bearer abcdefghijklmnop
            api_key=sk-proj-abcdef1234567890
            JWT (jwt)
            owner@example.com https://internal.example.com/spec?token=secret
            client_secret: ultra-secret-value
            opaque A234567890123456789012345678901234567890123456789
            (String(repeating: "OpenTelemetry ", count: 1_000))
            """)
        let prepared = try #require(ConnectedGlossarySuggestionService.prepare(
            snippets: [unsafe, unsafe, unsafe, unsafe], existingGlossary: ""))

        #expect(prepared.sourceCount == 1, "duplicate connector names are one source")
        #expect(prepared.groundingChars <= ConnectedGlossarySuggestionService.maxGroundingChars)
        #expect(prepared.promptChars <= ConnectedGlossarySuggestionService.maxPromptChars)
        #expect(prepared.estimatedInputTokens < TokenEstimate.baseCreditInputTokens)
        #expect(!prepared.user.contains(secretTranscript))
        for secret in ["abcdefghijklmnop", "sk-proj-", jwt, "owner@example.com",
                       "internal.example.com", "ultra-secret-value",
                       "A234567890123456789012345678901234567890123456789"] {
            #expect(!prepared.user.contains(secret), "prompt leaked \(secret)")
        }
        #expect(prepared.user.contains("[REDACTED"))
        #expect(!prepared.candidates.contains {
            $0.term.localizedCaseInsensitiveContains("redacted")
                || $0.term.caseInsensitiveCompare("EMAIL") == .orderedSame
                || $0.term.caseInsensitiveCompare("URL") == .orderedSame
        })
    }

    @Test("technical extraction deduplicates existing terms and caps review rows")
    func extractionDedupAndLimits() {
        let technical = ConnectedGlossarySuggestionService.extractCandidates(
            from: ConnectedGlossarySuggestionService.boundedSources(snippets))
        #expect(technical.map(\.id).contains(
            ConnectedGlossarySuggestionService.canonicalKey("RAG")))
        #expect(technical.contains { $0.term.contains("SLO-99.95") })

        let bulk = (0..<120).map { "API-\($0) ProjectName\($0)" }.joined(separator: " ")
        let input = snippets + [GroundingSnippet(
            serverName: "Docs", toolName: "search",
            text: "Kubernetes kubernetes RAG RAG \(bulk)")]
        let bounded = ConnectedGlossarySuggestionService.boundedSources(input)
        let output = ConnectedGlossarySuggestionService.extractCandidates(
            from: bounded,
            excluding: [ConnectedGlossarySuggestionService.canonicalKey("Kubernetes")])
        let keys = output.map(\.id)
        #expect(output.count <= ConnectedGlossarySuggestionService.maxCandidates)
        #expect(Set(keys).count == keys.count)
        #expect(!keys.contains(ConnectedGlossarySuggestionService.canonicalKey("Kubernetes")))

        let supportedTerms = (0..<40).map { "TERM-\($0)" }
        let supported = [GroundingSnippet(
            serverName: "Catalog", toolName: "search",
            text: supportedTerms.joined(separator: " "))]
        let supportedCandidates = ConnectedGlossarySuggestionService.extractCandidates(
            from: ConnectedGlossarySuggestionService.boundedSources(supported))
        let response = "{\"suggestions\":[" + supportedTerms.map {
            "{\"term\":\"\($0)\",\"reason\":\"technical\",\"source\":\"Catalog\"}"
        }.joined(separator: ",") + "]}"
        let review = ConnectedGlossarySuggestionService.parseModelSuggestions(
            response, snippets: supported, candidates: supportedCandidates,
            existingGlossary: "")
        #expect(review.count == ConnectedGlossarySuggestionService.maxSuggestions)
    }

    @Test("model ranking accepts only source-backed terms")
    func sourceBackedModelOutput() {
        let candidates = ConnectedGlossarySuggestionService.extractCandidates(
            from: ConnectedGlossarySuggestionService.boundedSources(snippets))
        let raw = """
        {"suggestions":[
          {"term":"Kubernetes","reason":"cluster platform","sources":["Notion"]},
          {"term":"HallucinatedCloud","reason":"invented","sources":["Notion"]},
          {"term":"RAG","reason":"acronym","source":"Notion"},
          {"term":"Kubernetes","reason":"duplicate","source":"Linear"}
        ]}
        """
        let parsed = ConnectedGlossarySuggestionService.parseModelSuggestions(
            raw, snippets: snippets, candidates: candidates, existingGlossary: "")
        #expect(parsed.map(\.term) == ["Kubernetes", "RAG"])
        #expect(parsed[0].sources == ["Notion"])
    }

    @Test("fast-model failure and timeout fall back to local candidates")
    func modelFailureFallbacks() async throws {
        let model = LLMCatalog.background(for: Config.selectedModel)
        let failed = try #require(await ConnectedGlossarySuggestionService.generate(
            snippets: snippets, existingGlossary: "", model: model,
            ranker: { _, _, _ in throw ConnectedGlossaryGateway.Failure.unavailable }))
        #expect(!failed.suggestions.isEmpty)
        #expect(failed.metrics.ranking == .localFallback)
        #expect(failed.fallbackMessage?.contains("unavailable") == true)

        let timedOut = try #require(await ConnectedGlossarySuggestionService.generate(
            snippets: snippets, existingGlossary: "", model: model,
            ranker: { _, _, _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "{}"
            }, modelDeadline: 0.005))
        #expect(!timedOut.suggestions.isEmpty)
        #expect(timedOut.metrics.ranking == .localFallback)
        #expect(timedOut.fallbackMessage?.contains("timed out") == true)
    }

    @Test("disabled, disconnected, and empty states spend no unnecessary model work")
    func unavailableAndEmptyStates() async {
        await preserveConfig {
            Config.googleTokens = nil
            Config.transcriptionGlossary = ""
            let gateway = ConnectedGlossaryGateway(response: #"{"suggestions":[]}"#)
            var cycles = 0
            let disabled = AppState(
                llm: gateway,
                connectedGlossarySourceProvider: { self.snippets },
                connectedGlossaryGroundedCycleConsumer: { _ in cycles += 1; return true })
            disabled.useConnectedAppsInPrompts = false
            await disabled.generateConnectedGlossarySuggestions()
            #expect(disabled.connectedGlossarySuggestionStatus
                == .unavailable("Connected-app context is off. Enable it before finding terms."))
            #expect(cycles == 0)
            #expect(gateway.calls.isEmpty)

            let disconnected = AppState(
                llm: gateway,
                connectedGlossaryGroundedCycleConsumer: { _ in cycles += 1; return true })
            disconnected.useConnectedAppsInPrompts = true
            await disconnected.generateConnectedGlossarySuggestions()
            #expect(disconnected.connectedGlossarySuggestionStatus
                == .unavailable("Connect at least one readable app before finding terms."))
            #expect(cycles == 0)

            let empty = AppState(
                llm: gateway,
                connectedGlossarySourceProvider: { [] },
                connectedGlossaryGroundedCycleConsumer: { _ in cycles += 1; return true })
            empty.useConnectedAppsInPrompts = true
            await empty.generateConnectedGlossarySuggestions()
            #expect(empty.connectedGlossarySuggestionStatus == .empty)
            #expect(cycles == 1)
            #expect(gateway.calls.isEmpty)
        }
    }

    @Test("fast background model uses bounded tariff math and five-minute cache")
    func cheapModelAndCache() async {
        await preserveConfig {
            Config.transcriptionGlossary = ""
            let gateway = ConnectedGlossaryGateway(response: """
            {"suggestions":[{"term":"Kubernetes","reason":"platform","sources":["Notion"]}]}
            """)
            var sourceReads = 0
            var cycles = 0
            let state = AppState(
                llm: gateway,
                connectedGlossarySourceProvider: {
                    sourceReads += 1
                    return self.snippets
                },
                connectedGlossaryGroundedCycleConsumer: { _ in cycles += 1; return true })
            state.useConnectedAppsInPrompts = true
            state.transcript = [TranscriptEntry(
                source: .system, text: "LIVE-TRANSCRIPT-MUST-STAY-LOCAL", timestamp: Date())]

            await state.generateConnectedGlossarySuggestions()
            let call = gateway.calls.first
            let metrics = state.connectedGlossarySuggestionMetrics
            let expectedModel = LLMCatalog.background(for: Config.selectedModel)
            #expect(call?.model == expectedModel.id)
            #expect(call?.maxOutputTokens == ConnectedGlossarySuggestionService.maxOutputTokens)
            #expect(call?.user.contains("LIVE-TRANSCRIPT-MUST-STAY-LOCAL") == false)
            #expect(metrics?.transcriptCharsSent == 0)
            #expect(metrics?.estimatedComputeCredits == CreditCostEstimate.credits(
                model: expectedModel.id, inputTokens: metrics?.estimatedInputTokens ?? 0))
            #expect(metrics?.estimatedInputTokens ?? .max < TokenEstimate.baseCreditInputTokens)
            #expect(sourceReads == 1 && cycles == 1 && gateway.calls.count == 1)

            await state.generateConnectedGlossarySuggestions()
            #expect(state.connectedGlossarySuggestionMetrics?.cached == true)
            #expect(sourceReads == 1 && cycles == 1 && gateway.calls.count == 1)
        }
    }

    @Test("approve and reject are explicit and never silently mutate the dictionary")
    func explicitReviewOnly() async {
        await preserveConfig {
            Config.transcriptionGlossary = "ExistingTerm"
            let state = AppState(
                llm: ConnectedGlossaryGateway(response: "unused"),
                connectedGlossarySourceProvider: { self.snippets },
                connectedGlossaryGroundedCycleConsumer: { _ in true })
            state.useConnectedAppsInPrompts = true
            await state.generateConnectedGlossarySuggestions(useFastModel: false)
            #expect(Config.transcriptionGlossary == "ExistingTerm")
            let initial = state.connectedGlossarySuggestions
            #expect(initial.count >= 2)

            let rejected = initial[0]
            #expect(state.rejectConnectedGlossarySuggestion(id: rejected.id))
            #expect(Config.transcriptionGlossary == "ExistingTerm")
            if let accepted = state.connectedGlossarySuggestions.first {
                #expect(state.acceptConnectedGlossarySuggestion(id: accepted.id))
                #expect(Glossary.terms(from: Config.transcriptionGlossary).contains(accepted.term))
            } else {
                Issue.record("rejecting one suggestion removed the whole review queue")
            }
            #expect(state.connectedGlossaryAcceptedCount == 1)
            #expect(state.connectedGlossaryRejectedCount == 1)
        }
    }

    @Test("accepting during a call defers the active engine dictionary")
    func midCallDeferredApplication() async throws {
        try await preserveConfig {
            // Замок на ВЕСЬ тест, а не на одну строку чтения.
            // `generateConnectedGlossarySuggestions` внутри себя читает
            // `Config.transcriptionGlossary`, и соседний набор успевал
            // записать туда «Falcon, Kubernetes» между установкой и
            // чтением: кандидат «Falcon» отбрасывался как уже известный,
            // подсказок выходило ноль, и падало на «нечего принимать».
            // И запас по срокам. `generateConnectedGlossarySuggestions` берёт их
            // из статических полей службы — двенадцать секунд на источники и
            // двадцать на модель, настоящих. Под полной нагрузкой источники в
            // них не укладывались, служба отвечала таймаутом, и тест падал на
            // «нечего принимать»: сообщение про приём, причина про часы.
            try await ConnectedGlossarySuggestionService.$sourceDeadline.withValue(600) {
            try await ConnectedGlossarySuggestionService.$modelDeadline.withValue(600) {
            try await SharedDefaults.withExclusiveAccess {
                Config.transcriptionGlossary = "Falcon"
                let state = AppState(
                    llm: ConnectedGlossaryGateway(response: "unused"),
                    connectedGlossarySourceProvider: { self.snippets },
                    connectedGlossaryGroundedCycleConsumer: { _ in true })
                state.useConnectedAppsInPrompts = true
                let active = RecordingSettingsSnapshot(
                    engine: .local, language: "en", localModel: "base",
                    microphoneNoiseSuppression: false, glossary: "Falcon",
                    assemblyDiarization: false)
                state.applyTestActiveRecordingSettings(active)
                state.applyTestWorkspace(recording: true)
                await state.generateConnectedGlossarySuggestions(useFastModel: false)
                // `if let` here let the whole setup no-op silently: with no
                // suggestion there is nothing to accept, so the two assertions
                // below failed instead — reporting "the glossary was not written"
                // when the truth was "nothing was ever suggested". Under a heavily
                // loaded run that is what happened, and the message sent the reader
                // to the wrong end of the feature. Require the precondition.
                let candidate = try #require(state.connectedGlossarySuggestions.first,
                                             "no suggestion to accept — the generate step produced none")
                #expect(state.acceptConnectedGlossarySuggestion(id: candidate.id))
                #expect(state.liveTranscriptionConfiguration().active?.glossary == "Falcon")
                #expect(RecordingSettingsSnapshot.configured().glossary != "Falcon")
                #expect(state.connectedGlossarySuggestionMessage?.contains("next recording") == true)
            }
            }
            }
        }
    }

    @Test("source timeout becomes a recoverable Settings failure")
    func sourceTimeout() async {
        await preserveConfig {
            Config.transcriptionGlossary = ""
            await #expect(throws: ConnectedGlossarySuggestionError.self) {
                _ = try await ConnectedGlossarySuggestionService.loadSources(deadline: 0.005) {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return self.snippets
                }
            }

            let state = AppState(
                llm: ConnectedGlossaryGateway(response: "unused"),
                connectedGlossarySourceProvider: {
                    throw ConnectedGlossaryGateway.Failure.unavailable
                },
                connectedGlossaryGroundedCycleConsumer: { _ in true })
            state.useConnectedAppsInPrompts = true
            await state.generateConnectedGlossarySuggestions()
            if case .failed = state.connectedGlossarySuggestionStatus {} else {
                Issue.record("source failure did not become a recoverable failed status")
            }
        }
    }

    @Test("dev fixture exercises production proposal and review state without network")
    func devFixture() async {
        await preserveConfig {
            Config.transcriptionGlossary = ""
            let gateway = ConnectedGlossaryGateway(response: "must not run")
            var cycles = 0
            let state = AppState(
                llm: gateway,
                connectedGlossaryGroundedCycleConsumer: { _ in cycles += 1; return true })
            let loaded = await state.debugLoadConnectedGlossaryFixture()
            #expect(loaded == Config.isDevBuild)
            if loaded {
                #expect(state.connectedGlossarySuggestionMetrics?.ranking == .localOnly)
                #expect(state.connectedGlossarySuggestionMetrics?.transcriptCharsSent == 0)
                #expect(!state.connectedGlossarySuggestions.isEmpty)
                _ = NSApplication.shared
                let data = LiveTestHooks.snapshotJSON(of: state)
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                #expect(json?["connectedGlossarySuggestionStatus"] as? String == "ready")
                #expect(json?["connectedGlossarySuggestionTranscriptCharsSent"] as? Int == 0)
                #expect((json?["connectedGlossarySuggestionTerms"] as? [String])?.isEmpty == false)
            }
            #expect(gateway.calls.isEmpty)
            #expect(cycles == 0)
        }
    }
}
