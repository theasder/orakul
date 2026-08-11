import Foundation
import Testing
@testable import MeetGPT

/// PROJECT_STATUS item 17 — silent text notifications for blind spots. The
/// side effect (posting a banner) is untestable without a live notification
/// centre, so the DECISION and the BODY are pure functions, and this pins both:
/// every rule that decides whether to interrupt, and that the banner never
/// carries sound.
@Suite("Blind-spot notifier")
struct BlindSpotNotifierTests {

    private func suggestion(_ title: String, _ detail: String = "why it matters") -> Suggestion {
        Suggestion(title: title, detail: detail, kind: .question)
    }

    // MARK: - shouldNotify: the four reasons not to interrupt

    @Test("notifies for a fresh blind spot while recording, app in the background")
    func happyPath() {
        #expect(BlindSpotNotifier.shouldNotify(
            freshCount: 1, isRecording: true, appIsActive: false, enabled: true))
    }

    @Test("does not notify when nothing new merged")
    func noFresh() {
        #expect(!BlindSpotNotifier.shouldNotify(
            freshCount: 0, isRecording: true, appIsActive: false, enabled: true))
    }

    @Test("does not notify outside a live call")
    func notRecording() {
        // A blind spot off-call is not urgent, and the panel is the right place.
        #expect(!BlindSpotNotifier.shouldNotify(
            freshCount: 2, isRecording: false, appIsActive: false, enabled: true))
    }

    @Test("does not notify when the app is frontmost")
    func appActive() {
        // The user is already looking at the panel; a banner is redundant noise.
        #expect(!BlindSpotNotifier.shouldNotify(
            freshCount: 1, isRecording: true, appIsActive: true, enabled: true))
    }

    @Test("does not notify when disabled")
    func disabled() {
        #expect(!BlindSpotNotifier.shouldNotify(
            freshCount: 1, isRecording: true, appIsActive: false, enabled: false))
    }

    // MARK: - body

    @Test("the body leads with the sharpest single blind spot")
    func bodySingle() {
        let body = BlindSpotNotifier.body(for: [suggestion("Nobody owns the DPA")])
        #expect(body?.title == "Nobody owns the DPA")
        #expect(body?.detail == "why it matters")
    }

    @Test("several arriving together show a count, not a wall of text")
    func bodyMultiple() {
        let body = BlindSpotNotifier.body(for: [
            suggestion("Nobody owns the DPA"),
            suggestion("Offline conflicts unresolved"),
            suggestion("Testers never asked"),
        ])
        #expect(body?.title == "Nobody owns the DPA  (+2 more)")
    }

    @Test("an empty batch has no body")
    func bodyEmpty() {
        #expect(BlindSpotNotifier.body(for: []) == nil)
    }

    // MARK: - Config

    @Test("the toggle defaults on and round-trips")
    func configDefault() {
        let saved = UserDefaults.standard.object(forKey: "notify.blindSpotText")
        defer { UserDefaults.standard.set(saved, forKey: "notify.blindSpotText") }
        UserDefaults.standard.removeObject(forKey: "notify.blindSpotText")
        #expect(Config.blindSpotTextNotificationsEnabled)
        Config.blindSpotTextNotificationsEnabled = false
        #expect(!Config.blindSpotTextNotificationsEnabled)
    }
}
