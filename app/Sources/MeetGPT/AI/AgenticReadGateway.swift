import Foundation

/// Runs the bounded read loop around any gateway.
///
/// A decorator for the same reason `RedactingGateway` is one: it wraps the
/// gateway once at construction, so every caller gets the behaviour and no
/// feature has to opt in or remember to. It also keeps the loop out of
/// `AppState.run`, which is long enough that adding a retry loop to it would be
/// the riskiest possible place to put one.
///
/// **Deltas are held until the shape of the answer is known.** The protocol says
/// a tool request is emitted alone, so the first non-whitespace characters
/// decide: if they open the marker, nothing is forwarded and the user never sees
/// the machinery; otherwise the buffer is flushed and the gateway becomes a
/// pass-through for the rest of the answer. That costs a few characters of
/// latency on the first token and nothing after it.
///
/// **Inactive unless there is something to read.** With no connected servers the
/// instruction is not appended at all — telling a model about a capability it
/// cannot use spends tokens to invite requests that can only be refused.
final class AgenticReadGateway: LLMGateway {
    private let wrapped: any LLMGateway
    private let executor: () async -> AgenticReadExecutor?
    private let isRecording: () async -> Bool
    /// Called with the finished turn so the answer can carry its sources.
    private let onTurnComplete: (AgenticReadStep.Turn) -> Void

    init(wrapping gateway: any LLMGateway,
         executor: @escaping () async -> AgenticReadExecutor?,
         isRecording: @escaping () async -> Bool = { false },
         onTurnComplete: @escaping (AgenticReadStep.Turn) -> Void = { _ in }) {
        self.wrapped = gateway
        self.executor = executor
        self.isRecording = isRecording
        self.onTurnComplete = onTurnComplete
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await run(system: system, user: user, images: images, model: model,
                      onDelta: onDelta) { system, user, onDelta in
            try await self.wrapped.streamChat(system: system, user: user, images: images,
                                              model: model, onDelta: onDelta)
        }
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await run(system: system, user: user, images: images, model: model,
                      onDelta: onDelta) { system, user, onDelta in
            try await self.wrapped.streamChat(system: system, user: user, images: images,
                                              model: model, maxOutputTokens: maxOutputTokens,
                                              onDelta: onDelta)
        }
    }

    private typealias Send = (String, String, @escaping (String) -> Void) async throws -> String

    private func run(system: String, user: String, images: [Data], model: LLMModel,
                     onDelta: @escaping (String) -> Void,
                     send: Send) async throws -> String {
        guard let executor = await executor() else {
            return try await send(system, user, onDelta)
        }

        let startedAt = Date()
        let recording = await isRecording()
        var turn = AgenticReadStep.Turn()
        var conversation = user
        var answer = ""

        // Bounded by the same budget the controller enforces, plus one: the
        // final pass that produces the answer after the last lookup.
        for _ in 0...AgenticReadStep.maxCallsPerTurn {
            let gate = DeltaGate(forward: onDelta)
            answer = try await send(system + "\n\n" + AgenticToolRequest.instruction,
                                    conversation) { gate.accept($0) }

            guard let request = AgenticToolRequest.parse(answer) else {
                gate.flush()
                onTurnComplete(turn)
                return answer
            }

            let outcome = await executor.perform(
                request, turn: turn,
                elapsed: Date().timeIntervalSince(startedAt), isRecording: recording)
            if let attribution = outcome.attribution { turn.record(attribution) }
            if let refusal = outcome.refusal { turn.record(refusal) }

            // Carry the exchange forward so the model can see what it asked and
            // what came back, rather than repeating the request.
            conversation += "\n\n" + AgenticToolRequest.stripped(from: answer)
            conversation += "\n\n" + (outcome.resultBlock ?? "")
        }

        // Budget exhausted with a request still pending: answer with what there
        // is rather than looping. The source note says what was and was not read.
        turn.record(.budgetSpent)
        let visible = AgenticToolRequest.stripped(from: answer)
        onDelta(visible)
        onTurnComplete(turn)
        return visible
    }
}

/// Holds streamed deltas until it can tell an answer from a tool request.
///
/// Once the first non-whitespace characters rule the marker out, everything
/// buffered is forwarded at once and the gate stays open — so the hold costs a
/// few characters on the first token and nothing afterwards.
private final class DeltaGate {
    private let forward: (String) -> Void
    private var buffer = ""
    private var open = false

    init(forward: @escaping (String) -> Void) { self.forward = forward }

    func accept(_ delta: String) {
        if open { forward(delta); return }
        buffer += delta
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Still ambiguous while the text is a prefix of the marker.
        if AgenticToolRequest.opening.hasPrefix(trimmed) { return }
        if trimmed.hasPrefix(AgenticToolRequest.opening) { return }
        open = true
        forward(buffer)
        buffer = ""
    }

    /// Flush anything held when the answer turned out not to be a request.
    func flush() {
        guard !open, !buffer.isEmpty else { return }
        open = true
        forward(buffer)
        buffer = ""
    }
}
