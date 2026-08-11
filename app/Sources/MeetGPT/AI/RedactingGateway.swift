import Foundation

/// The single point where outbound text is checked for secrets.
///
/// Four types implement `LLMGateway` — the backend, the direct Anthropic
/// client, the auto-orchestrator and the ensemble — and every feature holds one
/// as an existential. A filter attached to features instead would be bypassed
/// by the next caller someone adds, which is the failure this shape prevents:
/// wrap the gateway once at construction and every present and future caller is
/// covered, because there is no route to a provider that does not pass through
/// here.
///
/// Redacts and proceeds. A detection never blocks the request; the matched span
/// is replaced and the caller is told what went, so a false positive costs a
/// slightly poorer answer rather than a dead end — and the user can correct a
/// redaction they can see, on an answer they already have.
final class RedactingGateway: LLMGateway {
    private let wrapped: any LLMGateway
    private let userTerms: () -> [String]
    private let isEnabled: () -> Bool
    /// Called with everything removed from a request, for the session-level
    /// marker and correction UI.
    private let onRedaction: ([OutboundRedactor.Finding]) -> Void

    init(wrapping gateway: any LLMGateway,
         userTerms: @escaping () -> [String] = { Config.redactionTerms },
         isEnabled: @escaping () -> Bool = { Config.outboundRedactionEnabled },
         onRedaction: @escaping ([OutboundRedactor.Finding]) -> Void = { _ in }) {
        self.wrapped = gateway
        self.userTerms = userTerms
        self.isEnabled = isEnabled
        self.onRedaction = onRedaction
    }

    /// Both halves of the request, redacted together so one finding list covers
    /// the whole send.
    private func clean(system: String, user: String) -> (system: String, user: String) {
        guard isEnabled() else { return (system, user) }
        let terms = userTerms()
        let cleanedSystem = OutboundRedactor.redact(system, userTerms: terms)
        let cleanedUser = OutboundRedactor.redact(user, userTerms: terms)
        let findings = cleanedSystem.findings + cleanedUser.findings
        if !findings.isEmpty { onRedaction(findings) }
        return (cleanedSystem.text, cleanedUser.text)
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let cleaned = clean(system: system, user: user)
        return try await wrapped.streamChat(system: cleaned.system, user: cleaned.user,
                                            images: images, model: model, onDelta: onDelta)
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let cleaned = clean(system: system, user: user)
        return try await wrapped.streamChat(system: cleaned.system, user: cleaned.user,
                                            images: images, model: model,
                                            maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }
}
