import AppKit
import Foundation
import Testing
@testable import MeetGPT

private final class BlockingBlindSpotProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var requestsStorage: [AppState.BlindSpotProviderRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var returnedStorage = false

    var requests: [AppState.BlindSpotProviderRequest] {
        lock.withLock { requestsStorage }
    }

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    var didReturn: Bool {
        lock.withLock { returnedStorage }
    }

    func respond(
        to request: AppState.BlindSpotProviderRequest
    ) async throws -> BrainstormService.SuggestionResult {
        lock.withLock { requestsStorage.append(request) }
        await withCheckedContinuation { pending in
            let releaseNow = lock.withLock {
                if releaseRequested { return true }
                continuation = pending
                return false
            }
            if releaseNow { pending.resume() }
        }
        lock.withLock { returnedStorage = true }
        return .init(
            suggestions: [Suggestion(
                title: "Confirm delivery date",
                detail: "The vendor date remains unresolved.",
                kind: .risk,
                evidence: "vendor has not confirmed the delivery date")],
            execution: .init(
                correlationId: "stale-provider-correlation",
                provider: "openrouter",
                model: "test-model",
                latencyMs: 25,
                chargedCredits: 3,
                cacheHit: false,
                attemptCount: 1,
                attempts: nil))
    }

    func release() {
        let pending = lock.withLock {
            releaseRequested = true
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume()
    }
}

private final class ImmediateBlindSpotProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var requestsStorage: [AppState.BlindSpotProviderRequest] = []
    private var probeQueryOnceStorage: String?
    let error: Error?

    init(error: Error? = nil, probeQueryOnce: String? = nil) {
        self.error = error
        self.probeQueryOnceStorage = probeQueryOnce
    }

    var requests: [AppState.BlindSpotProviderRequest] {
        lock.withLock { requestsStorage }
    }

    func respond(
        to request: AppState.BlindSpotProviderRequest
    ) async throws -> BrainstormService.SuggestionResult {
        lock.withLock { requestsStorage.append(request) }
        if let error { throw error }
        // Handed out on the FIRST outcome only, so a test can watch the pending
        // query be consumed without the next outcome re-arming it.
        let probeQuery = lock.withLock {
            let value = probeQueryOnceStorage
            probeQueryOnceStorage = nil
            return value
        }
        return .init(
            suggestions: [Suggestion(
                title: "Confirm delivery date",
                detail: "The vendor date remains unresolved.",
                kind: .risk,
                evidence: "vendor has not confirmed the delivery date")],
            execution: .init(
                correlationId: "live-provider-correlation",
                provider: "openrouter",
                model: "test-model",
                latencyMs: 12,
                chargedCredits: 3,
                cacheHit: false,
                attemptCount: 1,
                attempts: nil),
            probeQuery: probeQuery)
    }
}

private final class BlockingBlindSpotTokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    func token() async -> String? {
        await withCheckedContinuation { pending in
            let releaseNow = lock.withLock {
                if releaseRequested { return true }
                continuation = pending
                return false
            }
            if releaseNow { pending.resume() }
        }
        return "stale-token"
    }

    func release() {
        let pending = lock.withLock {
            releaseRequested = true
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume()
    }
}

@MainActor
@Suite("Blind Spot scheduler races", .serialized)
struct BlindSpotSchedulerRaceTests {
    private enum Invalidation: CaseIterable {
        case settingsOff
        case snooze
        case stop
        case newCall
    }

    private struct SavedConfig {
        let brainstorm = Config.brainstormEnabled
        let connectedApps = Config.connectedAppsGroundingEnabled

        func restore() {
            Config.brainstormEnabled = brainstorm
            Config.connectedAppsGroundingEnabled = connectedApps
        }
    }

