import Foundation
import Testing
@testable import MeetGPT

/// Recognising a call from a window title.
///
/// This is the BROWSER detector. A Google Meet tab in Chrome, a Jitsi room, a
/// Whereby link — none of these is a running "meeting app", so the frontmost-app
/// heuristic never sees them, and without this path the browser call is simply
/// never offered.
///
/// Both directions cost something. A miss means no prompt for a real meeting; a
/// false positive interrupts someone reading a blog post with "Zoom" in the
/// title, and the prompt it raises asks to start recording — the most
/// unwelcome false positive the app has.
///
/// Layered on one base fact — a Meet tab is recognised — with each later test
/// tightening what else may or may not match.
@Suite("Call window title recognition")
@MainActor
struct CallWindowTitleTests {

    private func label(_ title: String) -> String? {
        CallDetector.callLabel(forWindowTitle: title)?.label
    }

    // MARK: - Base

    @Test("a Google Meet tab is recognised")
    func recognisesMeet() {
        #expect(label("Meet - abc-defg-hij") == nil, "the bare room code is not evidence")
        #expect(label("Google Meet - Weekly sync") == "Google Meet")
        #expect(label("meet.google.com/abc-defg-hij") == "Google Meet")
    }

    // MARK: - Layer: the other services

    @Test("every configured service is reachable from a realistic title")
    func recognisesEachService() {
        #expect(label("Zoom Meeting") == "Zoom")
        #expect(label("Webex Meeting — Q3 planning") == "Webex")
        #expect(label("Microsoft Teams Meeting | Standup") == "Microsoft Teams")
        #expect(label("Whereby - product-team") == "Whereby")
        #expect(label("Jitsi Meet - DailySync") == "Jitsi")
    }

    @Test("matching ignores the capitalisation the site happened to use")
    func matchIsCaseInsensitive() {
        // Titles carry the page title verbatim, and sites are inconsistent.
        #expect(label("ZOOM MEETING") == "Zoom")
        #expect(label("google meet — standup") == "Google Meet")
        #expect(label("JITSI MEET") == "Jitsi")
    }

    @Test("the service is found anywhere in the title, not only at the start")
    func matchesMidTitle() {
        // Browsers append their own name, and tab titles often lead with the
        // room or the document.
        #expect(label("Weekly sync - Google Meet - Google Chrome") == "Google Meet")
        #expect(label("(3) Zoom Meeting — Safari") == "Zoom")
    }

    // MARK: - Layer: what must NOT trigger a recording prompt

    @Test("reading about a product is not being in a call")
    func ignoresProseAboutTheProducts() {
        // The costly false positive: an article or a doc merely NAMING the
        // service. The fragments are deliberately two-word phrases for this
        // reason — "zoom" alone would match a photography article.
        for title in [
            "How to zoom in on a photo — Photography Weekly",
            "Zoom Video Communications, Inc. - Wikipedia",
            "Teams | Our company handbook",
            "Inbox (12) - Gmail",
            "Slack | general | Acme",
            "Untitled document - Google Docs",
        ] {
            #expect(label(title) == nil, "false positive on: \(title)")
        }
    }

    @Test("an empty or whitespace title never matches")
    func ignoresEmptyTitles() {
        #expect(label("") == nil)
        #expect(label("   ") == nil)
        #expect(label("\n\t") == nil)
    }

    // MARK: - Layer: the label that comes back

    @Test("both Meet spellings report the same service name")
    func aliasesShareOneLabel() {
        // The label is the debounce key, so two spellings mapping to different
        // labels would prompt twice for one meeting.
        #expect(label("Google Meet - sync") == label("meet.google.com/abc-defg-hij"))
    }

    @Test("every configured label matches the canonical app names")
    func labelsAreCanonical() {
        // The window path and the app-activation path debounce on the same
        // label; a mismatch means one call prompts twice.
        let labels = ["Google Meet - x", "Zoom Meeting", "Webex Meeting",
                      "Microsoft Teams Meeting", "Whereby - x", "Jitsi Meet - x"]
            .compactMap(label)
        #expect(Set(labels) == ["Google Meet", "Zoom", "Webex", "Microsoft Teams", "Whereby", "Jitsi"])
    }

    @Test("a title naming two services resolves to exactly one, deterministically")
    func ambiguousTitlesAreStable() {
        // A calendar tab can list several meetings. Whatever it picks, it must
        // pick the same one every scan or the debounce never settles.
        let title = "Zoom Meeting and Google Meet — Calendar"
        let first = label(title)
        #expect(first != nil)
        for _ in 0..<5 { #expect(label(title) == first) }
    }
}
