import Foundation

/// What a permission row's button should actually do.
///
/// macOS shows the Screen Recording prompt once per app, ever. After a refusal
/// `CGRequestScreenCaptureAccess()` returns without showing anything, so a
/// button wired straight to it becomes a dead control: the user presses it,
/// nothing happens, and the reasonable conclusion is that the app is broken.
/// The second press has to go somewhere that can still change the answer.
enum PermissionPrompt {
    enum Kind {
        case microphone
        case screenRecording
    }

    enum Action: Equatable {
        /// Ask macOS — the system prompt has not been shown yet.
        case request
        /// Only System Settings can change it now.
        case openSettings
    }

    static func action(granted: Bool, alreadyAsked: Bool) -> Action? {
        guard !granted else { return nil }
        return alreadyAsked ? .openSettings : .request
    }

    /// Deep link to the exact Privacy pane, so the user lands on the toggle
    /// rather than at the top of System Settings.
    static func settingsURL(for kind: Kind) -> URL? {
        let pane: String
        switch kind {
        case .microphone:      pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}
