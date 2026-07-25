import SwiftUI
import UIKit
import UserNotifications
import HourglassCore

@main
struct HourglassApp: App {
    @State private var model = AppModel()
    @State private var scheduler = NotificationScheduler()
    @State private var liveActivity = LiveActivityController()
    private let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { configureEngineHooks() }
                // Settings and clock state both affect the reminder, so re-apply
                // whenever either changes (not just once per launch).
                .onChange(of: model.settings) { _, _ in refreshReminder() }
                .onChange(of: model.workday.isClockedIn) { _, _ in refreshReminder() }
        }
    }

    private func configureEngineHooks() {
        scheduler.requestAuthorization()

        // Attach to AppModel's forwarding hooks (it owns the engine callbacks so
        // shared behaviour like auto clock-in always runs).
        model.onSessionStarted = { [model, scheduler, liveActivity] kind, secondsRemaining in
            if model.settings.notificationsEnabled {
                scheduler.schedule(after: secondsRemaining, kind: kind, playSound: model.settings.soundEnabled)
            }
            let planned = model.engine.plannedDuration
            Task { @MainActor in await liveActivity.startOrUpdate(kind: kind, secondsRemaining: secondsRemaining, plannedDuration: planned) }
        }

        model.onSessionInterrupted = { [scheduler, liveActivity] ended in
            scheduler.cancel()
            Task { @MainActor in
                if ended { await liveActivity.end() } else { await liveActivity.pause() }
            }
        }

        model.onSessionCompleted = { [model, liveActivity] _ in
            Task { @MainActor in await liveActivity.end() }
            guard model.settings.soundEnabled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        refreshReminder()
    }

    private func refreshReminder() {
        ClockInReminder.apply(settings: model.settings, isClockedIn: model.workday.isClockedIn)
    }
}
