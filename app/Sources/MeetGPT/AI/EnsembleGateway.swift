import Foundation

/// Council-mode chat: the same request is answered independently by a PANEL of
/// models mixing American frontier and Chinese providers, then a CHAIRMAN
/// model reconciles the proposals into one answer, streamed to the caller.
///
/// Why: different training corpora, alignment recipes, and cultural priors
/// fail differently — consensus over a diverse panel curbs single-model
/// blind spots and monoculture bias (mixture-of-agents / council pattern).
///
/// Config (mac/.env):
///   LLM_GATEWAY=ensemble               turns it on (whole-app)
///   ENSEMBLE_PANEL=provider/model,…    panel members (default mixes US + CN)
///   ENSEMBLE_CHAIRMAN=provider/model   synthesizer (default: user's model)
final class EnsembleGateway: LLMGateway {
    /// LLMGateway is intentionally not globally Sendable (many test doubles
    /// are mutable). The council only shares this immutable reference while
    /// the concrete gateway owns its own synchronization.
    private final class GatewayBox: @unchecked Sendable {
        let value: LLMGateway
        init(_ value: LLMGateway) { self.value = value }
    }

    struct Member: Hashable {
        let provider: LLMProvider
        let modelID: String

        var label: String { "\(provider.label) \(modelID)" }

        /// Parse "deepSeek/deepseek-reasoner" (provider enum rawValue / model id).
        init?(spec: String) {
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let provider = LLMProvider(rawValue: parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            self.provider = provider
            self.modelID = parts[1].trimmingCharacters(in: .whitespaces)
        }

        init(provider: LLMProvider, modelID: String) {
            self.provider = provider
            self.modelID = modelID
        }

        var asLLMModel: LLMModel {
            LLMModel(id: modelID, label: modelID, provider: provider,
                     minTier: .free, supportsVision: false)
        }
    }

    /// Test seams: the parsed panel is what a config typo silently changes, so
    /// it has to be observable without running a council against live models.
    var panelForTesting: [Member] { panel }
    var chairmanForTesting: Member? { chairman }

    private let router: GatewayBox
    private let panel: [Member]
    private let chairman: Member?
    private static let memberTimeout: TimeInterval = 75
    private static let quorum = 2

    init(panelSpec: String = Config.ensemblePanel,
         chairmanSpec: String = Config.ensembleChairman,
         gateway: LLMGateway = LLMRouter()) {
        self.panel = panelSpec.split(separator: ",").compactMap { Member(spec: String($0)) }
        self.chairman = Member(spec: chairmanSpec)
        self.router = GatewayBox(gateway)
    }

    /// Build from resolved members — used by the single-jurisdiction councils,
    /// which pick their panel from the live catalog. Chairman defaults to nil
    /// (same as the unconfigured-chairman path: the strongest member leads).
    init(members: [Member], chairman: Member? = nil,
         gateway: LLMGateway = LLMRouter()) {
        self.panel = members
        self.chairman = chairman
        self.router = GatewayBox(gateway)
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        try await streamChat(system: system, user: user, images: images,
                             model: model, maxOutputTokens: nil, onDelta: onDelta)
    }

    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    maxOutputTokens: Int?,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        // Panel too small (unconfigured / bad spec) → behave like the plain router.
        guard panel.count >= 2 else {
            return try await router.value.streamChat(
                system: system, user: user, images: images, model: model,
                maxOutputTokens: maxOutputTokens, onDelta: onDelta)
        }

        // --- Stage 1: silent parallel fan-out (proposals are not streamed) ---
        let proposals = await withTaskGroup(of: (Member, Result<String, Error>).self) { group in
            for member in panel {
                group.addTask { [router] in
                    do {
                        let text = try await Self.withTimeout(Self.memberTimeout) {
                            // Images only go to vision-capable calls; panel runs text-only
                            // (the chairman sees images through the user's own model).
                            try await router.value.streamChat(
                                system: system, user: user, images: [],
                                model: member.asLLMModel, maxOutputTokens: nil) { _ in }
                        }
                        return (member, .success(text))
                    } catch {
                        return (member, .failure(error))
                    }
                }
            }
            var collected: [(Member, Result<String, Error>)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        let successes = proposals.compactMap { member, result -> (Member, String)? in
            if case .success(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (member, text)
            }
            return nil
        }
        guard successes.count >= Self.quorum else {
            let failures = proposals.compactMap { member, result -> String? in
                if case .failure(let error) = result { return "\(member.label): \(error.localizedDescription)" }
                return nil
            }
            throw LLMError.http("Ensemble", 502,
                                "Only \(successes.count)/\(panel.count) panel members answered (need \(Self.quorum)). "
                                + failures.joined(separator: " | ").prefix(400))
        }

        // --- Stage 2: chairman synthesis, streamed to the caller ---
        let chairmanModel = chairman?.asLLMModel ?? model
        let synthesisSystem = """
        \(system)

        You are the chairman of a model council. Independent AI models from \
        different countries and training traditions each answered the user's \
        request. Synthesize ONE final answer: keep points the panel agrees on, \
        reconcile or flag material disagreements (briefly, e.g. "the panel was \
        split on …"), drop hallucinations that only one model produced unless \
        well-grounded. Do NOT mention model names or that a council exists \
        beyond such brief split-notes. Answer in the user's language.
        """
        let proposalsBlock = successes.enumerated().map { index, item in
            "=== Council member \(index + 1) (\(item.0.label)) ===\n\(item.1)"
        }.joined(separator: "\n\n")
        let synthesisUser = """
        Original request:
        \(user)

        Council answers:
        \(proposalsBlock)
        """

        return try await router.value.streamChat(
            system: synthesisSystem, user: synthesisUser, images: images,
            model: chairmanModel, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
    }

    /// Race the operation against a deadline.
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LLMError.http("Ensemble", 408, "panel member timed out after \(Int(seconds))s")
            }
            guard let first = try await group.next() else {
                throw LLMError.badResponse("Ensemble")
            }
            group.cancelAll()
            return first
        }
    }
}
