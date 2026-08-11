import AppKit
import Foundation
import Testing
@testable import MeetGPT

/// Captures whatever the app actually sends, so a test can assert on the real
/// request rather than on the pieces that were supposed to build it.
private final class CapturingGateway: LLMGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(system: String, user: String)] = []

    var requests: [(system: String, user: String)] { lock.withLock { seen } }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        // Two other passes share this gateway and are not the request under
        // test: the ambiguity clarifier, which runs BEFORE the answer, and
        // follow-up generation, which runs after. Both are identified by their
        // own system prompts rather than by call order, so a change in
        // sequencing cannot make this test quietly assert on the wrong request.
        if system == FollowUpService.systemPrompt { return "[]" }
        if system.hasPrefix("You decide whether a request to a meeting co-pilot is ambiguous") {
            return "{\"needsClarification\":false}"
        }
        lock.withLock { seen.append((system, user)) }
        onDelta("Answered.")
        return "Answered."
    }
}

/// F1, end to end through `AppState.ask`.
///
/// Every other recall test checks a piece: the service ranks, the context
/// builder formats, the wiring line exists. None of them prove the prior-meeting
/// record reaches the model — which is the only thing the feature is. A wiring
/// line that silently stopped being called would leave all of those green.
@Suite("Recall reaches the model")
@MainActor
struct RecallEndToEndTests {

    private func storeWithHistory() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let started = Date().addingTimeInterval(-11 * 86_400)
        try store.save(SavedSession(
            id: UUID(), title: "Pricing sync", startedAt: started, savedAt: started,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to move to usage-based pricing at two cents per credit."))
        return store
    }

    /// The request the app actually sent, after the work has finished.
    ///
    /// This used to poll `gateway.requests` against a 30-second deadline, and
    /// under a full parallel run that deadline expired: not because the product
    /// was slow, but because `ask`'s task was competing with ~2,500 other tests
    /// for the MainActor. A deadline measured scheduling latency and reported it
    /// as a product failure — the exact defect this suite was written to catch
    /// elsewhere.
    ///
    /// `AppState.run` stores its work in `aiTask`, so the test can await THAT.
    /// No clock, no polling, no window to expire: the assertion happens when the
    /// work is done, however long the machine took to get there.
    private func requestSent(by state: AppState, to gateway: CapturingGateway) async
        -> (system: String, user: String)? {
        await state.aiTask?.value
        return gateway.requests.first
    }

    /// Ask without the clarification detour.
    ///
    /// `ask` normally runs an ambiguity assessment first and only then reaches
    /// `run` — an extra async hop that a saturated machine can starve for
    /// tens of seconds. These tests are about whether recall reaches the model,
    /// not about clarification, so they pin the flag and take the direct path.
    /// Left in, the hop made this suite pass alone and fail on every full run,
    /// which is the failure mode I had just finished removing from two others.
    private func withClarificationDisabled(_ body: () -> Void) {
        let previous = Config.clarifyingQuestionsEnabled
        Config.clarifyingQuestionsEnabled = false
        defer { Config.clarifyingQuestionsEnabled = previous }
        body()
    }

    @Test("asking a recall question sends the prior-meeting record to the model")
    func recallQuestionCarriesTheRecord() async throws {
        let gateway = CapturingGateway()
        let state = AppState(llm: gateway, sessionStore: try storeWithHistory())

        withClarificationDisabled { state.ask("what did we decide about pricing?") }
        let request = try #require(await requestSent(by: state, to: gateway))

        let payload = request.system + "\n" + request.user
        #expect(payload.contains("PRIOR-MEETING RECORD"),
                "the recall block never reached the request")
        #expect(payload.contains("Pricing sync"), "the answer cannot cite a meeting it was not given")
        #expect(payload.contains("usage-based pricing at two cents per credit"))
    }

    @Test("an ordinary question does not drag old meetings into the prompt")
    func ordinaryQuestionStaysClean() async throws {
        let gateway = CapturingGateway()
        let state = AppState(llm: gateway, sessionStore: try storeWithHistory())

        withClarificationDisabled { state.ask("summarise what has been said so far") }
        let request = try #require(await requestSent(by: state, to: gateway))

        let payload = request.system + "\n" + request.user
        #expect(!payload.contains("PRIOR-MEETING RECORD"),
                "every prompt paying for old-meeting context is a bill the user did not ask for")
    }
}
