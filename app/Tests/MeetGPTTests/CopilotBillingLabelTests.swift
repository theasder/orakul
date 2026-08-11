import Foundation
import Testing
@testable import MeetGPT

/// Which credit pool a background watch bills to.
///
/// The agenda, rhetoric and facilitation watches reach the backend through the
/// same `/api/llm/chat` endpoint a user's own prompt uses. Unlabelled, they
/// classify as CLOUD — 15 credits a month on Free, shared with streamed
/// transcription — so three watches on a 300 s cadence emptied a free user's
/// entire monthly cloud allowance in about thirteen minutes of one call, while
/// the 210-credit copilot pool those loops exist to spend sat untouched.
///
/// The label is carried by a task-local rather than a parameter because it
/// concerns BILLING, not generation: threading it through `LLMGateway` would
/// touch every conformer and every mock to carry a value one gateway reads.
/// That choice is only safe if the value actually reaches the request, which is
/// what this suite pins.
@Suite("Copilot billing label")
struct CopilotBillingLabelTests {

    // MARK: - Base

    @Test("a labelled call carries its watch for the duration of the body")
    func labelIsVisibleInsideTheBody() async {
        #expect(CopilotBilling.watch == nil, "no label outside a labelled call")
        await CopilotBilling.labelled(.agenda) {
            #expect(CopilotBilling.watch == .agenda)
        }
        #expect(CopilotBilling.watch == nil, "the label must not outlive the call")
    }

    // MARK: - Layer: the reason it is a task-local at all

    @Test("the label reaches a child task")
    func labelPropagatesToChildTasks() async {
        // The gateway does its work in a child task, so a value that did not
        // propagate would be read as nil exactly where it is needed — the
        // failure would be invisible and would bill the wrong pool.
        await CopilotBilling.labelled(.rhetoric) {
            async let inner: Void = {
                #expect(CopilotBilling.watch == .rhetoric)
            }()
            await inner
        }
    }

    @Test("the label survives an await inside the body")
    func labelSurvivesSuspension() async {
        // Every real call suspends on the network between being labelled and
        // building its payload.
        await CopilotBilling.labelled(.facilitation) {
            try? await Task.sleep(nanoseconds: 1_000_000)
            #expect(CopilotBilling.watch == .facilitation)
        }
    }

    @Test("nested labels apply the innermost, then restore the outer")
    func nestedLabelsRestore() async {
        await CopilotBilling.labelled(.agenda) {
            #expect(CopilotBilling.watch == .agenda)
            await CopilotBilling.labelled(.rhetoric) {
                #expect(CopilotBilling.watch == .rhetoric)
            }
            #expect(CopilotBilling.watch == .agenda, "the outer label was lost")
        }
    }

    @Test("a throwing body still clears the label")
    func labelClearsOnThrow() async {
        struct Boom: Error {}
        _ = try? await CopilotBilling.labelled(.agenda) { throw Boom() }
        #expect(CopilotBilling.watch == nil, "a failed watch left its label behind")
    }

    @Test("a labelled call returns its body's value unchanged")
    func labelIsTransparentToTheResult() async {
        let value = await CopilotBilling.labelled(.agenda) { 42 }
        #expect(value == 42)
    }

    // MARK: - Layer: the contract with the server

    @Test("the three watch names match exactly what the server will honour")
    func rawValuesMatchTheServerAllowlist() {
        // The server allowlists these three strings and falls back to `chat`
        // for anything else. A rename here would not error — it would silently
        // bill the expensive pool again, which is the original bug returning.
        #expect(Set(CopilotBilling.Watch.allCases.map(\.rawValue))
                == ["agenda", "rhetoric", "facilitation"])
    }

    @Test("brainstorm and factcheck are deliberately absent")
    func onlyChatTransportedWatchesAreLabelled() {
        // Those two have their own endpoints and are already billed correctly.
        // Adding them here would double-label work the server meters elsewhere.
        let names = Set(CopilotBilling.Watch.allCases.map(\.rawValue))
        #expect(!names.contains("brainstorm"))
        #expect(!names.contains("factcheck"))
        #expect(!names.contains("chat"))
    }

    @Test("a user's own prompt is unlabelled, which is what makes it chat")
    func unlabelledIsChat() {
        // The absence of a label is meaningful: it is how the server tells a
        // person typing from a background loop. Defaulting to a watch would
        // route a frontier-model prompt into the cheap pool — the arbitrage the
        // server's second gate exists to refuse.
        #expect(CopilotBilling.watch == nil)
    }

    @Test("every watch case is reachable and distinct")
    func casesAreDistinct() async {
        for watch in CopilotBilling.Watch.allCases {
            await CopilotBilling.labelled(watch) {
                #expect(CopilotBilling.watch == watch)
            }
        }
        #expect(Set(CopilotBilling.Watch.allCases).count == CopilotBilling.Watch.allCases.count)
    }
}
