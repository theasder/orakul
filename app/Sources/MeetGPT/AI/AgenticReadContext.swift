import Foundation

/// Supplies the read loop with what it cannot reach from a gateway.
///
/// `LLMGatewayFactory.make()` runs before any `AppState` exists, so the gateway
/// cannot hold one. This is the seam that lets it ask, at request time, which
/// connectors are available and whether a call is live — both of which change
/// during a session and must not be captured at construction.
///
/// Empty by default, which makes the loop inert: with no provider wired the
/// gateway does not append the tool instruction at all. That is the right
/// default for tests and for a build where connectors are not configured.
final class AgenticReadContext: @unchecked Sendable {
    static let shared = AgenticReadContext()

    private let lock = NSLock()
    private var executorProvider: (() async -> AgenticReadExecutor?)?
    private var recordingProvider: (() async -> Bool)?
    private var turnSink: ((AgenticReadStep.Turn) -> Void)?

    private init() {}

    /// Wired once by AppState at startup.
    func configure(executor: @escaping () async -> AgenticReadExecutor?,
                   isRecording: @escaping () async -> Bool,
                   onTurnComplete: @escaping (AgenticReadStep.Turn) -> Void) {
        lock.lock(); defer { lock.unlock() }
        executorProvider = executor
        recordingProvider = isRecording
        turnSink = onTurnComplete
    }

    func executor() async -> AgenticReadExecutor? {
        lock.lock()
        let provider = executorProvider
        lock.unlock()
        return await provider?()
    }

    func isRecording() async -> Bool {
        lock.lock()
        let provider = recordingProvider
        lock.unlock()
        return await provider?() ?? false
    }

    func record(_ turn: AgenticReadStep.Turn) {
        lock.lock()
        let sink = turnSink
        lock.unlock()
        sink?(turn)
    }

    /// Test seam: restore the inert default.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        executorProvider = nil
        recordingProvider = nil
        turnSink = nil
    }
}
