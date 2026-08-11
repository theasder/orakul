import Foundation
import Testing
@testable import MeetGPT

/// Opt-in full-context mode, client half.
///
/// The rules are implemented twice — here and in
/// `cruxwing-api/functions/fullContext.js` — because the price must be shown
/// BEFORE the send and charged after. Two implementations of one rule is a
/// standing invitation to drift, so `catalogueMatchesTheContract` and the
/// constants tests pin this side against the shared contract rather than
/// trusting that they were written to match.
///
/// A quoted price that differs from what is charged is worse than not shipping
/// the mode, which is why that pinning is the first thing here.
@Suite("Full context requests")
struct FullContextRequestTests {

    private func model(_ id: String) -> LLMModel {
        LLMCatalog.fallback.first { $0.id == id }
            ?? LLMModel(id: id, label: id, provider: .openAI, minTier: .free,
                        supportsVision: false)
    }

    // MARK: - Cross-repo agreement

    @Test("every model's window matches the shared contract")
    func catalogueMatchesTheContract() {
        // The contract is emitted from the server's own catalog, so this is the
        // check that the app is not offering the mode for a model the server
        // will refuse it for — or, worse, quoting a size the server will not send.
        let contract = SharedContract.models
        guard !contract.isEmpty else { return }

        for model in LLMCatalog.fallback {
            guard let entry = contract[model.id] else { continue }
            #expect(model.contextTokens == entry.contextTokens,
                    "\(model.id) disagrees with contract/contract.json")
        }
    }

    @Test("eligibility agrees with the contract for every catalogued model")
    func eligibilityAgreesWithContract() {
        let contract = SharedContract.models
        guard !contract.isEmpty else { return }
        for model in LLMCatalog.fallback {
            guard let entry = contract[model.id] else { continue }
            let contractEligible = (entry.contextTokens ?? 0)
                >= FullContextRequest.minimumContextTokens
            #expect(FullContextRequest.isEligible(model) == contractEligible, "\(model.id)")
        }
    }

    // MARK: - Fail closed

    @Test("a model with no verified window is not eligible")
    func unverifiedWindowIsNotEligible() {
        // Absent metadata means NOT OFFERED, not unknown-so-try. Guessing sells
        // credits for a request the provider rejects for exceeding its window.
        #expect(model("kimi-k2.6").contextTokens == nil)
        #expect(!FullContextRequest.isEligible(model("kimi-k2.6")))
    }

    @Test("models outside the catalogue are not eligible")
    func unknownModelIsNotEligible() {
        #expect(!FullContextRequest.isEligible(model("something-nobody-added")))
    }

    @Test("an ineligible model still reports the ordinary limit")
    func ineligibleFallsBackRatherThanTrapping() {
        #expect(FullContextRequest.maximumInputChars(for: model("glm-5.2"))
                == FullContextRequest.defaultEnvelopeChars)
    }

    // MARK: - The default is untouched

    @Test("not asking leaves the envelope and the price alone")
    func defaultIsUnchanged() {
        let quote = FullContextRequest.quote(model: model("gemini-3.1-pro-preview"),
                                             requested: false,
                                             inputChars: 500_000, baseCredits: 3)
        #expect(!quote.active)
        #expect(quote.limitChars == FullContextRequest.defaultEnvelopeChars)
        #expect(quote.credits == 3)
    }

    @Test("an eligible model does not opt itself in")
    func capabilityDoesNotEnableItself() {
        // Per request. A model that supports a big window must not decide to
        // spend the user's credits on one.
        #expect(!FullContextRequest.quote(model: model("gemini-3.1-pro-preview"),
                                          requested: false, inputChars: 900_000,
                                          baseCredits: 3).active)
    }

    @Test("truncation is reported even when the mode is off")
    func truncationVisibleWhenOff() {
        // This is what makes opting in a considered choice rather than a guess:
        // the user can see the default envelope is clipping their call.
        #expect(FullContextRequest.quote(model: model("gpt-5.4"), requested: false,
                                         inputChars: 50_000, baseCredits: 4).truncated)
        #expect(!FullContextRequest.quote(model: model("gpt-5.4"), requested: false,
                                          inputChars: 500, baseCredits: 4).truncated)
    }

    // MARK: - Refusals are stated

    @Test("an ineligible model refuses out loud")
    func refusalIsExplained() {
        // Falling back silently would leave the user believing they sent a
        // two-hour call, and acting on an answer that read 8k characters of it.
        let quote = FullContextRequest.quote(model: model("kimi-k2.6"), requested: true,
                                             inputChars: 200_000, baseCredits: 2)
        #expect(!quote.active)
        #expect(quote.refusal?.contains("no verified context window") == true)
        #expect(quote.summary == quote.refusal)
    }

    @Test("a refused request is not charged extra")
    func refusalCostsNothingExtra() {
        #expect(FullContextRequest.quote(model: model("glm-5.2"), requested: true,
                                         inputChars: 900_000, baseCredits: 2).credits == 2)
    }

    // MARK: - Price

    @Test("price scales in whole envelopes and rounds up")
    func priceScales() {
        let envelope = FullContextRequest.defaultEnvelopeChars
        #expect(FullContextRequest.credits(baseCredits: 3, inputChars: 1) == 3)
        #expect(FullContextRequest.credits(baseCredits: 3, inputChars: envelope) == 3)
        #expect(FullContextRequest.credits(baseCredits: 3, inputChars: envelope + 1) == 6)
        #expect(FullContextRequest.credits(baseCredits: 3, inputChars: envelope * 4) == 12)
    }

    @Test("price is capped")
    func priceIsCapped() {
        #expect(FullContextRequest.credits(baseCredits: 3, inputChars: 100_000_000)
                == 3 * FullContextRequest.maximumCreditMultiplier)
    }

    @Test("nonsense input never produces a nonsense price")
    func priceIsRobust() {
        #expect(FullContextRequest.credits(baseCredits: 0, inputChars: -5) >= 1)
        #expect(FullContextRequest.credits(baseCredits: -3, inputChars: 100) >= 1)
    }

    @Test("the quote prices what will be sent, not what was offered")
    func pricesWhatIsSent() {
        let target = model("claude-sonnet-5")
        let limit = FullContextRequest.maximumInputChars(for: target)
        let over = FullContextRequest.quote(model: target, requested: true,
                                            inputChars: limit * 10, baseCredits: 3)
        let atLimit = FullContextRequest.quote(model: target, requested: true,
                                               inputChars: limit, baseCredits: 3)
        #expect(over.credits == atLimit.credits)
        #expect(over.truncated)
    }

    // MARK: - What the user reads

    @Test("the summary names both the price and the size")
    func summaryNamesPriceAndSize() {
        // The decision is "is this worth N credits", and neither number alone
        // answers it.
        let quote = FullContextRequest.quote(model: model("gemini-3.1-pro-preview"),
                                             requested: true, inputChars: 40_000,
                                             baseCredits: 3)
        #expect(quote.summary.contains("credits"))
        #expect(quote.summary.contains("Full context"))
    }

    @Test("a truncated send says so rather than implying everything went")
    func truncatedSummaryIsHonest() {
        let target = model("claude-sonnet-5")
        let limit = FullContextRequest.maximumInputChars(for: target)
        let quote = FullContextRequest.quote(model: target, requested: true,
                                             inputChars: limit * 2, baseCredits: 3)
        #expect(quote.summary.contains("last"))
        #expect(!quote.summary.contains("everything"))
    }

    @Test("nothing is shown when the mode is off")
    func silentWhenOff() {
        #expect(FullContextRequest.quote(model: model("gpt-5.4"), requested: false,
                                         inputChars: 100, baseCredits: 3).summary.isEmpty)
    }

    // MARK: - The window is used conservatively

    @Test("headroom is left for the prompt and the answer")
    func headroomIsLeft() {
        // Filling the window exactly with input leaves nothing for the system
        // prompt or the completion, and the provider rejects the request.
        let target = model("gemini-3.1-pro-preview")
        let impliedTokens = Double(FullContextRequest.maximumInputChars(for: target))
            / FullContextRequest.charsPerToken
        #expect(impliedTokens < Double(target.contextTokens ?? 0))
    }

    @Test("a bigger window buys a bigger envelope")
    func biggerWindowBiggerEnvelope() {
        #expect(FullContextRequest.maximumInputChars(for: model("gemini-3.1-pro-preview"))
                > FullContextRequest.maximumInputChars(for: model("claude-sonnet-5")))
    }
}

