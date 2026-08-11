import Foundation
import UserNotifications

/// A SILENT text notification when a new blind spot lands during a live call.
///
/// PROJECT_STATUS item 17, verbatim: "no audio implementation, ONLY IN BLIND
/// SPOT SECTION PUT TEXT NOTIFICATIONS." The point is the user who is looking at
/// Zoom, not at Cruxwing — a blind spot they never see is a blind spot that did
/// not help. So it surfaces as a macOS banner, and it is deliberately silent: a
/// chime mid-call interrupts the room, the text does not.
///
/// The decision of WHETHER to post is a pure function (`shouldNotify`), split
/// from the side effect so every rule is testable without a notification centre
/// or a live call.
enum BlindSpotNotifier {

    static let category = "BLIND_SPOT"

    /// Whether a batch of freshly-merged suggestions is worth a banner.
    ///
    /// Four rules, each a reason not to interrupt:
    /// - nothing new merged → nothing to say;
    /// - not recording → a blind spot outside a call is not urgent, and the
    ///   panel is the right place for it;
    /// - the app is frontmost → the user is already looking at the panel, so a
    ///   banner is redundant noise;
    /// - the feature is off.
    static func shouldNotify(freshCount: Int,
                             isRecording: Bool,
                             appIsActive: Bool,
                             enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard freshCount > 0 else { return false }
        guard isRecording else { return false }
        return !appIsActive
    }

    /// The banner's body: the sharpest single blind spot, plus a count when more
    /// arrived together. Named for the call so a glance identifies which meeting.
    static func body(for suggestions: [Suggestion]) -> (title: String, detail: String)? {
        guard let first = suggestions.first else { return nil }
        let extra = suggestions.count - 1
        let title = extra > 0 ? "\(first.title)  (+\(extra) more)" : first.title
        return (title: title, detail: first.detail)
    }

    /// Post the banner — silently. `sound = nil` is the whole point: item 17
    /// said text, not audio, and the default UN sound would be exactly the
    /// chime it rules out.
    @MainActor
    static func post(_ suggestions: [Suggestion], meetingTitle: String) {
        guard let body = body(for: suggestions) else { return }
        // UNUserNotificationCenter.current() ABORTS (not throws) when the host
        // is not an app bundle — a test runner, a CLI. Resolve it only AFTER
        // this guard, and never as a default argument, or the abort fires at
        // the call site before the guard can run. This is what keeps the merge
        // path safe to exercise in tests.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = meetingTitle.isEmpty ? "Blind spot" : meetingTitle
        content.subtitle = body.title
        content.body = body.detail
        content.sound = nil                 // silent, by design
        content.categoryIdentifier = category
        let request = UNNotificationRequest(
            identifier: "blindspot-\(UUID().uuidString)",
            content: content, trigger: nil)  // deliver now
        center.add(request)
    }
}
