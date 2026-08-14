import Foundation
import os
import UserNotifications

/// Nonisolated identifiers so the delegate callbacks (which run off the main
/// actor) can reference them without a concurrency violation.
enum CallNotifierID {
    static let callCategory = "CALL_DETECTED"
    /// Scheduled pre-meeting reminders (posted by `MeetingReminderScheduler`).
    static let reminderCategory = "MEETING_REMINDER"
    static let startAction = "START_RECORDING"
}

/// Wraps local notifications for the call-detection prompt and owns the single
/// `UNUserNotificationCenter` delegate (a center allows only one). Posts a "you
/// seem to be in a call — start recording?" alert with an inline action, routes
/// the tap back to AppState via `onStartRecording`, and registers the reminder
/// category so scheduled meeting reminders share the same delegate.
@MainActor
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked when the user taps the call prompt or its "Start recording" action.
    var onStartRecording: (() -> Void)?
    /// Invoked when a prompt could not be shown because notifications are denied,
    /// so the app can surface a hint instead of dropping the alert silently.
    var onNotificationsDenied: (() -> Void)?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: CallNotifierID.startAction,
                                         title: "Записать",
                                         options: [.foreground])
        let call = UNNotificationCategory(identifier: CallNotifierID.callCategory,
                                          actions: [start],
                                          intentIdentifiers: [],
                                          options: [])
        // Reminders are informational — tapping just opens the app, no action.
        let reminder = UNNotificationCategory(identifier: CallNotifierID.reminderCategory,
                                              actions: [],
                                              intentIdentifiers: [],
                                              options: [])
        // Blind-spot banners (PROJECT_STATUS item 17): informational, tap opens
        // the app. Shares this single delegate — a center allows only one.
        let blindSpot = UNNotificationCategory(identifier: BlindSpotNotifier.category,
                                               actions: [],
                                               intentIdentifiers: [],
                                               options: [])
        center.setNotificationCategories([call, reminder, blindSpot])
        // Ask up front so the OS permission dialog appears early. The prompt path
        // re-checks the live status, so a later grant/deny still takes effect.
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    /// Post the "in a call?" prompt. Unlike a cached flag, this reconciles the
    /// *current* authorization each time — so permission granted later in System
    /// Settings takes effect without an app relaunch — requests it when still
    /// undetermined, and reports a denial upward instead of failing silently.
    func promptForCall(appName: String) {
        Task { await deliverCallPrompt(appName: appName) }
    }

    /// Copy for the active-call prompt, kept pure and `nonisolated` so it can be
    /// unit-tested and reused by the delivery path. `source` is the detected app
    /// or service (e.g. "Zoom", "Google Meet"): macOS doesn't expose the caller's
    /// contact or number to third-party apps, so the service name stands in for
    /// the "[Contact Name/Number]" a native dialer would show. The wording marks
    /// this as a call happening *now* — distinct from the scheduled reminder,
    /// which announces an *upcoming* one.
    nonisolated static func callPromptText(source: String) -> (title: String, body: String) {
        ("Звонок в \(source)", "orakul может записать этот звонок. Записывать?")
    }

    private func deliverCallPrompt(appName: String) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            status = granted ? .authorized : .denied
        }
        guard status == .authorized || status == .provisional else {
            onNotificationsDenied?()
            return
        }

        let text = Self.callPromptText(source: appName)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        // A distinctive sonar tone so a live call is audibly unmistakable from a
        // scheduled-meeting reminder (which uses a light chime). If the named
        // system sound can't be resolved the OS falls back to the default sound.
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "Submarine.aiff"))
        content.categoryIdentifier = CallNotifierID.callCategory
        // Time Sensitive lets the alert break through Focus/Do Not Disturb — but
        // only once the app also carries the Time Sensitive Notifications
        // entitlement AND is signed with a profile that authorizes it. The dev
        // build signs ad-hoc, so this is currently harmless and delivers normally.
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)   // deliver now
        do {
            try await center.add(request)
        } catch {
            Log.notify.error("failed to post call notification — \(error.localizedDescription)")
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Only the call prompt starts recording. A meeting reminder fires before
        // the call begins, so tapping it just opens the app — never auto-records.
        let category = response.notification.request.content.categoryIdentifier
        let isStart = category == CallNotifierID.callCategory
            && (response.actionIdentifier == CallNotifierID.startAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        Task { @MainActor in
            if isStart { self.onStartRecording?() }
            completionHandler()
        }
    }

    /// Show the alert even when MeetGPT is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
