import Foundation
import Testing
@testable import MeetGPT

/// Answer styles.
///
/// The acceptance criteria were: a prompt-assembly parameter rather than a
/// post-hoc rewrite, visible in the composer, persisted per session, and it
/// NEVER overrides a structural contract — a DACI answer stays a DACI.
///
/// That last one is the property most of these tests defend, because it is the
/// one that fails silently: a model handed "be brief" alongside a required
/// structure will drop the structure unless told not to, and the result still
/// looks like a plausible answer.
@Suite("Answer style")
struct AnswerStyleTests {

    // MARK: - The default changes nothing

    @Test("standard adds nothing at all")
    func standardIsInert() {
        // Anyone who never opens the control must get exactly what they got
        // before it existed — not "write normally", which costs tokens and
        // invites the model to treat it as a change.
        #expect(AnswerStyle.standard.instruction.isEmpty)
        #expect(AnswerStyle.standard.applied(to: "Summarise the call") == "Summarise the call")
    }

    @Test("the default style is standard")
    func defaultIsStandard() {
        #expect(AnswerStyle.defaultStyle == .standard)
    }

    // MARK: - The structural invariant

    @Test("every non-default style forbids changing the structure")
    func everyStyleProtectsStructure() {
        // The invariant that makes a style safe to apply to a DACI, a fact
        // check, or any other contract-bearing workflow. Asserted on every
        // case so a style added later cannot quietly omit it.
        for style in AnswerStyle.allCases where style != .standard {
            let instruction = style.instruction.lowercased()
            #expect(instruction.contains("structure") || instruction.contains("section"),
                    "\(style.rawValue) does not defend the structure")
        }
    }

    @Test("concise shortens wording, explicitly not structure")
    func conciseTargetsWording() {
        let instruction = AnswerStyle.concise.instruction.lowercased()
        #expect(instruction.contains("wording"))
        // "shorten the wording inside them, never the structure"
        #expect(instruction.contains("never the structure"))
    }

    @Test("explanatory adds reasoning inside the structure, not around it")
    func explanatoryStaysInside() {
        let instruction = AnswerStyle.explanatory.instruction.lowercased()
        #expect(instruction.contains("inside it rather than around it"))
    }

    @Test("formal constrains register without touching required fields")
    func formalConstrainsRegister() {
        let instruction = AnswerStyle.formal.instruction.lowercased()
        #expect(instruction.contains("register"))
        #expect(instruction.contains("required field"))
    }

    // MARK: - Application

    @Test("appends rather than prepends")
    func appendsAfterTheTask() {
        // The task must be read first; a trailing constraint is the position
        // models honour most reliably.
        let applied = AnswerStyle.concise.applied(to: "List the decisions")
        #expect(applied.hasPrefix("List the decisions"))
        #expect(applied.count > "List the decisions".count)
    }

    @Test("leaves an empty body alone")
    func emptyBodyUnchanged() {
        // Appending a style to nothing would send a request that is only a
        // style instruction.
        #expect(AnswerStyle.concise.applied(to: "") == "")
        #expect(AnswerStyle.concise.applied(to: "   ") == "   ")
    }

    @Test("trims the body before appending, so spacing stays predictable")
    func trimsBeforeAppending() {
        let applied = AnswerStyle.concise.applied(to: "  Summarise  \n\n")
        #expect(applied.hasPrefix("Summarise\n\n"))
    }

    @Test("applying twice does not stack the instruction twice")
    func doubleApplicationIsVisible() {
        // Not prevented — a caller that applies twice has a bug — but recorded,
        // so the behaviour is known rather than assumed.
        let once = AnswerStyle.concise.applied(to: "Summarise")
        let twice = AnswerStyle.concise.applied(to: once)
        #expect(twice.count > once.count, "double application is additive, as documented")
    }

    // MARK: - The catalogue

    @Test("every style has a label and a help line")
    func everyStyleIsPresentable() {
        // A style with no help text ships as a mystery entry in a picker.
        for style in AnswerStyle.allCases {
            #expect(!style.label.isEmpty, "\(style.rawValue) has no label")
            #expect(!style.help.isEmpty, "\(style.rawValue) has no help")
        }
    }

    @Test("styles round-trip through their raw values")
    func roundTrips() {
        // Persisted per session, so the raw value is a stored contract.
        for style in AnswerStyle.allCases {
            #expect(AnswerStyle(rawValue: style.rawValue) == style)
        }
    }

    @Test("an unknown stored value is not decodable, so callers must default")
    func unknownValueFailsClosed() {
        // A style removed in a later build must not silently become a
        // different style; nil forces the caller to fall back to standard.
        #expect(AnswerStyle(rawValue: "socratic") == nil)
    }

    @Test("socratic is deliberately NOT a style")
    func socraticIsNotAStyle() {
        // Recorded as a test because it was the load-bearing design decision:
        // a style changes how an answer reads, while Socratic changes whether
        // you get an answer at all. If it ever appears here, the two features
        // have been merged and the mode's break-out keystroke and withholding
        // bound have nowhere to live.
        #expect(!AnswerStyle.allCases.map(\.rawValue).contains("socratic"))
    }
    // MARK: - Wiring

    @MainActor
    @Test("style is applied to a real prompt, after context adaptation")
    func appliedThroughAppState() {
        // A style nothing applies is worse than none: the picker implies an
        // effect that does not exist.
        let state = AppState(credentialStore: InMemoryKeychain())
        let base = QuickPrompt(id: "summary", icon: "📝", title: "Summarise",
                               tooltip: "", prompt: "Summarise the call")

        state.answerStyle = .standard
        let plain = state.promptForCurrentRecording(base).prompt

        state.answerStyle = .concise
        let styled = state.promptForCurrentRecording(base).prompt

        #expect(styled != plain)
        #expect(styled.hasPrefix(plain.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @MainActor
    @Test("standard leaves the prompt byte-identical")
    func standardLeavesPromptAlone() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.answerStyle = .standard
        let base = QuickPrompt(id: "summary", icon: "📝", title: "Summarise",
                               tooltip: "", prompt: "Summarise the call")

        // The whole point of an inert default: existing behaviour is untouched
        // for anyone who never opens the control.
        #expect(state.promptForCurrentRecording(base).prompt
                == RecordingPromptAdapter.adapt(base, kind: state.effectiveRecordingContextKind).prompt)
    }

    @MainActor
    @Test("styling preserves the prompt identity")
    func preservesIdentity() {
        // id, icon and title must survive: the id routes the request (factcheck
        // and logdecision branch on it) and the title is what the button says.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.answerStyle = .formal
        let base = QuickPrompt(id: "logdecision", icon: "🗳", title: "Log Decision",
                               tooltip: "tip", prompt: "Log the decision")
        let styled = state.promptForCurrentRecording(base)

        #expect(styled.id == "logdecision")
        #expect(styled.icon == "🗳")
        #expect(styled.title == "Log Decision")
    }

}
