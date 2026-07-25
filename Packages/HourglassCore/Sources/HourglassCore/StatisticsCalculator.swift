import Foundation

/// Aggregated focus stats for a single day (for charts and summaries).
public struct DailyStat: Sendable, Identifiable, Hashable {
    public let date: Date
    public let focusMinutes: Double
    public let completedSessions: Int
    public var id: Date { date }

    public init(date: Date, focusMinutes: Double, completedSessions: Int) {
        self.date = date
        self.focusMinutes = focusMinutes
        self.completedSessions = completedSessions
    }
}

/// Pure, deterministic statistics over a list of sessions. The calendar and the
/// "current" date are injected so results are fully testable.
public struct StatisticsCalculator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Only completed focus sessions count toward focus statistics.
    private func completedFocus(_ sessions: [FocusSession]) -> [FocusSession] {
        sessions.filter { $0.kind == .focus && $0.completed }
    }

    // MARK: Totals

    public func totalFocusTime(in sessions: [FocusSession], on day: Date) -> TimeInterval {
        completedFocus(sessions)
            .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.plannedDuration }
    }

    public func completedCount(in sessions: [FocusSession], on day: Date) -> Int {
        completedFocus(sessions)
            .filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            .count
    }

    public func totalFocusTimeAllTime(in sessions: [FocusSession]) -> TimeInterval {
        completedFocus(sessions).reduce(0) { $0 + $1.plannedDuration }
    }

    public func totalCompletedAllTime(in sessions: [FocusSession]) -> Int {
        completedFocus(sessions).count
    }

    public func totalFocusTime(in sessions: [FocusSession], inWeekOf day: Date) -> TimeInterval {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: day) else { return 0 }
        return completedFocus(sessions)
            .filter { week.contains($0.startedAt) }
            .reduce(0) { $0 + $1.plannedDuration }
    }

    // MARK: Streak

    /// Number of consecutive days (ending today, or yesterday if nothing yet
    /// today) that have at least one completed focus session.
    public func currentStreak(in sessions: [FocusSession], asOf now: Date) -> Int {
        let days = Set(completedFocus(sessions).map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            // Allow the streak to still be "alive" if the user worked yesterday
            // but not yet today.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: Workday (clock-in/out) statistics

    /// Clock sessions that started on `day`.
    private func sessions(_ all: [ClockSession], on day: Date) -> [ClockSession] {
        all.filter { calendar.isDate($0.clockedInAt, inSameDayAs: day) }
    }

    /// How many times the user clocked in on `day`.
    public func clockInCount(in all: [ClockSession], on day: Date) -> Int {
        sessions(all, on: day).count
    }

    /// How many of those sessions were closed (clocked out).
    public func clockOutCount(in all: [ClockSession], on day: Date) -> Int {
        sessions(all, on: day).filter { !$0.isActive }.count
    }

    /// Seconds of `range` that fall inside `day` (0 if they don't overlap).
    private func overlap(_ range: (start: Date, end: Date), with day: Date) -> TimeInterval {
        guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return 0 }
        let start = max(range.start, dayInterval.start)
        let end = min(range.end, dayInterval.end)
        return max(0, end.timeIntervalSince(start))
    }

    /// Clocked-in time that falls on `day`, so a session spanning midnight is
    /// split across both days rather than counted entirely on its start day.
    private func grossTime(in all: [ClockSession], on day: Date, asOf now: Date) -> TimeInterval {
        all.reduce(0) { total, session in
            total + overlap((session.clockedInAt, session.clockedOutAt ?? now), with: day)
        }
    }

    /// Total non-Pomodoro break time on `day`.
    public func breakTime(in all: [ClockSession], on day: Date, asOf now: Date = Date()) -> TimeInterval {
        all.reduce(0) { total, session in
            let sessionEnd = session.clockedOutAt ?? now
            return total + session.breaks.reduce(0) { breakTotal, entry in
                breakTotal + overlap((entry.startedAt, min(entry.endedAt ?? sessionEnd, sessionEnd)), with: day)
            }
        }
    }

    /// Worked time on `day` — clocked-in time minus non-Pomodoro breaks.
    public func netWorkedTime(in all: [ClockSession], on day: Date, asOf now: Date = Date()) -> TimeInterval {
        max(0, grossTime(in: all, on: day, asOf: now) - breakTime(in: all, on: day, asOf: now))
    }

    // MARK: Daily breakdown (for bar charts)

    /// One entry per day for the last `days` days, oldest first, ending on `now`.
    public func dailyStats(in sessions: [FocusSession], lastDays days: Int, endingOn now: Date) -> [DailyStat] {
        guard days > 0 else { return [] }
        let focus = completedFocus(sessions)
        let today = calendar.startOfDay(for: now)

        return (0..<days).reversed().compactMap { offset -> DailyStat? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let onDay = focus.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            let minutes = onDay.reduce(0.0) { $0 + $1.plannedDuration } / 60.0
            return DailyStat(date: day, focusMinutes: minutes, completedSessions: onDay.count)
        }
    }
}
