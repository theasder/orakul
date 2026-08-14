import Foundation
import os
import UserNotifications

/// Schedules local notifications ahead of upcoming calendar meetings.
///
/// `sync` is idempotent: every reminder is keyed by `reminder-<eventID>`, so
/// re-polling reconciles (removes stale, adds new) instead of duplicating. The
/// category is registered by `CallNotifier`, which owns the single center
/// delegate; a reminder tap just opens the app (no auto-record).
@MainActor
final class MeetingReminderScheduler {
    private static let idPrefix = "reminder-"

    /// Replace the currently-scheduled reminders with ones derived from
    /// `meetings`, firing `minutesBefore` minutes before each start. No-ops
    /// (after clearing) if notifications aren't authorized.
    func sync(meetings: [UpcomingMeeting], minutesBefore: Int) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            await clear()
            return
        }

        await clear()

        let now = Date()
        let lead = TimeInterval(max(1, minutesBefore) * 60)
        for meeting in meetings {
            // Schedule only while the lead-based fire time is still in the future.
            // Once it has passed we skip the meeting entirely: clamping the fire
            // time forward to "now" would re-fire the reminder on every poll,
            // because clear() only tracks *pending* requests and can't see an
            // already-delivered one — so a meeting in its final minutes would
            // spam a fresh duplicate alert each poll. (A meeting added with less
            // than the lead time remaining simply gets no reminder.)
            let fireDate = meeting.start.addingTimeInterval(-lead)
            guard fireDate > now else { continue }

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

            let text = Self.reminderText(
                title: meeting.title, start: meeting.start, minutesBefore: minutesBefore)
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            // A light chime — deliberately distinct from the active-call prompt's
            // sonar tone so the two events are tellable apart by ear alone.
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "Glass.aiff"))
            content.categoryIdentifier = CallNotifierID.reminderCategory
            // See CallNotifier: harmless without the Time Sensitive entitlement,
            // and lets the reminder pierce Focus/DND once that entitlement is added.
            content.interruptionLevel = .timeSensitive

            let request = UNNotificationRequest(
                identifier: Self.idPrefix + meeting.id, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                Log.notify.error("failed to schedule meeting reminder — \(error.localizedDescription)")
            }
        }
    }

    /// Remove every reminder this scheduler owns (leaves other app notifications
    /// — e.g. the call prompt — untouched).
    func clear() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    /// Copy for a scheduled-meeting reminder, kept pure and `nonisolated` so it
    /// can be unit-tested and reused by the scheduling path. This frames the
    /// alert as a call-to-action for an *upcoming* call — distinct from the
    /// active-call prompt. The reminder is scheduled to fire exactly
    /// `minutesBefore` before `start`, so "Starts in N min" is accurate at
    /// delivery time; computing it from the current clock here would be stale by
    /// the time the OS actually fires the notification.
    nonisolated static func reminderText(
        title: String, start: Date, minutesBefore: Int
    ) -> (title: String, body: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let clock = formatter.string(from: start)
        let lead = max(1, minutesBefore)   // mirrors the lead clamp in `sync`
        return ("Скоро звонок: \(title)",
                "Начало через \(lead) мин (\(clock)) — откройте orakul, чтобы записать.")
    }
}
