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

    // MARK: Day shape (clock spans)

    private func clock(_ inAt: Date, out outAt: Date? = nil) -> ClockSession {
        ClockSession(clockedInAt: inAt, clockedOutAt: outAt)
    }

    private func span(
        _ spans: [StatisticsCalculator.DailyClockSpan],
        on day: Date
    ) -> StatisticsCalculator.DailyClockSpan? {
        spans.first { utc.isDate($0.date, inSameDayAs: day) }
    }

    @Test func clockSpanForADayStillOnTheClockRunsToNow() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 14).addingTimeInterval(1800) // 14:30
        let sessions = [clock(date(2026, 3, 10, 9))] // never clocked out

        let today = span(calc.dailyClockSpans(in: sessions, lastDays: 7, endingOn: now), on: now)
        #expect(today?.start == date(2026, 3, 10, 9))
        #expect(today?.end == now)
        #expect(today?.startHour == 9)
        #expect(today?.endHour == 14.5)
        #expect(today?.clockInCount == 1)
    }

    @Test func clockSpanRunningPastMidnightShapesBothDays() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 3)
        let sessions = [clock(date(2026, 3, 9, 22))] // opened last night, still open
        let spans = calc.dailyClockSpans(in: sessions, lastDays: 7, endingOn: now)

        let lastNight = span(spans, on: date(2026, 3, 9))
        #expect(lastNight?.startHour == 22)
        #expect(lastNight?.endHour == 24) // clipped at midnight rather than left open
        #expect(lastNight?.clockInCount == 1)

        let today = span(spans, on: now)
        #expect(today?.start == date(2026, 3, 10, 0))
        #expect(today?.startHour == 0)
        #expect(today?.endHour == 3)
        #expect(today?.clockInCount == 0) // carried over instead of starting here
    }

    @Test func clockSpanForAClosedDayEndsAtTheLastClockOut() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 20)
        let lastOut = date(2026, 3, 10, 17).addingTimeInterval(1800) // 17:30
        let sessions = [
            clock(date(2026, 3, 10, 9), out: date(2026, 3, 10, 12)),
            clock(date(2026, 3, 10, 13), out: lastOut),
        ]

        let today = span(calc.dailyClockSpans(in: sessions, lastDays: 7, endingOn: now), on: now)
        #expect(today?.end == lastOut) // not `now`: the day is done
        #expect(today?.startHour == 9)
        #expect(today?.endHour == 17.5)
        #expect(today?.clockInCount == 2)
    }

    @Test func clockSpansCoverTheRangeAndLeaveDaysOffTheClockEmpty() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 18)
        let sessions = [clock(date(2026, 3, 8, 9), out: date(2026, 3, 8, 17))]
        let spans = calc.dailyClockSpans(in: sessions, lastDays: 7, endingOn: now)

        #expect(spans.count == 7)
        #expect(spans.first?.date == utc.startOfDay(for: date(2026, 3, 4)))
        #expect(span(spans, on: date(2026, 3, 8))?.endHour == 17)

        let idle = span(spans, on: now) // a finished day doesn't bleed forward
        #expect(idle?.start == nil)
        #expect(idle?.startHour == nil)
        #expect(idle?.endHour == nil)
        #expect(idle?.clockInCount == 0)
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

    /// Regression: the chart stacked raw focus on top of the rest of the
    /// worked time, so a Pomodoro run while clocked out drew a bar taller than
    /// the worked total printed beside it.
    @Test func aDaysStackedPartsNeverExceedItsWorkedTime() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 18)
        let stats = calc.dailyWorkStats(
            clockSessions: [
                clock(date(2026, 3, 10, 9), out: date(2026, 3, 10, 9).addingTimeInterval(6 * 60)),
            ],
            focusSessions: [focus(date(2026, 3, 10, 14), minutes: 60)],                 // off the clock
            lastDays: 1,
            endingOn: now
        )
        let day = stats[0]

        #expect(day.workedMinutes == 6)
        #expect(day.focusMinutes == 60)
        #expect(day.focusedWorkMinutes == 6)
        #expect(day.focusedWorkMinutes + day.otherMinutes == day.workedMinutes)
        #expect(day.focusShare == 1)
    }

    @Test func focusInsideWorkedTimeIsStackedWhole() {
        let calc = StatisticsCalculator(calendar: utc)
        let stats = calc.dailyWorkStats(
            clockSessions: [clock(date(2026, 3, 10, 9), out: date(2026, 3, 10, 13))], // 4h
            focusSessions: [focus(date(2026, 3, 10, 9), minutes: 50)],
            lastDays: 1,
            endingOn: date(2026, 3, 10, 18)
        )
        let day = stats[0]

        #expect(day.focusedWorkMinutes == 50)
        #expect(day.otherMinutes == 190)
        #expect(day.focusedWorkMinutes + day.otherMinutes == day.workedMinutes)
    }

    // MARK: Range summary

    @Test func aRangeSummaryAveragesOverTheDaysActuallyWorked() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 18)
        let sessions = [
            clock(date(2026, 3, 9, 9), out: date(2026, 3, 9, 13)),  // 4h
            clock(date(2026, 3, 10, 9), out: date(2026, 3, 10, 11)), // 2h
        ]
        let stats = calc.dailyWorkStats(
            clockSessions: sessions,
            focusSessions: [focus(date(2026, 3, 10, 9), minutes: 60)],
            lastDays: 7,
            endingOn: now
        )
        let summary = calc.summary(of: stats)

        #expect(summary.dayCount == 7)
        #expect(summary.daysWorked == 2)              // not 7 — five days were off
        #expect(summary.totalWorked == 6 * 3600)
        #expect(summary.averagePerWorkedDay == 3 * 3600)
        #expect(summary.totalFocus == 3600)
        #expect(summary.focusShare == 1.0 / 6.0)
        #expect(summary.best?.date == utc.startOfDay(for: date(2026, 3, 9)))
    }

    @Test func anEmptyRangeSummarisesToZeroWithoutDividingByIt() {
        let calc = StatisticsCalculator(calendar: utc)
        let stats = calc.dailyWorkStats(
            clockSessions: [], focusSessions: [], lastDays: 7, endingOn: date(2026, 3, 10)
        )
        let summary = calc.summary(of: stats)

        #expect(summary.isEmpty)
        #expect(summary.daysWorked == 0)
        #expect(summary.averagePerWorkedDay == 0)
        #expect(summary.focusShare == 0)
        #expect(summary.best == nil)
    }

    /// Oldest first in, most recent out: a day that equals the record is the
    /// one the user just had, and reading "best day: last Tuesday" would be
    /// telling them the wrong thing about today.
    @Test func aTiedBestDayResolvesToTheMoreRecentOne() {
        let calc = StatisticsCalculator(calendar: utc)
        let now = date(2026, 3, 10, 18)
        let sessions = [
            clock(date(2026, 3, 8, 9), out: date(2026, 3, 8, 13)),
            clock(date(2026, 3, 10, 9), out: date(2026, 3, 10, 13)),
        ]
        let stats = calc.dailyWorkStats(
            clockSessions: sessions, focusSessions: [], lastDays: 7, endingOn: now
        )
        #expect(calc.summary(of: stats).best?.date == utc.startOfDay(for: now))
    }
}
