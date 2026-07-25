import AppKit
import SwiftUI
import HourglassCore

/// Manages the custom `NSStatusItem`: renders the live minute badge, routes
/// left-click (popover) vs right-click (start/pause), and hosts the popover.
///
/// The badge is drawn by rendering ``MenuBarBadge`` to an `NSImage` each second
/// (research-backed: keeps the `NSStatusBarButton` the sole hit-test target, so
/// click routing stays reliable — an `NSHostingView` subview would fight the
/// macOS 26 Liquid Glass event layer).
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let engine: PomodoroEngine
    private let popover = NSPopover()
    private let makePanel: () -> AnyView
    private var ticker: Task<Void, Never>?
    private var lastSignature = ""

    init(engine: PomodoroEngine, makePanel: @escaping () -> AnyView) {
        self.engine = engine
        self.makePanel = makePanel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        startTicker()
    }

    func setVisible(_ visible: Bool) { statusItem.isVisible = visible }

    // MARK: Clicks

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            engine.toggle()
            renderBadge(force: true)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = NSHostingController(rootView: makePanel())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    // MARK: Badge rendering

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.renderBadge()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func renderBadge(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let time = engine.formattedRemaining // mm:ss
        // Include the resolved appearance so a light/dark switch re-renders the
        // badge (its .primary text is baked into a non-template image).
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let signature = "\(time)|\(engine.kind)|\(isDark)"
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        let badge = MenuBarBadge(time: time, tint: engine.kind.tint)
            .environment(\.colorScheme, isDark ? .dark : .light)

        let renderer = ImageRenderer(content: badge)
        renderer.scale = button.window?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = false // keep the kind colour; don't monochrome
            button.image = image
        }
    }

    deinit { ticker?.cancel() }
}
