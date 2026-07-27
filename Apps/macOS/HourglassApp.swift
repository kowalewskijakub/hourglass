import SwiftUI
import AppKit
import Observation
import HourglassCore

@main
struct HourglassApp: App {
    @NSApplicationDelegateAdaptor(MacAppController.self) private var controller

    var body: some Scene {
        // The app is a dock-less agent; every window is managed by the controller
        // as a floating AppKit panel (plays nicely with tiling WMs like AeroSpace).
        // This placeholder scene satisfies the App requirement and is never shown.
        Settings { EmptyView() }
    }
}

/// Owns the model and orchestrates the menu-bar status item plus the floating,
/// always-on-top windows. The app stays `.accessory` (no Dock icon) at all times.
@MainActor
final class MacAppController: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var sync: SyncService!
    private let notifier = MacNotifier()
    private var statusItemController: StatusItemController!
    private var activityWatcher: ActivityWatcher!

    private var mainWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var logWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var lastAppliedMode: MacAppMode?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // dock-less, always
        notifier.configure()

        sync = SyncService(model: model)
        model.sync = sync
        Task { await sync.restore() }
        observeWake()

        model.onSessionCompleted = { [weak self] session in
            guard let self else { return }
            notifier.sessionFinished(
                kind: session.kind,
                notify: model.settings.notificationsEnabled,
                playSound: model.settings.soundEnabled
            )
        }

        refreshClockInReminder()
        activityWatcher = ActivityWatcher(
            isClockedIn: { [weak self] in self?.model.workday.isClockedIn ?? true },
            isEnabled: { [weak self] in self?.model.settings.activityNudgeEnabled ?? false }
        )
        activityWatcher.start()

        statusItemController = StatusItemController(engine: model.engine) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(HourglassPanel(model: model, controller: self))
        }

        applyMode()
        observeModel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        reconcileSync()
    }

    /// Realtime can miss events while the Mac sleeps, so re-read on wake.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileSync() }
        }
    }

    private func reconcileSync() {
        guard let sync else { return }
        Task { await sync.refresh() }
    }

    /// In window mode, reopen the timer window if the user closed the last one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, model.settings.macAppMode == .window { openMainWindow() }
        return true
    }

    // MARK: Actions (from the panel)

    func toggleTimer() { model.engine.toggle() }

    func openMainWindow() {
        present(&mainWindow, title: "Hourglass", content: AnyView(HourglassPanel(model: model, controller: self)))
    }

    func openStats() {
        present(&statsWindow, title: "Statistics", size: NSSize(width: 620, height: 560),
                minSize: NSSize(width: 460, height: 420),
                content: AnyView(StatisticsView(model: model)))
    }

    func openLog() {
        present(&logWindow, title: "Log", size: NSSize(width: 520, height: 620),
                minSize: NSSize(width: 400, height: 360),
                content: AnyView(NavigationStack { LogView(model: model) }))
    }

    func openSettings() {
        present(&settingsWindow, title: "Settings", size: NSSize(width: 500, height: 620),
                minSize: NSSize(width: 420, height: 420),
                content: AnyView(SettingsFormView(model: model)))
    }

    func quit() { NSApp.terminate(nil) }

    private func refreshClockInReminder() {
        ClockInReminder.apply(settings: model.settings, isClockedIn: model.workday.isClockedIn)
    }

    // MARK: Floating window helper

    private func present(
        _ window: inout NSWindow?,
        title: String,
        size: NSSize? = nil,
        minSize: NSSize? = nil,
        content: AnyView
    ) {
        if let existing = window {
            bringToFront(existing)
            return
        }
        let contentSize = size ?? NSSize(width: 340, height: 260)
        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = title
        newWindow.isReleasedWhenClosed = false

        let hosting = NSHostingController(rootView: content)
        // Give the hosting view an explicit size so SwiftUI doesn't collapse the
        // window to its minimum intrinsic height when it first appears.
        hosting.view.frame = NSRect(origin: .zero, size: contentSize)
        newWindow.contentViewController = hosting
        newWindow.setContentSize(contentSize)
        if let minSize { newWindow.contentMinSize = minSize }
        if size == nil { newWindow.styleMask.remove(.resizable) } // panel windows stay fixed

        newWindow.level = .floating // always on top
        newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newWindow.center()
        bringToFront(newWindow)
        window = newWindow
    }

    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Mode

    private func applyMode() {
        let mode = model.settings.macAppMode
        switch mode {
        case .menuBar:
            statusItemController.setVisible(true)
            mainWindow?.orderOut(nil)
        case .window:
            statusItemController.setVisible(false)
            openMainWindow()
        }
        lastAppliedMode = mode
    }

    /// Re-applies anything derived from settings or clock state.
    ///
    /// Both are tracked as observable state rather than driven off a callback,
    /// so a clock-in arriving from another device re-applies the reminder too —
    /// a sync-applied change deliberately skips the tracker's hooks.
    ///
    /// Windows are only touched when the mode actually changes, so unrelated
    /// settings edits (durations, sound, …) have no window side effects.
    private func observeModel() {
        withObservationTracking {
            _ = model.settings
            _ = model.workday.isClockedIn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.settings.macAppMode != self.lastAppliedMode { self.applyMode() }
                self.refreshClockInReminder()
                self.observeModel()
            }
        }
    }
}
