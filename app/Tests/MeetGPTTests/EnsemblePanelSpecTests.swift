import Foundation
import Testing
@testable import MeetGPT

/// Parsing the council panel out of configuration.
///
/// `ENSEMBLE_PANEL=provider/model,provider/model,…` decides who sits on the
/// council — the most expensive thing the product runs (24–38 credits a call,
/// several frontier providers per request). The parse is `compactMap`, so a
/// malformed entry is not an error: it silently drops that member. A typo in a
/// deployment's env therefore produces a quieter, weaker council that still
/// bills as a council, with nothing anywhere saying so.
///
/// Layered on one base fact — a well-formed spec yields its member — with each
/// later test covering a way real configuration goes wrong.
@Suite("Ensemble panel spec")
struct EnsemblePanelSpecTests {

    private typealias Member = EnsembleGateway.Member

    // MARK: - Base

    @Test("a well-formed spec yields its provider and model")
    func parsesAValidSpec() throws {
        let member = try #require(Member(spec: "openAI/gpt-5.4"))
        #expect(member.provider == .openAI)
        #expect(member.modelID == "gpt-5.4")
    }

    // MARK: - Layer: how real config is written

    @Test("surrounding whitespace is tolerated on both halves")
    func toleratesWhitespace() throws {
        // Panels are comma-separated in a .env line, so entries after the first
        // routinely arrive with a leading space.
        for spec in [" openAI/gpt-5.4", "openAI /gpt-5.4", "openAI/ gpt-5.4", " openAI / gpt-5.4 "] {
            let member = try #require(Member(spec: spec), "rejected: \(spec.debugDescription)")
            #expect(member.provider == .openAI)
            #expect(member.modelID == "gpt-5.4", "model mangled from \(spec.debugDescription)")
        }
    }

    @Test("a model id containing a slash keeps everything after the first one")
    func keepsSlashesInModelID() throws {
        // Vendor-qualified ids are common on aggregating endpoints
        // ("meta/llama-4"). Splitting on every slash would truncate the model
        // to "meta" and route to something that does not exist.
        let member = try #require(Member(spec: "moonshot/meta/llama-4-70b"))
        #expect(member.provider == .moonshot)
        #expect(member.modelID == "meta/llama-4-70b")
    }

    // MARK: - Layer: what must be rejected rather than half-accepted

    @Test("an unknown provider is rejected, not coerced")
    func rejectsUnknownProviders() {
        // Silently defaulting to some provider would send the request — and the
        // bill — somewhere the operator never chose.
        #expect(Member(spec: "notAProvider/gpt-5.4") == nil)
        #expect(Member(spec: "OPENAI/gpt-5.4") == nil, "provider match is case-sensitive by rawValue")
        #expect(Member(spec: "open ai/gpt-5.4") == nil)
    }

    @Test("a spec without both halves is rejected")
    func rejectsMalformedSpecs() {
        for spec in ["", "   ", "openAI", "openAI/", "/gpt-5.4", "/", "gpt-5.4"] {
            #expect(Member(spec: spec) == nil, "accepted malformed spec: \(spec.debugDescription)")
        }
    }

    // MARK: - Layer: the whole panel, as the gateway builds it

    @Test("a panel string yields one member per valid entry")
    func parsesAWholePanel() {
        let gateway = EnsembleGateway(
            panelSpec: "openAI/gpt-5.4, anthropic/claude-sonnet-5, deepSeek/deepseek-v4-pro",
            chairmanSpec: "openAI/gpt-5.4")
        #expect(gateway.panelForTesting.count == 3)
        #expect(gateway.panelForTesting.map(\.provider) == [.openAI, .anthropic, .deepSeek])
        #expect(gateway.chairmanForTesting?.provider == .openAI)
    }

    @Test("one bad entry costs only that seat — the rest of the council still sits")
    func oneBadEntryDoesNotEmptyThePanel() {
        // compactMap's behaviour, pinned deliberately: a typo must not take the
        // whole council down, but it does quietly shrink it.
        let gateway = EnsembleGateway(
            panelSpec: "openAI/gpt-5.4, typo-here, anthropic/claude-sonnet-5",
            chairmanSpec: "")
        #expect(gateway.panelForTesting.count == 2)
        #expect(gateway.chairmanForTesting == nil, "an unparseable chairman is simply absent")
    }

    @Test("an entirely unparseable panel yields no members, not a phantom one")
    func fullyBadPanelIsEmpty() {
        let gateway = EnsembleGateway(panelSpec: "nonsense,,   ,also/nonsense", chairmanSpec: "")
        #expect(gateway.panelForTesting.isEmpty)
    }

    // MARK: - Layer: what a member becomes downstream

    @Test("a member renders a readable label and maps to a routable model")
    func memberProjections() throws {
        let member = try #require(Member(spec: "anthropic/claude-sonnet-5"))
        #expect(member.label.contains("claude-sonnet-5"))
        let model = member.asLLMModel
        #expect(model.id == "claude-sonnet-5")
        #expect(model.provider == .anthropic)
        // Panel members are routed directly, so they must not be gated by tier.
        #expect(model.minTier == .free)
    }

    @Test("members with the same provider and model are the same member")
    func membersDeduplicateByIdentity() throws {
        // Hashable is what stops a duplicated env entry from paying twice for
        // the same model's opinion.
        let a = try #require(Member(spec: "openAI/gpt-5.4"))
        let b = try #require(Member(spec: " openAI / gpt-5.4 "))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)

        let other = try #require(Member(spec: "openAI/gpt-5.5"))
        #expect(Set([a, other]).count == 2)
    }

    @Test("the shipped default panel parses to a real council")
    func defaultPanelIsUsable() {
        // The default is a literal in Config; a typo there ships a council of
        // one to every install that never sets ENSEMBLE_PANEL.
        let gateway = EnsembleGateway(panelSpec: Config.ensemblePanel, chairmanSpec: "")
        #expect(gateway.panelForTesting.count >= 2,
                "default panel parsed to \(gateway.panelForTesting.count) member(s): \(Config.ensemblePanel)")
    }
}
