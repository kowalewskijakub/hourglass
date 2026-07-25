import Foundation
import UserNotifications
import HourglassCore

/// Schedules the daily "time to clock in" notification. Shared by both platforms;
/// the request repeats daily and is cancelled when the reminder is switched off.
@MainActor
enum ClockInReminder {
    private static let identifier = "hourglass.clockin.reminder"

    /// Re-applies the reminder from settings. Call at launch, whenever settings
    /// change, and whenever the clock state changes — while you're clocked in
    /// there's nothing to remind you about, so the request is withdrawn.
    static func apply(settings: TimerSettings, isClockedIn: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard settings.clockInReminderEnabled, !isClockedIn else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ready to start?"
        content.body = "Clock in to begin tracking your day."
        content.sound = .default

        var components = DateComponents()
        components.hour = settings.clockInReminderHour
        components.minute = settings.clockInReminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// A one-off nudge (used by the macOS activity watcher).
    static func nudgeNow(body: String = "You're active but clocked out — want to clock in?") {
        let content = UNMutableNotificationContent()
        content.title = "Still working?"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