    private func transcript() -> [TranscriptEntry] {
        [
            TranscriptEntry(
                source: .system,
                text: "Project Falcon rollout is scheduled for Friday, but the vendor has not confirmed the delivery date and the operations team still lacks a fallback owner."),
            TranscriptEntry(
                source: .mic,
                text: "We agreed that customer migration depends on the hardware arriving before Thursday, and nobody has validated the contingency budget or escalation path."),
            TranscriptEntry(
                source: .system,
                text: "The launch announcement is drafted, yet the support staffing decision and the final go or no-go approver remain explicitly unresolved today."),
        ]
    }

    private func prepare(_ state: AppState, goal: String = "De-risk Project Falcon") {
        state.applyTestWorkspace(recording: true)
        state.callGoal = goal
        state.transcript = transcript()
        state.setBlindSpotsEnabled(true)
        state.forceBlindSpotRefreshForTesting()
    }

    private func waitUntil(
        iterations: Int = 2_000,
        _ predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return predicate()
    }

    @Test("same-value Settings writes do not restart the Blind Spot task")
    func settingsWriteIsIdempotent() {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        state.applyTestWorkspace(recording: true)

        state.setBlindSpotsEnabled(true)
        let firstGeneration = state.blindSpotGenerationForTesting()
        state.setBlindSpotsEnabled(true)

        #expect(firstGeneration != nil)
        #expect(state.blindSpotGenerationForTesting() == firstGeneration)
        #expect(state.liveWatchActivity().brainstormTaskActive)
        state.setBlindSpotsEnabled(false)
    }

    @Test("OFF, snooze, Stop, and new call reject a non-cooperative stale provider")
    func everyInFlightInvalidationRejectsStaleOutcome() async {
        for transition in Invalidation.allCases {
            let saved = SavedConfig()
            Config.brainstormEnabled = false
            Config.connectedAppsGroundingEnabled = false
            let provider = BlockingBlindSpotProvider()
            let state = AppState(
                credentialStore: InMemoryKeychain(),
                blindSpotSuggestionProvider: { request in
                    try await provider.respond(to: request)
                },
                blindSpotAccessTokenProvider: { nil },
                blindSpotSkillGuidanceProvider: { _, _ in nil })
            prepare(state)
            #expect(await waitUntil { provider.isWaiting }, "\(transition)")
            let oldSession = state.currentSessionID

            switch transition {
            case .settingsOff:
                state.setBlindSpotsEnabled(false)
            case .snooze:
                state.snoozeSuggestionsForCall()
            case .stop:
                state.applyTestWorkspace(recording: false)
            case .newCall:
                state.resetForNewRecording()
            }
            provider.release()
            #expect(await waitUntil { provider.didReturn }, "\(transition)")
            // Give the actor-bound scheduler a turn to process the deliberately
            // stale return from a provider that ignored cancellation.
            await Task.yield()

            #expect(state.suggestions.isEmpty, "\(transition)")
            #expect(state.blindSpotActivity().successes == 0, "\(transition)")
            #expect(state.blindSpotActivity().lastBackendCorrelationID == nil, "\(transition)")
            if transition == .newCall {
                #expect(state.currentSessionID != oldSession)
                #expect(state.blindSpotActivity().attempts == 0)
                #expect(state.blindSpotActivity().lastOutcome == nil)
            } else {
                #expect(state.blindSpotActivity().attempts == 1, "\(transition)")
                #expect(state.blindSpotActivity().lastOutcome == "cancelled", "\(transition)")
            }
            state.setBlindSpotsEnabled(false)
            saved.restore()
        }
    }

