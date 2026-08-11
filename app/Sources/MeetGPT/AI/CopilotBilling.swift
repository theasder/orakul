import Foundation

/// Which co-pilot loop a chat call belongs to, so the server can bill it
/// against the budget it was designed for.
///
/// The agenda, rhetoric and facilitation watches reach the backend through the
/// same `/api/llm/chat` endpoint the user's own prompts use, and that endpoint
/// billed everything as generic `chat`. `chat` classifies as the CLOUD pool —
/// on Free, 15 credits a MONTH, shared with streamed transcription. Three
/// watches on a 300 s cadence at 2 credits a tick empty that pool in about
/// thirteen minutes of a single call, while the 210-credit copilot pool those
/// loops exist to spend sits nearly untouched. The server already knew the
/// three names; nothing had ever sent one.
///
/// A task-local rather than a parameter on `LLMGateway`: the label concerns
/// billing, not generation, and threading it through the protocol would touch
/// every conformer and every mock to carry a value only one gateway reads.
/// Task-locals propagate into child tasks, so wrapping the call is enough.
enum CopilotBilling {
    /// The three the server will honour. Anything else is billed as `chat` —
    /// the label is validated server-side and never trusted, so a wrong value
    /// here costs correctness of the report, not money.
    enum Watch: String, CaseIterable, Sendable {
        case agenda, rhetoric, facilitation
    }

    @TaskLocal static var watch: Watch?

    /// Run `body` with every backend chat call inside it labelled as `watch`.
    static func labelled<T>(_ watch: Watch,
                            _ body: () async throws -> T) async rethrows -> T {
        try await $watch.withValue(watch) { try await body() }
    }
}
