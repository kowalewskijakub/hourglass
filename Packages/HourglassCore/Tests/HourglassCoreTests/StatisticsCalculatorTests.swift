import Testing
import Foundation
@testable import HourglassCore

@Suite struct StatisticsCalculatorTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = hour
        return utc.date(from: comps)!
    }

    private func focus(_ start: Date, minutes: Double = 25, completed: Bool = true) -> FocusSession {
        FocusSession(
            kind: .focus,
            plannedDuration: minutes * 60,
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60),
            completed: completed
        )
    }

    @Test func totalFocusTimeCountsOnlyCompletedFocusSessions() {
        let calc = StatisticsCalculator(calendar: utc)
        let day = date(2026, 3, 10)
        let sessions = [
            focus(day, minutes: 25),
            focus(day, minutes: 25),
            focus(day, minutes: 25, completed: false), // excluded: not completed
            FocusSession(kind: .shortBreak, plannedDuration: 300, startedAt: day, endedAt: day, completed: true), // excluded: break
        ]
        #expect(calc.totalFocusTime(in: sessions, on: day) == 50 * 60)
        #expect(calc.completedCount(in: sessions, on: day) == 2)
        #expect(calc.totalCompletedAllTime(in: sessions) == 2)
    }

    @Test func streakCountsConsecutiveDaysEndingToday() {
        let calc = StatisticsCalculator(calendar: utc)
        let today = date(2026, 3, 10)
        let sessions = [
            focus(date(2026, 3, 10)),
            focus(date(2026, 3, 9)),
            focus(date(2026, 3, 8)),
            focus(date(2026, 3, 5)), // gap on the 6th/7th breaks the streak
        ]
        #expect(calc.currentStreak(in: sessions, asOf: today) == 3)
    }

    @Test func streakStaysAliveFromYesterdayWhenNothingToday() {
        let calc = StatisticsCalculator(calendar: utc)
        let today = date(2026, 3, 10, 9)
        let sessions = [focus(date(2026, 3, 9)), focus(date(2026, 3, 8))]
        #expect(calc.currentStreak(in: sessions, asOf: today) == 2)
    }

    @Test func streakIsZeroWhenNewestSessionIsOlderThanYesterday() {
        let calc = StatisticsCalculator(calendar: utc)
        let today = date(2026, 3, 10)
        let sessions = [focus(date(2026, 3, 8))]
        #expect(calc.currentStreak(in: sessions, asOf: today) == 0)
    }

    @Test func dailyStatsReturnsRequestedRangeOldestFirst() {
        let calc = StatisticsCalculator(calendar: utc)
        let today = date(2026, 3, 10)
        let sessions = [
            focus(date(2026, 3, 10)),
            focus(date(2026, 3, 10)),
            focus(date(2026, 3, 8)),
        ]
        let stats = calc.dailyStats(in: sessions, lastDays: 7, endingOn: today)
        #expect(stats.count == 7)
        #expect(stats.last?.completedSessions == 2)  // today, last in oldest-first order
        #expect(stats.last?.focusMinutes == 50)
        let march8 = stats.first { utc.isDate($0.date, inSameDayAs: date(2026, 3, 8)) }
        #expect(march8?.completedSessions == 1)
        #expect(march8?.focusMinutes == 25)
    }

    @Test func weeklyTotalRespectsWeekBoundaries() {
        let calc = StatisticsCalculator(calendar: utc)
        // 2026-03-10 is a Tuesday.
        let inWeek = date(2026, 3, 10)
        let sessions = [
            focus(date(2026, 3, 9)),  // same week (Mon)
            focus(date(2026, 3, 10)), // same week (Tue)
            focus(date(2026, 3, 2)),  // previous week
        ]
        #expect(calc.totalFocusTime(in: sessions, inWeekOf: inWeek) == 50 * 60)
    }
}
