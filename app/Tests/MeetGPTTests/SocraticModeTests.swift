import Foundation
import Testing
@testable import MeetGPT

/// A mode that answers with questions.
///
/// The backlog item said to settle one thing first — whether this is an answer
/// style or a separate mode — because building it twice is the failure case.
/// `AnswerStyle` answers it in its own doc comment: a style adjusts DELIVERY and
/// never the contract, and every style still answers the question. Socratic
/// withholds the answer. `socraticIsNotAnAnswerStyle` pins that decision so the
/// next person does not relitigate it.
///
/// The rest of these are about the three things the acceptance criteria asked
/// for, all of which exist because a mode that withholds answers is one bad
/// edge away from looking like a broken product.
@Suite("Socratic mode")
struct SocraticModeTests {

    // MARK: - The design decision

    @Test("socratic is not an answer style")
    func socraticIsNotAnAnswerStyle() {
        // If this ever fails, someone added it to AnswerStyle — which would
        // apply it to fact checks, agendas and DACIs, whose output shape is a
        // contract. A Socratic fact check is not a shorter fact check; it is a
        // fact check that does not return a verdict.
        #expect(!AnswerStyle.allCases.contains { $0.rawValue.lowercased().contains("socratic") })
    }

    @Test("styles still answer, which is why they are safe everywhere")
    func stylesNeverWithhold() {
        // The invariant that separates the two concepts, checked rather than
        // asserted in prose: no style's instruction tells the model not to
        // answer.
        for style in AnswerStyle.allCases {
            #expect(!style.instruction.lowercased().contains("do not state the answer"))
        }
    }

    // MARK: - The bound

    @Test("withholds up to the limit, then stops")
    func boundIsEnforced() {
        for exchanges in 0..<SocraticMode.maxExchangesIdle {
            #expect(SocraticMode.shouldWithholdAnswer(exchangesSoFar: exchanges,
                                                      isRecording: false))
        }
        // An unbounded Socratic mode is indistinguishable from a broken
        // assistant: you ask, you get a question, and nothing tells you whether
        // the product is thinking or failing.
        #expect(!SocraticMode.shouldWithholdAnswer(
            exchangesSoFar: SocraticMode.maxExchangesIdle, isRecording: false))
    }

    @Test("the bound is tighter while a call is live")
    func tighterWhileRecording() {
        // The cost of withholding is not the user's alone during a call — other
        // people are waiting on them. A copilot that meets "what was their ARR?"
        // with "what makes ARR the right measure?" mid-call is actively harmful.
        #expect(SocraticMode.maxExchangesRecording < SocraticMode.maxExchangesIdle)
        #expect(SocraticMode.exchangeLimit(isRecording: true)
                < SocraticMode.exchangeLimit(isRecording: false))
    }

    @Test("one exchange in, a live call already answers plainly")
    func liveCallStopsAfterOne() {
        #expect(SocraticMode.shouldWithholdAnswer(exchangesSoFar: 0, isRecording: true))
        #expect(!SocraticMode.shouldWithholdAnswer(exchangesSoFar: 1, isRecording: true))
    }

    @Test("a negative count never withholds")
    func negativeCountIsSafe() {
        #expect(!SocraticMode.shouldWithholdAnswer(exchangesSoFar: -1, isRecording: false))
    }

    // MARK: - Scope

    @Test("structured prompts are never made socratic", arguments: [
        "factcheck", "agenda", "brainstorm", "unresolved", "whattoask",
    ])
    func structuredPromptsExcluded(promptID: String) {
        // These have a required output shape. Replacing an agenda with questions
        // does not make a Socratic agenda, it makes a broken one.
        #expect(!SocraticMode.applies(toBuiltInPromptID: promptID))
    }

    @Test("free-form asks are in scope")
    func freeformIncluded() {
        #expect(SocraticMode.applies(toBuiltInPromptID: nil))
    }

    // MARK: - Applying it

    @Test("off by default: the prompt is untouched")
    func disabledLeavesPromptAlone() {
        let prompt = "Should we move the launch to September?"
        #expect(SocraticMode.applied(to: prompt, enabled: false, exchangesSoFar: 0,
                                     isRecording: false, brokenOut: false) == prompt)
    }

    @Test("breaking out returns the plain prompt")
    func brokenOutLeavesPromptAlone() {
        let prompt = "Should we move the launch to September?"
        #expect(SocraticMode.applied(to: prompt, enabled: true, exchangesSoFar: 0,
                                     isRecording: false, brokenOut: true) == prompt)
    }

    @Test("past the bound, the prompt is untouched")
    func spentBoundLeavesPromptAlone() {
        let prompt = "Should we move the launch to September?"
        #expect(SocraticMode.applied(to: prompt, enabled: true, exchangesSoFar: 99,
                                     isRecording: false, brokenOut: false) == prompt)
    }

    @Test("when it applies, the original question survives intact")
    func promptIsAppendedNotReplaced() {
        // The model still needs to know what was asked. Replacing the prompt
        // with the instruction would produce questions about nothing.
        let prompt = "Should we move the launch to September?"
        let result = SocraticMode.applied(to: prompt, enabled: true, exchangesSoFar: 0,
                                          isRecording: false, brokenOut: false)
        #expect(result.contains(prompt))
        #expect(result.contains(SocraticMode.instruction))
    }

    @Test("the instruction carves out matters of fact")
    func factsAreStillAnswered() {
        // The interviewer's posture is for judgement calls. Meeting "what time
        // is the review?" with a question about premises is not thoughtful.
        #expect(SocraticMode.instruction.lowercased().contains("matter of fact"))
    }

    @Test("the instruction forbids hinting rather than only stating")
    func noHinting() {
        // Without this a model asks leading questions that telegraph the answer,
        // which is the worst of both: no answer AND no thinking.
        #expect(SocraticMode.instruction.lowercased().contains("hint"))
    }
}

