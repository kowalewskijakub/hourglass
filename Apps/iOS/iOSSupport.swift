import SwiftUI
import UIKit
import UserNotifications
import HourglassCore

/// Schedules a single look-ahead local notification so the user is alerted when
/// a session ends even if the app is backgrounded. Because the engine can
/// auto-start sessions, scheduling is driven off the engine's start/interrupt
/// callbacks rather than button taps.
@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()
    private static let sessionID = "hourglass.session.completion"

    func requestAuthorization() {
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func schedule(after seconds: TimeInterval, kind: SessionKind, playSound: Bool) {
        guard seconds >= 1 else { return }
        let content = UNMutableNotificationContent()
        switch kind {
        case .focus:
            content.title = "Focus complete"
            content.body = "Time for a break."
        case .shortBreak, .longBreak:
            content.title = "Break over"
            content.body = "Ready for another focus session?"
        }
        if playSound { content.sound = .default }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        // Re-adding with the same identifier replaces any pending request.
        let request = UNNotificationRequest(identifier: Self.sessionID, content: content, trigger: trigger)
        center.add(request)
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.sessionID])
    }
}

/// Shows the completion banner + sound even while the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Keeps the screen awake only while a session is running, and never leaves it
/// stuck on after the view disappears.
struct KeepAwake: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, isActive in
                UIApplication.shared.isIdleTimerDisabled = isActive
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = active }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    func keepAwake(_ active: Bool) -> some View { modifier(KeepAwake(active: active)) }
}
