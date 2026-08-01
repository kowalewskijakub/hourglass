import AppKit
import SwiftUI
import HourglassCore

/// Manages the single `NSStatusItem`: renders the resolved badge and opens or
/// closes the Orbit panel.
///
/// Clicking the item does **one** thing — toggle the panel. It never starts,
/// pauses, resumes, skips, breaks or clocks out; a menu-bar item that changed the
/// timer on a stray click was a way to lose a Pomodoro without noticing.
///
/// The badge is drawn by rendering ``MenuBarBadge`` into an `NSImage` rather than
/// hosting a SwiftUI view, which keeps the `NSStatusBarButton` the only
/// hit-test target and the click routing reliable under Liquid Glass.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let popover = NSPopover()
    private let makePanel: () -> AnyView
    private var ticker: Task<Void, Never>?
    private var lastSignature = ""

    init(model: AppModel, makePanel: @escaping () -> AnyView) {
        self.model = model
        self.makePanel = makePanel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render(force: true)
        startTicker()
        observeState()
    }

    /// The cadence only decides how often a *running* number is repainted. A
    /// change of state — clocking in, a phase pausing, a break arriving from
    /// another device — must show at once, not on the next tick, which is what
    /// this observation is for.
    private func observeState() {
        withObservationTracking {
            _ = model.engine.phase
            _ = model.engine.cyclePosition
            _ = model.workday.isClockedIn
            _ = model.workday.isOnBreak
            _ = model.coordinator.linkedBreak
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.render()
                self.observeState()
            }
        }
    }

    func setVisible(_ visible: Bool) { statusItem.isVisible = visible }

    // MARK: Clicks

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = NSHostingController(rootView: makePanel())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePanel() { popover.performClose(nil) }

    // MARK: Rendering

    /// One timer at the finest cadence any state needs, with the redraw itself
    /// gated on the resolved cadence and a content signature. A paused phase
    /// therefore costs nothing, and a clocked-out item costs nothing at all —
    /// the tick still runs, but it neither recomputes nor redraws.
    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            var lastCadence: MenuBarCadence = .second
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(lastCadence == .second ? 1 : 15))
                guard let self else { return }
                lastCadence = render()
            }
        }
    }

    /// Re-render if anything visible changed. Returns the cadence this state
    /// wants, so the ticker can slow down for the states that do not move.
    @discardableResult
    func render(force: Bool = false) -> MenuBarCadence {
        guard let button = statusItem.button else { return .none }
        let badge = model.orbitPresentation(surface: .panel).menuBarBadge

        // The resolved appearance is part of the signature because `.primary`
        // ink is baked into a non-template image; a light/dark switch has to
        // redraw even when the value has not moved.
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let signature = "\(badge.mark.rawValue)|\(badge.value ?? "")|\(isDark)"
        guard force || signature != lastSignature else { return badge.cadence }
        lastSignature = signature

        let renderer = ImageRenderer(
            content: MenuBarBadge(badge: badge, isDarkMenuBar: isDark)
                .environment(\.colorScheme, isDark ? .dark : .light)
        )
        renderer.scale = button.window?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = false // keep ember and stone; do not monochrome
            button.image = image
        }
        button.setAccessibilityLabel(badge.accessibilityLabel)
        button.toolTip = badge.accessibilityLabel
        return badge.cadence
    }

    deinit { ticker?.cancel() }
}
