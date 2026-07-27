import SwiftUI
import UIKit
import UserNotifications
import HourglassCore

@main
struct HourglassApp: App {
    @State private var model: AppModel
    @State private var scheduler = NotificationScheduler()
    @State private var liveActivity = LiveActivityController()
    @State private var sync: SyncService
    private let notificationDelegate = NotificationDelegate()

    init() {
        let model = AppModel()
        let sync = SyncService(model: model)
        model.sync = sync
        _model = State(initialValue: model)
        _sync = State(initialValue: sync)
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // Must be registered before launch finishes.
        let activity = LiveActivityController()
        _liveActivity = State(initialValue: activity)
        BackgroundRefresh.register {
            await sync.refresh()
            await activity.sync(engine: model.engine, workday: model.workday)
        }
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
        model.onSessionStarted = { [model, scheduler] kind, secondsRemaining in
            if model.settings.notificationsEnabled {
                scheduler.schedule(after: secondsRemaining, kind: kind, playSound: model.settings.soundEnabled)
            }
            refreshLiveActivity()
        }

        model.onSessionInterrupted = { [scheduler] _ in
            scheduler.cancel()
            refreshLiveActivity()
        }

        model.onSessionCompleted = { [model] _ in
            refreshLiveActivity()
            guard model.settings.soundEnabled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        // Clocking in/out and breaks drive the activity too — including changes
        // arriving from another device.
        model.onWorkdayChanged = { refreshLiveActivity() }

        refreshReminder()
        refreshLiveActivity()
        BackgroundRefresh.schedule()
        Task { await sync.restore() }
    }

    /// Recomputes the Live Activity from the current timer and clock state.
    private func refreshLiveActivity() {
        Task { @MainActor in
            await liveActivity.sync(engine: model.engine, workday: model.workday)
        }
    }

    private func refreshReminder() {
        ClockInReminder.apply(settings: model.settings, isClockedIn: model.workday.isClockedIn)
    }
}