    @Test("backpressure does not consume the transcript baseline or miss the retry")
    func backpressureRetriesExactSnapshot() async throws {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let queue = BackgroundLLMQueue(maxConcurrent: 2)
        #expect(await queue.reserve(key: "occupied-a", signature: 1))
        #expect(await queue.reserve(key: "occupied-b", signature: 1))
        let provider = ImmediateBlindSpotProvider()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            backgroundLLMQueue: queue,
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        prepare(state)

        #expect(await waitUntil {
            (state.blindSpotSchedulerStateForTesting()?.evaluations ?? 0) >= 1
        })
        #expect(provider.requests.isEmpty)
        #expect(state.blindSpotSchedulerStateForTesting()?.charactersAtLastRun == nil)

        await queue.finish(key: "occupied-a")
        await queue.finish(key: "occupied-b")
        state.forceBlindSpotRefreshForTesting()
        #expect(await waitUntil { provider.requests.count == 1 })
        #expect(await waitUntil { state.blindSpotActivity().successes == 1 })
        #expect(state.blindSpotSchedulerStateForTesting()?.charactersAtLastRun != nil)
        #expect(state.suggestions.map(\.title) == ["Confirm delivery date"])
        state.setBlindSpotsEnabled(false)
    }

    @Test("a visible user answer has priority over a new Blind Spot wake")
    func foregroundAnswerDefersAmbientSpend() async {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let provider = ImmediateBlindSpotProvider()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })

        state.applyTestWorkspace(recording: true)
        state.callGoal = "De-risk Project Falcon"
        state.transcript = transcript()
        state.aiStreaming = true
        state.setBlindSpotsEnabled(true)
        state.forceBlindSpotRefreshForTesting()

        #expect(await waitUntil {
            (state.blindSpotSchedulerStateForTesting()?.evaluations ?? 0) >= 1
        })
        #expect(provider.requests.isEmpty)
        #expect(state.blindSpotSchedulerStateForTesting()?.charactersAtLastRun == nil)

        state.aiStreaming = false
        state.forceBlindSpotRefreshForTesting()
        #expect(await waitUntil { provider.requests.count == 1 })
        #expect(await waitUntil { state.blindSpotActivity().successes == 1 })
        state.setBlindSpotsEnabled(false)
    }

    @Test("disable during token lookup prevents the provider request")
    func disableBeforeProviderBoundary() async {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let tokenProvider = BlockingBlindSpotTokenProvider()
        let provider = ImmediateBlindSpotProvider()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { await tokenProvider.token() },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        prepare(state)

        #expect(await waitUntil { tokenProvider.isWaiting })
        state.setBlindSpotsEnabled(false)
        tokenProvider.release()
        await Task.yield()
        #expect(provider.requests.isEmpty)
        #expect(state.blindSpotActivity().attempts == 0)
        #expect(state.suggestions.isEmpty)
    }

    @Test("a provider 429 latches quota and never promises an automatic retry")
    func quotaDoesNotClaimRetry() async {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let provider = ImmediateBlindSpotProvider(error: LLMError.http(
            "Brainstorm", 429,
            #"{"error":"Synthetic credit pool is empty.","upgrade":true}"#))
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        prepare(state)

        #expect(await waitUntil { state.blindSpotActivity().failures == 1 })
        #expect(state.copilotQuotaMessage == "Synthetic credit pool is empty.")
        #expect(state.blindSpotFailureMessage == "Synthetic credit pool is empty.")
        #expect(state.blindSpotFailureMessage?.localizedCaseInsensitiveContains("retry") == false)
        #expect(state.blindSpotActivity().lastOutcome == "failed")
        #expect(await waitUntil { !state.liveWatchActivity().brainstormTaskActive })
        state.setBlindSpotsEnabled(false)
    }

    @Test("authorized synthetic trace exactly reconstructs the bounded provider body")
    func syntheticTraceIsExactAndSnapshotVisible() async throws {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        Config.connectedAppsGroundingEnabled = false
        let provider = ImmediateBlindSpotProvider()
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { "must-not-enter-evidence" },
            blindSpotSkillGuidanceProvider: { _, _ in "Synthetic fixed guidance" })
        prepare(state, goal: LiveTestHooks.syntheticBlindSpotGoal)
        state.beginSyntheticBlindSpotTraceCapture(
            goal: LiveTestHooks.syntheticBlindSpotGoal)
        // Arm before the wake is consumed even on a heavily loaded full suite.
        state.forceBlindSpotRefreshForTesting()

        #expect(await waitUntil { state.blindSpotActivity().successes == 1 })
        let request = try #require(provider.requests.first)
        let trace = try #require(state.syntheticBlindSpotTrace())
        #expect(trace.goal == request.goal)
        #expect(trace.transcript == request.transcript)
        #expect(trace.priorTitles == request.priorTitles)
        #expect(trace.guidance == request.guidance)
        #expect(trace.context == request.context)
        #expect(trace.probe == request.probe)
        #expect(trace.theme == request.theme)
        #expect(trace.grounded == request.grounded)
        #expect(trace.transcript.count <= 8_000)
        #expect((trace.guidance?.count ?? 0) <= 8_000)
        #expect(trace.priorTitles.count <= 40)
        #expect(trace.preparedAt <= (trace.tokenLookupStartedAt ?? 0))
        #expect((trace.tokenLookupStartedAt ?? 0) <= (trace.tokenLookupCompletedAt ?? 0))
        #expect((trace.tokenLookupCompletedAt ?? 0) <= (trace.providerStartedAt ?? 0))
        #expect((trace.providerStartedAt ?? 0) <= (trace.providerCompletedAt ?? 0))

        let payload = try #require(trace.requestPayload?.data(using: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["goal"] as? String == request.goal)
        #expect(object["transcript"] as? String == request.transcript)
        #expect(object["priorSuggestions"] as? [String] == request.priorTitles)
        #expect(object["probe"] as? String == request.probe)
        #expect(object["accessToken"] == nil)
        #expect(!String(data: payload, encoding: .utf8)!.contains("must-not-enter-evidence"))

        _ = NSApplication.shared
        let snapshot = LiveTestHooks.snapshotJSON(
            of: state, requestID: "synthetic-trace", appliedAt: 123)
        let root = try #require(
            JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        let snapshotTrace = try #require(
            root["blindSpotSyntheticTrace"] as? [String: Any])
        #expect(snapshotTrace["goal"] as? String == request.goal)
        #expect(snapshotTrace["transcript"] as? String == request.transcript)
        #expect(snapshotTrace["requestPayload"] as? String == trace.requestPayload)
        state.setBlindSpotsEnabled(false)
    }

    @Test("a probeQuery is captured from one outcome and consumed by the next scan")
    func probeQueryCapturedThenConsumedOnce() async {
        let saved = SavedConfig()
        defer { saved.restore() }
        Config.brainstormEnabled = false
        // Connectors OFF: the scan must not ask for a query (canProbe false), and
        // a pending query has no grounded cycle to spend itself on — so the
        // consume-once contract shows as capture → drop, never carry.
        Config.connectedAppsGroundingEnabled = false
        let provider = ImmediateBlindSpotProvider(probeQueryOnce: "acme renewal history")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            blindSpotSuggestionProvider: { request in
                try await provider.respond(to: request)
            },
            blindSpotAccessTokenProvider: { nil },
            blindSpotSkillGuidanceProvider: { _, _ in nil })
        prepare(state)

        #expect(await waitUntil { provider.requests.count >= 1 })
        #expect(provider.requests.first?.canProbe == false)
        // Captured from the first outcome, held for the next cycle.
        #expect(await waitUntil {
            state.blindSpotPendingProbeQueryForTesting() == "acme renewal history"
        })

        // New material, or the loop rightly skips the rescan as "unchanged";
        // the wake poll runs in 500ms slices, so give the wait real headroom.
        state.transcript.append(TranscriptEntry(
            source: .mic,
            text: "Also the vendor now says the delivery could slip a further week past Thursday."))
        state.forceBlindSpotRefreshForTesting()
        #expect(await waitUntil(iterations: 8_000) { provider.requests.count >= 2 })
        // The second scan consumed it at start (and, with connectors off,
        // dropped it); its own outcome carried none, so nothing re-armed.
        #expect(await waitUntil(iterations: 8_000) {
            state.blindSpotPendingProbeQueryForTesting() == nil
        })
        #expect(provider.requests.last?.canProbe == false)
        state.setBlindSpotsEnabled(false)
    }
}
