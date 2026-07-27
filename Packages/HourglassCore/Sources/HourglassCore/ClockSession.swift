import Foundation

/// A non-Pomodoro break taken while clocked in (the "coffee" break).
public struct WorkBreak: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isActive: Bool { endedAt == nil }

    /// Elapsed break time (up to `now` while still running).
    public func duration(asOf now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// One clocked-in stretch of a working day, from clock-in to clock-out,
/// including any non-Pomodoro breaks taken within it.
public struct ClockSession: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var clockedInAt: Date
    public var clockedOutAt: Date?
    public var breaks: [WorkBreak]

    public init(
        id: UUID = UUID(),
        clockedInAt: Date,
        clockedOutAt: Date? = nil,
        breaks: [WorkBreak] = []
    ) {
        self.id = id
        self.clockedInAt = clockedInAt
        self.clockedOutAt = clockedOutAt
        self.breaks = breaks
    }

    public var isActive: Bool { clockedOutAt == nil }

    /// The break currently running, if any.
    public var activeBreak: WorkBreak? { breaks.first(where: \.isActive) }
    public var isOnBreak: Bool { activeBreak != nil }

    /// Wall-clock time from clock-in to clock-out (or `now` while active).
    public func grossDuration(asOf now: Date = Date()) -> TimeInterval {
        max(0, (clockedOutAt ?? now).timeIntervalSince(clockedInAt))
    }

    /// Total time spent on non-Pomodoro breaks.
    ///
    /// A break left running inside a *closed* session is bounded by the
    /// clock-out, so a finished day's numbers never drift with wall-clock time.
    public func breakDuration(asOf now: Date = Date()) -> TimeInterval {
        let end = clockedOutAt ?? now
        return breaks.reduce(0) { $0 + $1.duration(asOf: end) }
    }

    /// Actual worked time — clocked-in time minus breaks.
    public func netDuration(asOf now: Date = Date()) -> TimeInterval {
        max(0, grossDuration(asOf: now) - breakDuration(asOf: now))
    }

    /// How long the running break has lasted so far; 0 when not on a break.
    public func activeBreakDuration(asOf now: Date = Date()) -> TimeInterval {
        activeBreak?.duration(asOf: min(now, clockedOutAt ?? now)) ?? 0
    }

    /// Time at work since the last break ended — or since clocking in, when
    /// there hasn't been a break yet.
    public func timeSinceLastBreak(asOf now: Date = Date()) -> TimeInterval {
        let end = min(now, clockedOutAt ?? now)
        let lastBreakEnd = breaks.compactMap(\.endedAt).max()
        let reference = max(lastBreakEnd ?? clockedInAt, clockedInAt)
        return max(0, end.timeIntervalSince(reference))
    }
}
