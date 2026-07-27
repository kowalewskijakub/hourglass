#if os(iOS)
import ActivityKit
import Foundation

/// Shared Live Activity attributes, compiled by both the iOS app and the widget
/// extension. Kept in the UI-free core (ActivityKit is data-only here) and guarded
/// so the macOS target — which has no ActivityKit — still compiles.
public struct TimerActivityAttributes: ActivityAttributes, Sendable {

    /// What the activity is currently reporting.
    public enum Mode: String, Codable, Hashable, Sendable {
        /// A Pomodoro session is running or paused — show its countdown.
        case timer
        /// Clocked in with no Pomodoro running — count the working stretch up.
        case clockedIn
        /// On a non-Pomodoro break — count the break up.
        case onBreak
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var mode: Mode
        public var kind: SessionKind
        public var isRunning: Bool
        /// The interval the countdown runs over (start ... end). Only meaningful
        /// in `.timer` mode.
        public var timerRange: ClosedRange<Date>
        /// Instant the clock is frozen while paused; nil when running.
        public var pausedAt: Date?
        /// When the current clocked-in stretch or break began, so the widget can
        /// count up from it without any further updates.
        public var since: Date?

        public init(
            mode: Mode = .timer,
            kind: SessionKind,
            isRunning: Bool,
            timerRange: ClosedRange<Date>,
            pausedAt: Date? = nil,
            since: Date? = nil
        ) {
            self.mode = mode
            self.kind = kind
            self.isRunning = isRunning
            self.timerRange = timerRange
            self.pausedAt = pausedAt
            self.since = since
        }

        /// Elapsed fraction (0…1) for a static progress bar while paused.
        public var pausedFraction: Double {
            let total = timerRange.upperBound.timeIntervalSince(timerRange.lowerBound)
            guard total > 0, let pausedAt else { return 0 }
            let elapsed = pausedAt.timeIntervalSince(timerRange.lowerBound)
            return min(max(elapsed / total, 0), 1)
        }
    }

    public init() {}
}
#endif
