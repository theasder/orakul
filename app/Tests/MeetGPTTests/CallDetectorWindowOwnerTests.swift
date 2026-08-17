import Foundation
import Testing
@testable import MeetGPT

/// Who owns a window decides whether its title is evidence of a call.
///
/// The reported bug: the Fireflies desktop app was running and showing its
/// meeting list, a row read "… Zoom Meeting", and the window-title recognizer
/// offered to record. Nobody was in a call. A notetaker displaying a meeting
/// title is close to the OPPOSITE of evidence — it usually means the meeting is
/// already over.
///
/// The asymmetry that shapes these tests: a false prompt interrupts focused
/// work and teaches people to dismiss the app, while a missed offer costs one
/// click, and the acoustic and activation detectors still cover real calls this
/// turns away. So an unknown owner is refused rather than allowed.
@Suite("Call detector window owner")
struct CallDetectorWindowOwnerTests {

    // MARK: - The reported bug

    @Test("a Fireflies row naming a Zoom meeting is not a call")
    func firefliesListingIsNotACall() {
        #expect(CallDetector.callLabel(forWindowTitle: "Weekly sync — Zoom Meeting",
                                       ownerBundleID: "ai.fireflies.desktop") == nil)
    }

    @Test("other notetakers listing meetings are not calls either", arguments: [
        "ai.otter.otter", "ai.fathom.app", "com.granola.granola", "tv.tldv.app",
    ])
    func otherNotetakersAreNotCalls(bundleID: String) {
        #expect(CallDetector.callLabel(forWindowTitle: "Q3 planning — Google Meet",
                                       ownerBundleID: bundleID) == nil)
    }

    @Test("a calendar entry naming a meeting is not a call", arguments: [
        "com.apple.iCal", "com.flexibits.fantastical2.mac", "com.microsoft.Outlook",
    ])
    func calendarEntriesAreNotCalls(bundleID: String) {
        // A calendar showing tomorrow's "Zoom Meeting" is the clearest case of
        // a title that describes a meeting that is not happening.
        #expect(CallDetector.callLabel(forWindowTitle: "10:00 Zoom Meeting — Calendar",
                                       ownerBundleID: bundleID) == nil)
    }

    @Test("a Slack message mentioning a meeting is not a call")
    func slackMentionIsNotACall() {
        #expect(CallDetector.callLabel(forWindowTitle: "#general — join the zoom meeting",
                                       ownerBundleID: "com.tinyspeck.slackmacgap") == nil)
    }

    // MARK: - Real calls still detected

    @Test("a browser tab in a real call is still detected", arguments: [
        "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.browser", "com.brave.browser",
    ])
    func browserCallsStillDetected(bundleID: String) {
        // The whole reason the title recognizer exists: a browser call is
        // invisible to the frontmost-app heuristic.
        let match = CallDetector.callLabel(forWindowTitle: "Meet — abc-defg-hij | meet.google.com",
                                           ownerBundleID: bundleID)
        #expect(match?.label == "Google Meet")
    }

    @Test("a native meeting client is still detected", arguments: [
        "us.zoom.xos", "com.microsoft.teams2", "com.webex.meetingmanager",
        "org.jitsi.jitsi-meet",
    ])
    func nativeClientsStillDetected(bundleID: String) {
        #expect(CallDetector.callLabel(forWindowTitle: "Zoom Meeting",
                                       ownerBundleID: bundleID) != nil)
    }

    @Test("the official Jitsi desktop owner can host its Jitsi Meet window")
    func jitsiDesktopWindow() {
        let match = CallDetector.callLabel(
            forWindowTitle: "Jitsi Meet — Daily sync",
            ownerBundleID: "org.jitsi.jitsi-meet")
        #expect(match?.label == "Jitsi")
    }

    // MARK: - The default for anything else

    @Test("an unknown app is refused rather than trusted")
    func unknownOwnerIsRefused() {
        // Allow-by-default would mean every future notetaker, wiki and chat app
        // reintroduces this bug. The cost of refusing is one missed offer; the
        // acoustic and activation detectors still cover a real call.
        #expect(CallDetector.callLabel(forWindowTitle: "Zoom Meeting",
                                       ownerBundleID: "com.example.somethingnew") == nil)
    }

    @Test("a window with no owner is refused")
    func missingOwnerIsRefused() {
        #expect(!CallDetector.windowOwnerCanHostCall(bundleID: nil))
        #expect(!CallDetector.windowOwnerCanHostCall(bundleID: ""))
    }

    @Test("owner matching ignores case")
    func ownerMatchingIsCaseInsensitive() {
        // ScreenCaptureKit reports bundle ids verbatim, and they are not
        // consistently cased across apps.
        #expect(CallDetector.windowOwnerCanHostCall(bundleID: "US.ZOOM.XOS"))
        #expect(!CallDetector.windowOwnerCanHostCall(bundleID: "AI.Fireflies.Desktop"))
    }

    // MARK: - The title matcher itself is unchanged

    @Test("a plain title still matches without an owner check")
    func titleOnlyMatcherStillWorks() {
        // The single-argument form is still used where the owner is already
        // known to be a call host; it must keep its old behaviour.
        #expect(CallDetector.callLabel(forWindowTitle: "Zoom Meeting")?.label == "Zoom")
        #expect(CallDetector.callLabel(forWindowTitle: "Inbox — Mail") == nil)
    }

    @Test("a listing app cannot be rescued by a very explicit title")
    func listingAppNeverMatches() {
        // Even the most call-like title from a notetaker is a row in a list.
        for title in ["Zoom Meeting", "meet.google.com/abc-defg-hij",
                      "Microsoft Teams Meeting", "Jitsi Meet"] {
            #expect(CallDetector.callLabel(forWindowTitle: title,
                                           ownerBundleID: "ai.fireflies.desktop") == nil,
                    "\(title)")
        }
    }
}
