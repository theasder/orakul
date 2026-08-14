import Foundation
import Testing
@testable import MeetGPT

/// Announcing a sign-out the user did not ask for.
///
/// The session lives in the Keychain; connected-app tokens live in separate
/// rows. When the session row disappears — expired, revoked, or unreadable
/// after a signing-identity change — the connectors survive, so the workspace
/// still looks signed in and nothing says otherwise. The only symptom was the
/// credits rail going quiet, which reads as a billing bug: reported as "credits
/// unavailable in the account where apps are connected".
///
/// The breadcrumb that makes this detectable is `Config.lastSignedInEmail` in
/// UserDefaults — outside the Keychain on purpose, so it survives whatever took
/// the session with it.
@Suite("Unexpected sign-out notice")
@MainActor
struct SignedOutNoticeTests {

    private func freshState() -> AppState {
        Config.lastSignedInEmail = nil
        let app = AppState(credentialStore: InMemoryKeychain())
        app.dismissSignedOutNotice()
        return app
    }

    private func session(_ email: String) -> WheesprSession {
        WheesprSession(accessToken: "access", refreshToken: "refresh",
                       accessExpiry: Date().addingTimeInterval(900), email: email)
    }

    @Test("signing in records the account so a later disappearance is detectable")
    func signInLeavesABreadcrumb() {
        let app = freshState()
        app.applySession(session("dev@cruxwing.ai"))
        #expect(Config.lastSignedInEmail == "dev@cruxwing.ai")
        #expect(app.signedOutNotice == nil)
        Config.lastSignedInEmail = nil
    }

    @Test("a deliberate sign-out never nags, now or on the next launch")
    func deliberateSignOutIsSilent() {
        let app = freshState()
        app.applySession(session("dev@cruxwing.ai"))
        app.signOutWheespr()
        #expect(app.signedOutNotice == nil)
        // The breadcrumb is cleared, so the next launch sees "never signed in"
        // rather than "signed out unexpectedly".
        #expect(Config.lastSignedInEmail == nil)
    }

    @Test("an expired session is announced, and names the account")
    func expiredSessionIsAnnounced() {
        let app = freshState()
        app.applySession(session("dev@cruxwing.ai"))
        app.handleSessionExpiredForTesting()

        let notice = app.signedOutNotice
        #expect(notice?.reason == .expired)
        #expect(notice?.email == "dev@cruxwing.ai")
        let message = notice?.message ?? ""
        #expect(message.contains("dev@cruxwing.ai"))
        // Человеку нужны два факта: что делать и что коннекторы целы —
        // отсутствие второго и делало это похожим на отказ оплаты. Сам текст
        // был английским и обещал «AI credits», которых у orakul нет.
        #expect(message.lowercased().contains("войдите"))
        Config.lastSignedInEmail = nil
    }

    @Test("a fresh install is not a sign-out")
    func neverSignedInIsNotASignOut() {
        // No breadcrumb: this machine has never held an account, so silence is
        // correct. Getting this wrong would greet every new user with an error.
        let app = freshState()
        app.handleSessionExpiredForTesting()
        #expect(app.signedOutNotice == nil)
    }

    @Test("the first notice stands; a second reason does not overwrite it")
    func firstNoticeWins() {
        let app = freshState()
        Config.lastSignedInEmail = "dev@cruxwing.ai"
        app.noteSignedOutForTesting(.sessionMissingAtLaunch)
        app.noteSignedOutForTesting(.expired)
        #expect(app.signedOutNotice?.reason == .sessionMissingAtLaunch)
        Config.lastSignedInEmail = nil
    }

    @Test("dismissing clears it; signing back in clears it too")
    func noticeClears() {
        let app = freshState()
        Config.lastSignedInEmail = "dev@cruxwing.ai"

        app.noteSignedOutForTesting(.sessionMissingAtLaunch)
        #expect(app.signedOutNotice != nil)
        app.dismissSignedOutNotice()
        #expect(app.signedOutNotice == nil)

        app.noteSignedOutForTesting(.expired)
        #expect(app.signedOutNotice != nil)
        app.applySession(session("dev@cruxwing.ai"))
        #expect(app.signedOutNotice == nil, "signing back in answers the notice")
        Config.lastSignedInEmail = nil
    }

    @Test("both reasons say the connectors survived")
    func everyReasonReassuresAboutConnectors() {
        for reason in [AppState.SignedOutReason.sessionMissingAtLaunch, .expired] {
            let text = reason.message.lowercased()
            #expect(text.contains("войдите"), "\(reason): \(text)")
            #expect(!text.contains("credits"), "обещаны кредиты, которых нет: \(text)")
            #expect(!text.contains("cruxwing"), "имя другого продукта: \(text)")
        }
        // Only the launch case can be mistaken for "the app lost my apps too",
        // because it is the one where the workspace still shows them attached.
        #expect(AppState.SignedOutReason.sessionMissingAtLaunch.message
            .lowercased().contains("подключённые приложения"))
    }
}
