import Foundation
import Testing
@testable import MeetGPT

/// Which app a detected call is attributed to.
///
/// Reported from a real session: starting a new Zoom conference produced a
/// "Telegram" call. The acoustic detector fires when the mic goes live and then
/// has to name the app responsible; it used to take the FIRST comm app in
/// `NSWorkspace.runningApplications`, whose order is arbitrary. Messengers
/// launch at login and run all day, so on most machines one of them is in that
/// list before Zoom — and the meeting was named, notified and filed against the
/// wrong app.
@Suite("Call detector app attribution")
@MainActor
struct CallDetectorRankingTests {

    private func app(_ bundleID: String, name: String? = nil, active: Bool = false)
    -> CallDetector.CommAppCandidate {
        CallDetector.CommAppCandidate(bundleID: bundleID, localizedName: name, isActive: active)
    }

    private func label(_ candidates: [CallDetector.CommAppCandidate]) -> String? {
        CallDetector.rankedCommApp(from: candidates).map(CallDetector.label(for:))
    }

    @Test("a Zoom conference is not attributed to a Telegram running in the background")
    func zoomBeatsBackgroundTelegram() {
        // The exact reported shape: Telegram enumerated first because it was
        // launched at login, Zoom started later for the actual meeting.
        #expect(label([
            app("ru.keepcoder.Telegram", name: "Telegram"),
            app("us.zoom.xos", name: "zoom.us", active: true),
        ]) == "Zoom")
    }

    @Test("Zoom wins even when it is not frontmost")
    func zoomBeatsTelegramWithoutFocus() {
        // Screen-sharing or taking notes in another window during the call.
        // Zoom merely BEING open is evidence of a meeting; Telegram being open
        // is the resting state of the machine.
        #expect(label([
            app("ru.keepcoder.Telegram", name: "Telegram"),
            app("us.zoom.xos", name: "zoom.us"),
        ]) == "Zoom")
    }

    @Test("Jitsi desktop is a dedicated meeting client with a canonical label")
    func jitsiDesktopIsRecognised() {
        #expect(label([
            app("ru.keepcoder.Telegram", name: "Telegram"),
            app("org.jitsi.jitsi-meet", name: "Jitsi Meet"),
        ]) == "Jitsi")
        #expect(CallDetector.meetingApps.contains("org.jitsi.jitsi-meet"))
    }

    @Test("TrueConf is recognised by the live acoustic detector")
    func trueConfIsRecognised() {
        // TrueConf is a communication client rather than history data source:
        // mic-in-use + running app is the evidence, and the localized app name
        // cannot change the meeting label.
        #expect(label([
            app("org.trueconf.client", name: "Труконф", active: true),
        ]) == "TrueConf")
        #expect(!CallDetector.meetingApps.contains("org.trueconf.client"))
    }

    @Test("a real Telegram call is still attributed to Telegram")
    func telegramCallIsNotStolen() {
        // The fix must not simply always prefer meeting apps: with no meeting
        // app running at all, the messenger is the right answer.
        #expect(label([app("ru.keepcoder.Telegram", name: "Telegram", active: true)]) == "Telegram")
        #expect(label([
            app("net.whatsapp.WhatsApp", name: "WhatsApp"),
            app("ru.keepcoder.Telegram", name: "Telegram", active: true),
        ]) == "Telegram")
    }

    @Test("the app in front wins between two meeting apps")
    func frontmostBreaksTiesBetweenMeetingApps() {
        // Teams left running from the morning, Zoom in front for this call.
        #expect(label([
            app("com.microsoft.teams2", name: "Microsoft Teams"),
            app("us.zoom.xos", name: "zoom.us", active: true),
        ]) == "Zoom")
        #expect(label([
            app("us.zoom.xos", name: "zoom.us"),
            app("com.microsoft.teams2", name: "Microsoft Teams", active: true),
        ]) == "Microsoft Teams")
    }

    @Test("both Telegram bundle ids are recognised")
    func telegramDesktopVariant() {
        // Telegram ships two macOS builds with different bundle ids; the
        // App Store one and Telegram Desktop.
        #expect(label([app("com.tdesktop.Telegram", name: "Telegram Desktop", active: true)]) == "Telegram")
        #expect(label([app("ru.keepcoder.Telegram", name: "Telegram", active: true)]) == "Telegram")
    }

    @Test("labels do not depend on the system locale")
    func labelsAreStableAcrossLocales() {
        // localizedName is whatever the vendor shipped for that locale, and the
        // label ends up in the meeting title. Every known app has a fixed name.
        #expect(label([app("ru.keepcoder.Telegram", name: "Телеграм", active: true)]) == "Telegram")
        #expect(label([app("us.zoom.xos", name: "Зум", active: true)]) == "Zoom")
        // An app we do not have a canonical name for falls back to its own.
        #expect(label([app("com.skype.skype", name: "Skype for Business")]) == "Skype")
    }

    @Test("non-communication apps are never attributed a call")
    func ignoresUnrelatedApps() {
        #expect(label([
            app("com.apple.Safari", name: "Safari", active: true),
            app("com.spotify.client", name: "Spotify"),
        ]) == nil)
        #expect(label([]) == nil)
    }

    @Test("the answer does not depend on process-list order")
    func rankingIsOrderIndependent() {
        // The original bug WAS order dependence, so every permutation of a
        // realistic app set must produce the same attribution.
        let apps = [
            app("ru.keepcoder.Telegram", name: "Telegram"),
            app("net.whatsapp.WhatsApp", name: "WhatsApp"),
            app("us.zoom.xos", name: "zoom.us", active: true),
        ]
        var results: Set<String> = []
        for permutation in permutations(of: apps) {
            results.insert(label(permutation) ?? "nil")
        }
        #expect(results == ["Zoom"], "order changed the answer: \(results)")
    }

    private func permutations(
        of items: [CallDetector.CommAppCandidate]
    ) -> [[CallDetector.CommAppCandidate]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[CallDetector.CommAppCandidate]] in
            var rest = items
            let item = rest.remove(at: index)
            return permutations(of: rest).map { [item] + $0 }
        }
    }
}
