import Foundation
import AppKit
import UserNotifications
import HourglassCore

/// Delivers an immediate completion banner (when authorized) and plays a system
/// sound. On macOS the app stays resident in the menu bar, so we notify at the
/// moment of completion rather than scheduling ahead.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = self // must be set before requesting authorization
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func sessionFinished(kind: SessionKind, notify: Bool, playSound: Bool) {
        if notify {
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
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }

        // Play directly too — reliable even if notification sound is suppressed.
        if playSound {
            NSSound(named: kind == .focus ? "Glass" : "Ping")?.play()
        }
    }

    // Show the banner + sound even when Hourglass is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
