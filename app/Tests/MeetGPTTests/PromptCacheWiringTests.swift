import Foundation
import Testing
@testable import MeetGPT

// The split, the breakpoint and the request body were each built and tested in
// isolation — and none of it did anything, because the caller still passed one
// joined string. Unit tests on the pieces cannot catch that; only something
// looking at the call site can.
//
// `runPrompt` is fire-and-forget, so asserting through it would be a race. This
// pins the wiring the same way `RecordingContextTests` pins the composer's use
// of adapted prompts: by reading the source.

/// A gateway that only implements the protocol's own requirements.
private final class BreakpointSpy: LLMGateway, @unchecked Sendable {
    var sawBreakpoint = false
    var joinedUser: String?

    func streamChat(system: String, user: String, images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        joinedUser = user
        return ""
    }

    func streamChat(system: String, user: String, images: [Data],
                    model: LLMModel, maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        joinedUser = user
        return ""
    }

    func streamChat(system: String, cachedPrefix: String, volatileSuffix: String,
                    images: [Data], model: LLMModel, maxOutputTokens: Int?,
                    onUsage: ((TokenUsage) -> Void)?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        sawBreakpoint = true
        onUsage?(TokenUsage(inputTokens: 40, outputTokens: 5,
                            cacheCreationTokens: 0, cacheReadTokens: 9_960))
        return ""
    }
}

@Suite("A gateway's own breakpoint implementation is the one that runs")
struct BreakpointDispatchTests {
    @Test("calling through the protocol reaches the conformer, not the default")
    func dispatchIsDynamic() async throws {
        // The trap this exists for: a protocol EXTENSION method that is not also
        // a requirement dispatches statically. Held as an existential — which is
        // how AppState holds its gateway — every call would land on the default
        // implementation, quietly joining the halves and dropping the
        // breakpoint, while the call site looked correctly wired.
        let spy = BreakpointSpy()
        let gateway: LLMGateway = spy

        _ = try await gateway.streamChat(
            system: "s", cachedPrefix: "stable", volatileSuffix: "volatile",
            images: [], model: LLMCatalog.all.first!, maxOutputTokens: nil,
            onUsage: nil) { _ in }

        #expect(spy.sawBreakpoint, "the default implementation swallowed the split")
        #expect(spy.joinedUser == nil)
    }

    @Test("what the call cost reaches the caller")
    func usageIsReported() async throws {
        // Without this the cache is unfalsifiable: a breakpoint the API ignored
        // and one that worked are indistinguishable from the app's side.
        let spy = BreakpointSpy()
        let gateway: LLMGateway = spy
        var reported: TokenUsage?

        _ = try await gateway.streamChat(
            system: "s", cachedPrefix: "stable", volatileSuffix: "volatile",
            images: [], model: LLMCatalog.all.first!, maxOutputTokens: nil,
            onUsage: { reported = $0 }) { _ in }

        #expect(reported?.cacheReadTokens == 9_960)
        #expect((reported?.cacheHitRate ?? 0) > 0.99)
    }
}

@Suite("The prompt path is wired to its cache breakpoint")
struct PromptCacheWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    @Test("the answer run builds the message in two halves")
    func answerRunSplitsTheMessage() throws {
        let appState = try source("Sources/MeetGPT/AppState.swift")
        #expect(appState.contains("SystemInstructions.buildUserMessageParts("))
    }

    @Test("the answer run hands the gateway the split, not a joined string")
    func answerRunPassesTheBreakpoint() throws {
        // Without this the whole chain below it is inert: the client marks a
        // prefix nobody supplied, and every pass pays full price.
        let appState = try source("Sources/MeetGPT/AppState.swift")
        #expect(appState.contains("cachedPrefix: messageParts.stable"))
        #expect(appState.contains("volatileSuffix: messageParts.volatile"))
    }

    @Test("the answer run records what the call actually cost")
    func answerRunRecordsUsage() throws {
        // Every other number in the diagnostics is a character count divided by
        // four. This one comes from the provider, and it is the only thing that
        // can falsify the caching.
        let appState = try source("Sources/MeetGPT/AppState.swift")
        #expect(appState.contains("onUsage:"))
        #expect(appState.contains("\"assistant_usage\""))
        #expect(appState.contains("\"cacheReadTokens\""))
        #expect(appState.contains("\"cacheHitRate\""))
    }

    @Test("diagnostics still record the whole message")
    func diagnosticsSeeTheFullPrompt() throws {
        // Splitting the call must not halve what the dev log shows, or a
        // reported prompt stops matching the one that was sent.
        let appState = try source("Sources/MeetGPT/AppState.swift")
        #expect(appState.contains("messageParts.stable + messageParts.volatile"))
        #expect(appState.contains("\"user\": userMessage"))
    }

    @Test("only Anthropic is handed the breakpoint")
    func routerMarksOnlyTheProviderThatSupportsIt() throws {
        // OpenAI matches prefixes automatically and the rest do not cache, so
        // marking them would be a no-op at best and a wrong request at worst.
        let gateway = try source("Sources/MeetGPT/AI/LLMGateway.swift")
        #expect(gateway.contains("guard model.provider == .anthropic else"))
        // And the default implementation must still send the same bytes, or a
        // gateway that cannot express a breakpoint changes the prompt.
        #expect(gateway.contains("user: cachedPrefix + volatileSuffix"))
    }
}