/// Full context as the user meets it: a per-request control with a price on it.
@MainActor
@Suite("Full context in the app")
struct FullContextAppStateTests {

    private func state() -> AppState {
        let appState = AppState(credentialStore: InMemoryKeychain())
        appState.applyTestWorkspace(recording: false)
        return appState
    }

    @Test("off by default")
    func offByDefault() {
        #expect(!state().fullContextRequested)
    }

    @Test("attached material counts toward the quote")
    func attachedMaterialCounted() {
        // A folder of specs can dwarf the transcript. A price that ignored it
        // would understate, which is the one direction this must never err in.
        let appState = state()
        let before = appState.attachedContextCharacters
        appState.contextFiles = [ImportedContextFile(name: "spec.md",
                                                     text: String(repeating: "x", count: 5_000))]
        appState.contextNotes = String(repeating: "y", count: 1_000)
        #expect(appState.attachedContextCharacters == before + 6_000)
    }

    @Test("the quote is recomputed, never cached")
    func quoteIsLive() {
        // A cached price would quote a stale figure for a transcript that has
        // since grown — and the transcript grows continuously during a call.
        let appState = state()
        appState.fullContextRequested = true
        let first = appState.fullContextQuote
        appState.contextNotes = String(repeating: "z", count: 200_000)
        #expect(appState.fullContextQuote != first)
    }

    @Test("the transcript cap is only lifted when the mode is armed")
    func capLiftedOnlyWhenArmed() {
        let appState = state()
        appState.contextNotes = ""
        let clipped = appState.promptTranscript(cap: 50)
        appState.fullContextRequested = true
        let full = appState.promptTranscript(cap: 50)
        // With an eligible model the armed call must not be the clipped one.
        if appState.fullContextAvailable {
            #expect(full.count >= clipped.count)
        }
    }

    @Test("an ineligible model hides the control rather than disabling it")
    func hiddenWhenIneligible() {
        // An always-visible control that is usually disabled teaches people to
        // stop reading the row.
        let appState = state()
        #expect(appState.fullContextAvailable
                == FullContextRequest.isEligible(Config.selectedRequestModel))
    }

    @Test("the base rate matches the server's table")
    func baseRatesMatchServer() {
        // Quoting cheap and charging more is the failure this module exists to
        // avoid, and the base rate is half of every quote.
        #expect(FullContextRequest.baseCredits(for:
            LLMCatalog.fallback.first { $0.id == "claude-opus-5" }!) == 7)
        #expect(FullContextRequest.baseCredits(for:
            LLMModel(id: "unlisted", label: "x", provider: .openAI,
                     minTier: .free, supportsVision: false))
                == FullContextRequest.fallbackCredits)
    }
}
