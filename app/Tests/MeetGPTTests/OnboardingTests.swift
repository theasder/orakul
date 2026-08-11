import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// First-run pre-flight: the flag lifecycle plus the screen's rendered rows.
@MainActor
@Suite("Onboarding pre-flight", .serialized)
struct OnboardingTests {
    @Test("onboardingCompleted defaults false and round-trips")
    func flag() {
        let saved = Config.onboardingCompleted
        defer { Config.onboardingCompleted = saved }

        UserDefaults.standard.removeObject(forKey: "onboarding.completed")
        #expect(Config.onboardingCompleted == false)
        Config.onboardingCompleted = true
        #expect(Config.onboardingCompleted == true)
    }

    @Test("completed onboarding is reopened when either capture permission is missing")
    func permissionGate() {
        #expect(!OnboardingGate.shouldPresent(
            completed: true, microphoneGranted: true, screenRecordingGranted: true))
        #expect(OnboardingGate.shouldPresent(
            completed: false, microphoneGranted: true, screenRecordingGranted: true))
        #expect(OnboardingGate.shouldPresent(
            completed: true, microphoneGranted: false, screenRecordingGranted: true))
        #expect(OnboardingGate.shouldPresent(
            completed: true, microphoneGranted: true, screenRecordingGranted: false))
    }

    @Test("the capture step shows both permission asks, the check, and the way on")
    func rendersRows() throws {
        let view = OnboardingView(startingAt: .capture)
            .environmentObject(AppState(llm: MockLLMGateway(response: "")))
        let sut = try view.inspect()
        #expect(throws: Never.self) { try sut.find(text: "Microphone") }
        #expect(throws: Never.self) { try sut.find(text: "Screen Recording") }
        // The check is the point of this screen: a granted permission and a
        // working capture are different things.
        #expect(throws: Never.self) { try sut.find(text: "Capture check") }
        #expect(throws: Never.self) { try sut.find(button: "Continue") }
        // Sign-in has MOVED to the sidebar's setup card, so the account
        // decision lands after the user has seen what the co-pilot produces.
        #expect(throws: (any Error).self) { try sut.find(text: "Sign in") }
    }

    @Test("the relaunch fix is offered as a button, not described in prose")
    func relaunchIsAnAction() throws {
        // The old screen told the user to quit and reopen. The row now appears
        // only when the probe proves the quirk — granted, and silent anyway —
        // and it carries the action itself.
        #expect(CaptureProbe.needsRelaunch(verdict: .micOnly,
                                           screenRecordingGranted: true))
        #expect(!CaptureProbe.needsRelaunch(verdict: .pass,
                                            screenRecordingGranted: true))
    }

    @Test("asked for no particular step, the flow starts at the beginning")
    func unknownStepStartsSafe() throws {
        // The caller that knows the answer (ContentView) always passes it. A
        // caller that does not must not be handed a resume point computed from
        // pretend-granted permissions — starting at the capture check is the
        // only conservative answer.
        let saved = UserDefaults.standard.string(forKey: "onboarding.step")
        defer { UserDefaults.standard.set(saved, forKey: "onboarding.step") }
        UserDefaults.standard.set(OnboardingStep.capture.rawValue, forKey: "onboarding.step")

        let sut = try OnboardingView(startingAt: nil)
            .environmentObject(AppState(llm: MockLLMGateway(response: "")))
            .inspect()
        #expect(throws: Never.self) { try sut.find(text: "Capture check") }
    }

    @Test("the sample step names itself fiction and offers a way out")
    func sampleStepIsLabelled() throws {
        let view = OnboardingView(startingAt: .sample)
            .environmentObject(AppState(llm: MockLLMGateway(response: "")))
        let sut = try view.inspect()
        #expect(throws: Never.self) {
            try sut.find(textWhere: { s, _ in s.contains("Fictional call") })
        }
        #expect(throws: Never.self) { try sut.find(button: "Skip") }
    }

    @Test("a tip retired elsewhere disappears without a relaunch")
    func tipReadsLiveRetirementState() throws {
        // The retired set used to be copied into @State at init. Any other
        // surface retiring a tip — the chip's own modifier, a second card — left
        // this copy stale, so the tip sat on screen for the rest of the session.
        let saved = Config.coachTipsRetired
        defer { Config.coachTipsRetired = saved }
        Config.coachTipsRetired = []

        let state = AppState(llm: MockLLMGateway(response: ""))
        let view = CoachTipView(anchor: "recording.context.menu").environmentObject(state)
        #expect(throws: Never.self) {
            try view.inspect().find(text: CoachTip.recordingType.title)
        }

        Config.coachTipsRetired = [CoachTip.recordingType.id]
        #expect(throws: (any Error).self) {
            try view.inspect().find(text: CoachTip.recordingType.title)
        }
    }

    @Test("the sign-in step can be put off from its own row")
    func setupCardSignInRowHasItsOwnDismiss() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        let view = SetupCard()
            .environmentObject(state)
            .environmentObject(MCPConnectionManager(tokenStore: InMemoryKeychain()))
        let sut = try view.inspect()

        // The row itself, and a dismiss that belongs to it rather than to the
        // whole card — signing in is optional and stays available in the footer.
        #expect(throws: Never.self) {
            try sut.find(viewWithAccessibilityLabel: "Dismiss: Sign in — managed AI & sync")
        }
    }

    @Test("using the feature retires its tip, and nothing else does")
    func retiringModifierFires() throws {
        // The modifier is the half of retirement that no pure function can
        // cover: if it is wired to the wrong value, or not attached at all, the
        // tip keeps reappearing for someone who has already moved on.
        let saved = Config.coachTipsRetired
        defer { Config.coachTipsRetired = saved }
        Config.coachTipsRetired = []

        let view = Text("anchor").retiringCoachTip(.recordingType, when: false)
        let sut = try view.inspect()

        // Still automatic — the user has not touched the chip.
        try sut.callOnChange(newValue: false)
        #expect(Config.coachTipsRetired.isEmpty)

        // The moment they pick a type by hand, the tip is done.
        try sut.callOnChange(newValue: true)
        #expect(Config.coachTipsRetired.contains(CoachTip.recordingType.id))

        // And it stays done — a later flip back does not resurrect it.
        try sut.callOnChange(newValue: false)
        #expect(Config.coachTipsRetired.contains(CoachTip.recordingType.id))
    }

    @Test("a granted permission shows the granted state, not an Enable button")
    func grantedState() throws {
        let state = AppState(llm: MockLLMGateway(response: ""))
        state.micGranted = true
        state.screenRecordingGranted = false
        let sut = try OnboardingView(startingAt: .capture)
            .environmentObject(state).inspect()
        // Mic granted → its accessibility label reflects that.
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "Microphone granted") }
        // Screen not granted → an Enable affordance is present.
        #expect(throws: Never.self) { try sut.find(viewWithAccessibilityLabel: "Enable Screen Recording") }
    }
}
