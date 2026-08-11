import Foundation

extension Notification.Name {
    /// Posted when a Wheespr session is adopted outside `AppState` (e.g. paywall /
    /// device-redeem). `userInfo["session"]` is a `WheesprSession`.
    static let wheesprSessionAdopted = Notification.Name("meetgpt.wheesprSessionAdopted")

    /// Posted when a refresh returns 401 — the Keychain session is already cleared.
    static let wheesprSessionExpired = Notification.Name("meetgpt.wheesprSessionExpired")

    /// Posted for every process-local account-context replacement: sign-in,
    /// sign-out, refresh rotation, device redemption, and startup restoration.
    /// Connected-app evidence observes this separately from the UI lifecycle so
    /// cached content can never cross from one Cruxwing account to another.
    static let wheesprAccountContextChanged = Notification.Name(
        "meetgpt.wheesprAccountContextChanged")
}

/// Posts session-lifecycle notifications for observers (AppState, tests).
/// `center` is injectable so tests can use a private center — AppState observes
/// whichever center it was constructed with; production stays on `.default`.
enum WheesprSessionNotifications {
    static func postAdopted(_ session: WheesprSession,
                            center: NotificationCenter = .default) {
        center.post(
            name: .wheesprSessionAdopted,
            object: nil,
            userInfo: ["session": session])
    }

    static func postExpired(center: NotificationCenter = .default) {
        center.post(name: .wheesprSessionExpired, object: nil)
    }

    static func postAccountContextChanged(center: NotificationCenter = .default) {
        center.post(name: .wheesprAccountContextChanged, object: nil)
    }
}
