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
    private let notifier = MacNotifier()
    private var statusItemController: StatusItemController!

    private var mainWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var logWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var lastAppliedMode: MacAppMode?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // dock-less, always
        notifier.configure()

        model.engine.onSessionCompleted = { [weak self] session in
            guard let self else { return }
            notifier.sessionFinished(
                kind: session.kind,
                notify: model.settings.notificationsEnabled,
                playSound: model.settings.soundEnabled
            )
        }

        statusItemController = StatusItemController(engine: model.engine) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(HourglassPanel(model: model, controller: self))
        }

        applyMode()
        observeSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
        present(&statsWindow, title: "Statistics", size: NSSize(width: 560, height: 460),
                content: AnyView(StatisticsView(model: model)))
    }

    func openLog() {
        present(&logWindow, title: "Log", size: NSSize(width: 480, height: 520),
                content: AnyView(NavigationStack { LogView(model: model) }))
    }

    func openSettings() {
        present(&settingsWindow, title: "Settings", size: NSSize(width: 460, height: 460),
                content: AnyView(SettingsFormView(model: model)))
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: Floating window helper

    private func present(_ window: inout NSWindow?, title: String, size: NSSize? = nil, content: AnyView) {
        if let existing = window {
            bringToFront(existing)
            return
        }
        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 280, height: 420)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = title
        newWindow.isReleasedWhenClosed = false
        newWindow.contentViewController = NSHostingController(rootView: content)
        if size == nil { newWindow.styleMask.remove(.resizable) } // panel-sized windows stay fixed
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

    /// Only touch windows when the mode actually changes, so unrelated settings
    /// edits (durations, sound, …) have no window side effects.
    private func observeSettings() {
        withObservationTracking {
            _ = model.settings.macAppMode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.settings.macAppMode != self.lastAppliedMode { self.applyMode() }
                self.observeSettings()
            }
        }
    }
}