/// Socratic mode as the user meets it: a toggle, a counter, and a way out.
@MainActor
@Suite("Socratic mode in the app")
struct SocraticModeAppStateTests {

    private func state(recording: Bool = false) -> AppState {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(recording: recording)
        return state
    }

    @Test("off by default")
    func offByDefault() {
        // It changes whether you get an answer at all, so it must be switched on
        // deliberately rather than lie in wait from a setting changed last week.
        #expect(!state().socraticModeEnabled)
    }

    @Test("the indicator says what the next ask will do")
    func indicatorReflectsNextAsk() {
        // "Never a silent behaviour change" means visible BEFORE sending, not
        // discovered in the reply.
        let appState = state()
        #expect(!appState.socraticWillWithhold)
        appState.socraticModeEnabled = true
        #expect(appState.socraticWillWithhold)
    }

    @Test("toggling resets the bound")
    func togglingResets() {
        // Otherwise switching off and on again silently inherits a spent bound,
        // and the mode appears not to work.
        let appState = state()
        appState.socraticModeEnabled = true
        appState.answerPlainlyNext()
        #expect(appState.socraticBrokenOut)

        appState.socraticModeEnabled = false
        appState.socraticModeEnabled = true
        #expect(!appState.socraticBrokenOut)
        #expect(appState.socraticExchanges == 0)
    }

    @Test("breaking out does not switch the mode off")
    func breakoutKeepsTheMode() {
        // Making the escape hatch also disable the feature would punish using
        // it. The user wants this answer plainly, not a different product.
        let appState = state()
        appState.socraticModeEnabled = true
        appState.answerPlainlyNext()
        #expect(appState.socraticModeEnabled)
        #expect(!appState.socraticWillWithhold)
    }

    @Test("breaking out while the mode is off does nothing")
    func breakoutRequiresTheMode() {
        let appState = state()
        appState.answerPlainlyNext()
        #expect(!appState.socraticBrokenOut)
    }

    @Test("the remaining count is tighter during a call")
    func remainingIsTighterLive() {
        let idle = state()
        idle.socraticModeEnabled = true
        let live = state(recording: true)
        live.socraticModeEnabled = true
        #expect(live.socraticRemainingExchanges < idle.socraticRemainingExchanges)
    }

    @Test("no notice until the bound is actually spent")
    func noticeOnlyWhenRelevant() {
        // A banner on every turn trains people to ignore it, which is exactly
        // when it needs to be read.
        let appState = state()
        appState.socraticModeEnabled = true
        #expect(appState.socraticNotice == nil)
    }
}
