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

    /// A day's worked time alongside how much of it was spent in Pomodoro focus.
    public struct DailyWorkStat: Sendable, Identifiable, Hashable {
        public let date: Date
        public let workedMinutes: Double
        public let focusMinutes: Double
        public var id: Date { date }

        /// Share of the worked time that was focused, 0...1.
        public var focusShare: Double {
            guard workedMinutes > 0 else { return 0 }
            return min(1, focusMinutes / workedMinutes)
        }

        /// Worked time that wasn't inside a Pomodoro, for stacking on a chart.
        public var otherMinutes: Double { max(0, workedMinutes - focusMinutes) }
    }

    /// Worked vs focused time per day, oldest first.
    public func dailyWorkStats(
        clockSessions: [ClockSession],
        focusSessions: [FocusSession],
        lastDays days: Int,
        endingOn now: Date
    ) -> [DailyWorkStat] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let worked = netWorkedTime(in: clockSessions, on: day, asOf: now) / 60
            let focused = totalFocusTime(in: focusSessions, on: day) / 60
            return DailyWorkStat(date: day, workedMinutes: worked, focusMinutes: focused)
        }
    }

    /// When a day started and ended on the clock, and how many times it was
    /// clocked into.
    ///
    /// Both instants are already resolved against the `now` the span was built
    /// for, so a chart plots `startHour`/`endHour` as-is. Resolving here rather
    /// than at draw time is what keeps a still-running day agreeing with the
    /// worked-time headline instead of each reading the clock separately.
    public struct DailyClockSpan: Sendable, Identifiable, Hashable {
        public let date: Date
        /// First moment of this day spent on the clock; nil on a day off it.
        public let start: Date?
        /// Last moment on the clock — `now` on a day still running, midnight
        /// when the stretch carries on into the next day.
        public let end: Date?
        /// Hours past this day's midnight, ready to use as a chart axis value.
        /// `endHour` reaches 24 when the day never clocked out.
        public let startHour: Double?
        public let endHour: Double?
        /// How many stretches *began* on this day, so a carried-over stretch
        /// isn't counted twice; 0 on a day that only inherited one.
        public let clockInCount: Int
        public var id: Date { date }
    }

    /// The shape of each of the last `days` days on the clock, oldest first.
    ///
    /// Days are filled by overlap, the way `grossTime` does it, so a stretch
    /// running past midnight shapes both days instead of leaving the second one
    /// blank. A day still on the clock ends at `now`, which is also later than
    /// any earlier clock-out that day.
    public func dailyClockSpans(
        in all: [ClockSession],
        lastDays days: Int,
        endingOn now: Date
    ) -> [DailyClockSpan] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayInterval = calendar.dateInterval(of: .day, for: day) else { return nil }

            let clipped = all.compactMap { session -> (start: Date, end: Date)? in
                let start = max(session.clockedInAt, dayInterval.start)
                let end = min(session.clockedOutAt ?? now, dayInterval.end)
                return end > start ? (start, end) : nil
            }
            let start = clipped.map(\.start).min()
            let end = clipped.map(\.end).max()
            return DailyClockSpan(
                date: day,
                start: start,
                end: end,
                startHour: hours(from: dayInterval.start, to: start),
                endHour: hours(from: dayInterval.start, to: end),
                clockInCount: clockInCount(in: all, on: day)
            )
        }
    }

    /// Hours from `dayStart` to `instant`. Measured from the day rather than
    /// from the instant's own midnight so a stretch clipped at midnight lands
    /// at hour 24 of the day it belongs to, not hour 0 of the next one.
    private func hours(from dayStart: Date, to instant: Date?) -> Double? {
        guard let instant else { return nil }
        return instant.timeIntervalSince(dayStart) / 3600
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
