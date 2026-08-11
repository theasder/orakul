import Testing
import Foundation
@testable import MeetGPT

@Suite("Account session")
struct AccountSessionTests {
    @Test("applySession persists flags used by the UI and Keychain")
    @MainActor
    func applySessionSetsConnectionState() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let session = WheesprSession(
            accessToken: "access",
            refreshToken: "refresh",
            accessExpiry: Date().addingTimeInterval(900),
            email: "reviewer@example.com",
            displayName: "Reviewer")

        state.applySession(session)
        state.applyTestWorkspace(recording: true)

        #expect(state.wheesprConnected)
        #expect(state.wheesprEmail == "reviewer@example.com")
        #expect(Config.wheesprSession?.refreshToken == "refresh")
        #expect(state.pendingAuthEmail == nil)

        state.signOutWheespr()
        #expect(!state.wheesprConnected)
        #expect(state.wheesprEmail == nil)
        #expect(Config.wheesprSession == nil)
        #expect(state.isRecording, "signing out must not terminate local audio capture")
    }

    @Test("session-adopted notification funnels through applySession")
    @MainActor
    func adoptedNotificationAppliesSession() async {
        // Private center: with the global default, these posts also hit every
        // OTHER test's AppState (parallel suites) and their session state —
        // and theirs hit ours.
        let center = NotificationCenter()
        let state = AppState(credentialStore: InMemoryKeychain(),
                             notificationCenter: center)
        let session = WheesprSession(
            accessToken: "a2",
            refreshToken: "r2",
            accessExpiry: Date().addingTimeInterval(900),
            email: "paywall@example.com",
            displayName: nil)

        WheesprSessionNotifications.postAdopted(session, center: center)
        // Observer delivery goes through OperationQueue.main — under a loaded
        // parallel run that can far exceed any fixed sleep. Poll to a deadline.
        await Self.waitUntil { state.wheesprConnected }

        #expect(state.wheesprConnected)
        #expect(state.wheesprEmail == "paywall@example.com")
        state.signOutWheespr()
    }

    @Test("session-expired notification surfaces a user-visible message")
    @MainActor
    func expiredNotificationSignsOutWithToast() async {
        let center = NotificationCenter()
        let state = AppState(credentialStore: InMemoryKeychain(),
                             notificationCenter: center)
        state.applySession(WheesprSession(
            accessToken: "a3",
            refreshToken: "r3",
            accessExpiry: Date().addingTimeInterval(900),
            email: "expire@example.com",
            displayName: nil))

        Config.wheesprSession = nil
        WheesprSessionNotifications.postExpired(center: center)
        await Self.waitUntil { !state.wheesprConnected }

        #expect(!state.wheesprConnected)
        #expect(state.lastError == "Session expired — sign in again")
    }

    /// Poll `condition` on the main actor until true or a 5 s deadline — the
    /// assertions after it produce the real failure message.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("socialAccountLoginEnabled defaults off and respects UserDefaults")
    func socialFlagDefaultsOff() {
        let key = "auth.socialAccountLogin"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        // Env may override in CI — only assert UserDefaults path when env unset.
        if ProcessInfo.processInfo.environment["SOCIAL_ACCOUNT_LOGIN"] == nil {
            #expect(Config.socialAccountLoginEnabled == false)
            Config.socialAccountLoginEnabled = true
            #expect(Config.socialAccountLoginEnabled == true)
            Config.socialAccountLoginEnabled = false
        }
    }
}
