import Foundation
import Testing
@testable import MeetGPT

/// The Google sign-in ORCHESTRATION — the part that had no tests when the
/// "signed in a second time and nothing happened" report arrived. The browser
/// and Google are injected out; what is under test is the state machine:
/// success applies a session, repeat sign-ins work, cancellation stays
/// silent, real failures surface, and a click during a live flow restarts it
/// instead of being swallowed.
@Suite("Google sign-in flow")
struct GoogleSignInFlowTests {

    private func session(email: String) -> WheesprSession {
        WheesprSession(accessToken: "access-\(email)", refreshToken: "refresh",
                       accessExpiry: Date().addingTimeInterval(900), email: email)
    }

    @Test("a successful sign-in applies the session")
    @MainActor
    func successAppliesSession() async {
        let state = AppState()
        await state.signInWithGoogleAccount(
            authorize: { "id-token" },
            login: { _ in self.session(email: "anna@example.com") })
        #expect(state.wheesprConnected)
        #expect(state.wheesprEmail == "anna@example.com")
        #expect(state.lastError == nil)
    }

    @Test("signing in a second time with the same email works and stays clean")
    @MainActor
    func repeatSignInSameEmail() async {
        // The reported symptom. A repeat login is an ordinary login: the
        // server upserts and issues a fresh session; the app must apply it
        // and end in exactly the signed-in state, with no stuck guard.
        let state = AppState()
        for _ in 0..<2 {
            await state.signInWithGoogleAccount(
                authorize: { "id-token" },
                login: { _ in self.session(email: "anna@example.com") })
        }
        #expect(state.wheesprConnected)
        #expect(state.wheesprEmail == "anna@example.com")
        #expect(!state.authWorking, "the guard must never stay latched")
        #expect(state.lastError == nil)
    }

    @Test("a dismissed browser stays silent; a real failure surfaces")
    @MainActor
    func cancelSilentFailureLoud() async {
        let state = AppState()
        await state.signInWithGoogleAccount(
            authorize: { throw GoogleAuthError.cancelled },
            login: { _ in Issue.record("login must not run"); return self.session(email: "x") })
        #expect(state.lastError == nil, "dismissing the browser is not an error")
        #expect(!state.wheesprConnected)

        await state.signInWithGoogleAccount(
            authorize: { throw GoogleAuthError.http(500) },
            login: { _ in Issue.record("login must not run"); return self.session(email: "x") })
        #expect(state.lastError != nil, "a real failure must be visible")
        #expect(!state.authWorking)
    }

    @Test("every session apply forces a credit-usage refetch, even same-account")
    @MainActor
    func sessionApplyBumpsUsageRevision() async {
        // The credit bar listens to computeUsageRevision. A re-sign-in with
        // the SAME account flips no other observed state, and the bar kept
        // pre-sign-in numbers — "you don't remember that I spent credits".
        let state = AppState()
        let before = state.computeUsageRevision
        await state.signInWithGoogleAccount(
            authorize: { "id-token" },
            login: { _ in self.session(email: "anna@example.com") })
        let afterFirst = state.computeUsageRevision
        #expect(afterFirst > before)
        await state.signInWithGoogleAccount(
            authorize: { "id-token" },
            login: { _ in self.session(email: "anna@example.com") })
        #expect(state.computeUsageRevision > afterFirst,
                "the same-account re-sign-in must also force a refetch")
    }

    @Test("a click during a live flow restarts it rather than being swallowed")
    @MainActor
    func repeatClickRestartsLiveFlow() async {
        // Before the fix this was the bug: the first browser flow waits up to
        // two minutes, and every further click hit `guard !authWorking` and
        // returned with no feedback at all — "the app doesn't react".
        let state = AppState()
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstBlocked = AsyncStream<Void>.makeStream()

        let first = Task { @MainActor in
            await state.signInWithGoogleAccount(
                authorize: {
                    firstStarted.continuation.yield()
                    // Simulates the abandoned browser window: hangs until the
                    // restart path lets it end.
                    for await _ in firstBlocked.stream { }
                    throw GoogleAuthError.cancelled
                },
                login: { _ in Issue.record("first flow must not log in"); return self.session(email: "x") })
        }
        for await _ in firstStarted.stream { break }   // first flow is live
        #expect(state.authWorking)

        let second = Task { @MainActor in
            await state.signInWithGoogleAccount(
                authorize: { "fresh-token" },
                login: { _ in self.session(email: "anna@example.com") })
        }
        // The restart path cancels the stale loopback; our fake "browser"
        // honours it by ending the hang.
        try? await Task.sleep(nanoseconds: 200_000_000)
        firstBlocked.continuation.finish()

        await first.value
        await second.value
        #expect(state.wheesprConnected, "the second click must produce a sign-in")
        #expect(state.wheesprEmail == "anna@example.com")
        #expect(!state.authWorking)
    }
}
