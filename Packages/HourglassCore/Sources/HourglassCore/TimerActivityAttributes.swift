#if os(iOS)
import ActivityKit
import Foundation

/// Shared Live Activity attributes, compiled by both the iOS app and the widget
/// extension. Kept in the UI-free core (ActivityKit is data-only here) and guarded
/// so the macOS target — which has no ActivityKit — still compiles.
public struct TimerActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var kind: SessionKind
        public var isRunning: Bool
        /// The interval the countdown runs over (start ... end).
        public var timerRange: ClosedRange<Date>
        /// Instant the clock is frozen while paused; nil when running.
        public var pausedAt: Date?

        public init(kind: SessionKind, isRunning: Bool, timerRange: ClosedRange<Date>, pausedAt: Date? = nil) {
            self.kind = kind
            self.isRunning = isRunning
            self.timerRange = timerRange
            self.pausedAt = pausedAt
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
