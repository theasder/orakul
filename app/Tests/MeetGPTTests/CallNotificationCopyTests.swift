import Testing
import Foundation
@testable import MeetGPT

/// The call-detection prompt and the scheduled-meeting reminder must read as two
/// clearly different events — a call happening *now* vs. one *about to* start —
/// so the user can tell at a glance (and by ear) which is which. These lock the
/// delineating copy so a future edit can't quietly blur the two contexts.
struct CallNotificationCopyTests {

    @Test("Active-call prompt names the source and asks to record")
    func callPromptDelineatesActiveCall() {
        let text = CallNotifier.callPromptText(source: "Zoom")
        #expect(text.title == "Incoming call — Zoom")
        #expect(text.body == "Cruxwing can capture this meeting. Start recording?")
    }

    @Test("Scheduled reminder names the topic and its lead time")
    func reminderDelineatesScheduledCall() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let text = MeetingReminderScheduler.reminderText(
            title: "Weekly Sync", start: start, minutesBefore: 5)
        #expect(text.title == "Start your scheduled call: Weekly Sync")
        // Lead phrasing is locale-independent; the parenthesised clock time is
        // not asserted because its format depends on the runner's locale.
        #expect(text.body.contains("Starts in 5 min"))
        #expect(text.body.contains("open Cruxwing to record"))
    }

    @Test("The two notifications are unmistakably different")
    func theTwoContextsAreDistinct() {
        // Even when both resolve to the same underlying service, the titles must
        // not collide: one announces a live call, the other an upcoming one.
        let call = CallNotifier.callPromptText(source: "Google Meet")
        let reminder = MeetingReminderScheduler.reminderText(
            title: "Google Meet", start: Date(), minutesBefore: 2)
        #expect(call.title != reminder.title)
        #expect(call.title.localizedCaseInsensitiveContains("incoming call"))
        #expect(reminder.title.localizedCaseInsensitiveContains("scheduled call"))
    }

    @Test("Reminder lead time is clamped to at least one minute")
    func reminderClampsLead() {
        // Mirrors the `max(1, minutesBefore)` clamp the scheduler applies to the
        // fire time, so the copy never claims "Starts in 0 min".
        let text = MeetingReminderScheduler.reminderText(
            title: "Standup", start: Date(), minutesBefore: 0)
        #expect(text.body.contains("Starts in 1 min"))
    }
}
