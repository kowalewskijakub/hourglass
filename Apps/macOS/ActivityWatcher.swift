import Foundation
import CoreGraphics
import HourglassCore

/// Watches for the user being active at the machine while clocked out, and nudges
/// them to clock in.
///
/// Uses the system-wide idle time (`CGEventSource.secondsSinceLastEventType`),
/// which needs no Accessibility or Input Monitoring permission — we only ever
/// read *how long ago* the last input was, never what it was.
@MainActor
final class ActivityWatcher {
    /// Consider the user "at the machine" if input happened within this window.
    private let activeWithin: TimeInterval = 60
    /// Don't nudge more often than this.
    private let nudgeInterval: TimeInterval = 30 * 60
    /// Require this much continuous presence before the first nudge.
    private let presenceBeforeNudge: TimeInterval = 5 * 60

    private var task: Task<Void, Never>?
    private var activeSince: Date?
    private var lastNudge: Date?
    private var lastTick: Date?

    private let isClockedIn: @MainActor () -> Bool
    private let isEnabled: @MainActor () -> Bool

    init(
        isClockedIn: @escaping @MainActor () -> Bool,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.isClockedIn = isClockedIn
        self.isEnabled = isEnabled
    }

    func start() {
        stop()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        activeSince = nil
    }

    private func tick() {
        let now = Date()
        // If the loop wasn't running contiguously (system sleep, app suspended),
        // the streak isn't observed presence — start counting again from now.
        if let lastTick, now.timeIntervalSince(lastTick) > 3 * 60 {
            activeSince = nil
        }
        lastTick = now

        guard isEnabled(), !isClockedIn() else {
            activeSince = nil // clocked in (or disabled): nothing to nudge about
            return
        }

        let idle = Self.systemIdleSeconds()
        guard idle < activeWithin else {
            activeSince = nil // away from the machine
            return
        }

        let since = activeSince ?? now
        activeSince = since

        guard now.timeIntervalSince(since) >= presenceBeforeNudge else { return }
        if let lastNudge, now.timeIntervalSince(lastNudge) < nudgeInterval { return }

        lastNudge = now
        ClockInReminder.nudgeNow()
    }

    /// Seconds since any user input (mouse, keyboard, trackpad).
    private static func systemIdleSeconds() -> TimeInterval {
        // `~0` is the documented "any event type" wildcard.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }
}
