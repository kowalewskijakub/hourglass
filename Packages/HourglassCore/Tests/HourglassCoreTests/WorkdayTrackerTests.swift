import Testing
import Foundation
@testable import HourglassCore

@MainActor
@Suite struct WorkdayTrackerTests {

    private func makeTracker() -> (WorkdayTracker, InMemoryWorkdayStore, TestClock) {
        let store = InMemoryWorkdayStore()
        let clock = TestClock()
        return (WorkdayTracker(store: store, clock: clock), store, clock)
    }

    @Test func startsClockedOut() {
        let (tracker, _, _) = makeTracker()
        #expect(tracker.isClockedIn == false)
        #expect(tracker.isOnBreak == false)
        #expect(tracker.currentSession == nil)
    }

    @Test func clockInThenOutRecordsTheSession() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        #expect(tracker.isClockedIn)

        clock.jump(by: 3600) // an hour of work
        tracker.clockOut()

        #expect(tracker.isClockedIn == false)
        let sessions = store.all()
        #expect(sessions.count == 1)
        #expect(sessions.first?.isActive == false)
        #expect(sessions.first?.grossDuration() == 3600)
        #expect(sessions.first?.netDuration() == 3600) // no breaks
    }

    @Test func clockingInTwiceDoesNotStartASecondSession() {
        let (tracker, store, _) = makeTracker()
        tracker.clockIn()
        tracker.clockIn()
        #expect(store.all().count == 1)
    }

    @Test func breaksSubtractFromNetWorkedTime() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        clock.jump(by: 1800)      // 30 min worked
        tracker.startBreak()
        #expect(tracker.isOnBreak)
        clock.jump(by: 600)       // 10 min break
        tracker.endBreak()
        #expect(tracker.isOnBreak == false)
        clock.jump(by: 1800)      // 30 min more
        tracker.clockOut()

        let session = store.all().first
        #expect(session?.grossDuration() == 4200)  // 70 min clocked in
        #expect(session?.breakDuration() == 600)   // 10 min on break
        #expect(session?.netDuration() == 3600)    // 60 min actually worked
    }

    @Test func clockingOutClosesARunningBreak() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        clock.jump(by: 300)
        tracker.clockOut() // break still running

        let session = store.all().first
        #expect(session?.isOnBreak == false)
        #expect(session?.breaks.first?.endedAt != nil)
        #expect(session?.breakDuration() == 300)
    }

    @Test func startingABreakWhileClockedOutClocksInFirst() {
        let (tracker, store, _) = makeTracker()
        tracker.startBreak()
        #expect(tracker.isClockedIn)
        #expect(tracker.isOnBreak)
        #expect(store.all().count == 1)
    }

    // MARK: A Pomodoro started

    @Test func focusSessionClocksInWhenClockedOut() {
        let (tracker, store, _) = makeTracker()
        tracker.sessionStarted(kind: .focus)
        #expect(tracker.isClockedIn)
        #expect(store.all().count == 1)
    }

    @Test func breakSessionDoesNotClockIn() {
        let (tracker, store, _) = makeTracker()
        tracker.sessionStarted(kind: .shortBreak)
        #expect(tracker.isClockedIn == false)
        #expect(store.all().isEmpty)
    }

    /// Starting any timer means you're back at it, so a running coffee break is
    /// closed rather than left charging break time against the work you're doing.
    @Test func startingATimerEndsARunningBreak() {
        let (tracker, _, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        #expect(tracker.isOnBreak)

        clock.jump(by: 300)
        tracker.sessionStarted(kind: .focus)

        #expect(tracker.isOnBreak == false)
        #expect(tracker.isClockedIn)
        #expect(tracker.currentSession?.breakDuration() == 300)
    }

    /// A break timer ends a coffee break too, without clocking in on its own.
    @Test func startingABreakTimerEndsARunningBreak() {
        let (tracker, _, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()

        clock.jump(by: 120)
        tracker.sessionStarted(kind: .longBreak)

        #expect(tracker.isOnBreak == false)
        #expect(tracker.currentSession?.breakDuration() == 120)
    }

    @Test func focusSessionWhileAlreadyClockedInDoesNotStartASecondSession() {
        let (tracker, store, _) = makeTracker()
        tracker.clockIn()
        tracker.sessionStarted(kind: .focus)
        #expect(store.all().count == 1)
    }

    @Test func toggleDrivesClockAndBreak() {
        let (tracker, _, _) = makeTracker()
        tracker.toggleClock()
        #expect(tracker.isClockedIn)
        tracker.toggleBreak()
        #expect(tracker.isOnBreak)
        tracker.toggleBreak()
        #expect(tracker.isOnBreak == false)
        tracker.toggleClock()
        #expect(tracker.isClockedIn == false)
    }

    /// Regression: a closed day whose break was left running must report a
    /// stable duration — it used to decay toward zero with wall-clock time.
    @Test func closedSessionWithRunningBreakHasStableDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ClockSession(
            clockedInAt: start,
            clockedOutAt: start.addingTimeInterval(8 * 3600),
            breaks: [WorkBreak(startedAt: start.addingTimeInterval(6 * 3600))] // never ended
        )
        let atClockOut = session.netDuration(asOf: start.addingTimeInterval(8 * 3600))
        let threeDaysLater = session.netDuration(asOf: start.addingTimeInterval(72 * 3600))
        #expect(atClockOut == threeDaysLater)
        #expect(session.breakDuration() == 2 * 3600) // bounded by the clock-out
        #expect(session.netDuration() == 6 * 3600)
    }

    /// Regression: editing a session closed in the log must also close a break
    /// left running inside it.
    @Test func editingASessionClosedNormalizesRunningBreaks() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        let session = tracker.currentSession!
        clock.jump(by: 3600)

        // Simulate the log editor closing the day while the break still runs.
        tracker.updateClockSession(id: session.id, clockedInAt: session.clockedInAt, clockedOutAt: clock.now)

        let stored = store.all().first
        #expect(stored?.isActive == false)
        #expect(stored?.isOnBreak == false)
        #expect(stored?.breaks.first?.endedAt == stored?.clockedOutAt)
    }

    /// Regression: a session left open from a previous day must not swallow
    /// today's clock-in — it's closed off at the end of its own day instead.
    @Test func clockingInClosesAForgottenSessionFromAnEarlierDay() {
        let store = InMemoryWorkdayStore()
        let clock = TestClock()
        let old = ClockSession(clockedInAt: clock.now.addingTimeInterval(-86_400)) // yesterday, still open
        store.add(old)
        let tracker = WorkdayTracker(store: store, clock: clock)

        tracker.clockIn() // today

        let stale = store.all().first { $0.id == old.id }
        #expect(stale?.isActive == false)                       // auto-closed
        #expect(stale?.clockedOutAt ?? .distantFuture <= clock.now)
        #expect(tracker.currentSession?.id != old.id)           // today's is separate
        #expect(store.all().filter(\.isActive).count == 1)      // exactly one open
    }

    /// Regression: a session spanning midnight splits across both days.
    @Test func workedTimeSplitsAcrossMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let calc = StatisticsCalculator(calendar: cal)
        let dayOne = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 22))!
        let dayTwo = cal.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 12))!

        // 22:00 -> 02:00: two hours on the 10th, two on the 11th.
        let session = ClockSession(clockedInAt: dayOne, clockedOutAt: dayOne.addingTimeInterval(4 * 3600))
        #expect(calc.netWorkedTime(in: [session], on: dayOne) == 2 * 3600)
        #expect(calc.netWorkedTime(in: [session], on: dayTwo) == 2 * 3600)
    }

    /// Ending the break is what stops break time accruing while you work — the
    /// app calls this whenever a Pomodoro starts, including when idle.
    @Test func endingABreakStopsItAccruingAndIsSafeWhenThereIsNone() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        clock.jump(by: 300)
        tracker.endBreak()

        // Break is closed, so further time counts as worked, not break.
        clock.jump(by: 600)
        let session = store.all().first
        #expect(session?.isOnBreak == false)
        #expect(session?.breakDuration(asOf: clock.now) == 300)
        // 900s clocked in, 300s of it on a break -> 600s actually worked.
        #expect(session?.netDuration(asOf: clock.now) == 600)

        // Calling it again — as the app does on every start — changes nothing.
        tracker.endBreak()
        #expect(store.all().first?.breakDuration(asOf: clock.now) == 300)

        // And it's harmless when clocked out entirely.
        tracker.clockOut()
        tracker.endBreak()
        #expect(store.all().count == 1)
    }

    /// Regression: a stale copy arriving from another device must not undo a
    /// newer local edit — that is what made log edits look like they "didn't
    /// work" when in fact sync overwrote them.
    @Test func remoteCopyOnlyWinsWhenItIsNewer() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let local = tracker.currentSession!

        // A stale copy of the same session, still open, from before our edit.
        var stale = local
        stale.clockedOutAt = nil
        stale.updatedAt = clock.now.addingTimeInterval(-3600)

        clock.jump(by: 60)
        tracker.clockOut()                       // local edit: now closed
        tracker.applyRemote(stale)               // stale arrives
        #expect(store.all().first?.isActive == false) // local edit survives

        // A genuinely newer copy is accepted.
        var fresher = local
        fresher.clockedOutAt = nil
        fresher.updatedAt = clock.now.addingTimeInterval(3600)
        tracker.applyRemote(fresher)
        #expect(store.all().first?.isActive == true)
    }

    @Test func activeBreakDurationCountsFromTheBreakStart() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ClockSession(
            clockedInAt: start,
            breaks: [WorkBreak(startedAt: start.addingTimeInterval(1800))] // break at +30m
        )
        // 7 minutes into the break.
        #expect(session.activeBreakDuration(asOf: start.addingTimeInterval(1800 + 420)) == 420)
        // No running break -> zero.
        let noBreak = ClockSession(clockedInAt: start)
        #expect(noBreak.activeBreakDuration(asOf: start.addingTimeInterval(600)) == 0)
    }

    @Test func timeSinceLastBreakFallsBackToClockIn() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // No break yet: measured from clock-in.
        let fresh = ClockSession(clockedInAt: start)
        #expect(fresh.timeSinceLastBreak(asOf: start.addingTimeInterval(900)) == 900)

        // After a break: measured from when that break ended.
        let afterBreak = ClockSession(
            clockedInAt: start,
            breaks: [WorkBreak(startedAt: start.addingTimeInterval(600),
                               endedAt: start.addingTimeInterval(900))]
        )
        #expect(afterBreak.timeSinceLastBreak(asOf: start.addingTimeInterval(1500)) == 600)
    }

    // MARK: Editing from the log

    /// The log's sheet holds a copy of the session from the moment it opened.
    /// Anything that changed since — a break started here, a clock-out mirrored
    /// from another device — must survive the save.
    @Test func editingTheClockStampsKeepsBreaksTakenWhileTheSheetWasOpen() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let asTheSheetSawIt = tracker.currentSession!
        #expect(asTheSheetSawIt.breaks.isEmpty)

        // A break happens while the sheet sits open.
        clock.jump(by: 600)
        tracker.startBreak()
        clock.jump(by: 300)
        tracker.endBreak()

        // The sheet saves the one field the user moved.
        let correctedStart = asTheSheetSawIt.clockedInAt.addingTimeInterval(-1800)
        tracker.updateClockSession(id: asTheSheetSawIt.id, clockedInAt: correctedStart, clockedOutAt: nil)

        let stored = store.all().first
        #expect(stored?.clockedInAt == correctedStart)
        #expect(stored?.breaks.count == 1)
        #expect(stored?.breakDuration(asOf: clock.now) == 300)
    }

    /// Every edit goes through the same write path as the live clock, so other
    /// devices hear about it and can tell whose copy is newer.
    @Test func editsStampUpdatedAtAndAnnounceTheChange() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let session = tracker.currentSession!

        var announced: [ClockSession] = []
        tracker.onSessionChanged = { announced.append($0) }

        clock.jump(by: 3600)
        tracker.updateClockSession(id: session.id, clockedInAt: session.clockedInAt, clockedOutAt: clock.now)

        #expect(announced.count == 1)
        #expect(announced.first?.id == session.id)
        #expect(store.all().first?.updatedAt == clock.now)
    }

    /// The log's date pickers are unbounded, so a day can be saved ending before
    /// it starts; it's clamped to no length rather than negative time.
    @Test func aClockOutBeforeTheClockInIsClampedToTheClockIn() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let session = tracker.currentSession!

        tracker.updateClockSession(
            id: session.id,
            clockedInAt: session.clockedInAt,
            clockedOutAt: session.clockedInAt.addingTimeInterval(-3600)
        )

        let stored = store.all().first
        #expect(stored?.clockedOutAt == stored?.clockedInAt)
        #expect(stored?.grossDuration(asOf: clock.now) == 0)
        #expect(stored?.netDuration(asOf: clock.now) == 0)
    }

    @Test func editingABreakLeavesTheRestOfTheSessionAlone() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        clock.jump(by: 300)
        tracker.endBreak()
        let session = store.all().first!
        var entry = session.breaks[0]

        var announced = 0
        tracker.onSessionChanged = { _ in announced += 1 }

        entry.endedAt = entry.startedAt.addingTimeInterval(900) // it ran longer than logged
        tracker.updateBreak(sessionID: session.id, entry: entry)

        let stored = store.all().first
        #expect(stored?.breaks.count == 1)
        #expect(stored?.breakDuration(asOf: clock.now) == 900)
        #expect(stored?.clockedInAt == session.clockedInAt)
        #expect(announced == 1)
    }

    @Test func deletingABreakRemovesOnlyThatBreak() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        clock.jump(by: 300)
        tracker.endBreak()
        clock.jump(by: 600)
        tracker.startBreak()
        clock.jump(by: 120)
        tracker.endBreak()

        let session = store.all().first!
        #expect(session.breaks.count == 2)
        tracker.deleteBreak(sessionID: session.id, entryID: session.breaks[0].id)

        let stored = store.all().first
        #expect(stored?.breaks.map(\.id) == [session.breaks[1].id])
        #expect(stored?.breakDuration(asOf: clock.now) == 120)
    }

    /// An edit aimed at something that is no longer there (deleted here, or on
    /// another device) does nothing rather than resurrecting it.
    @Test func editsAgainstAMissingRecordAreIgnored() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let session = tracker.currentSession!

        var announced = 0
        tracker.onSessionChanged = { _ in announced += 1 }

        tracker.updateClockSession(id: UUID(), clockedInAt: clock.now, clockedOutAt: clock.now)
        tracker.updateBreak(sessionID: session.id, entry: WorkBreak(startedAt: clock.now))
        tracker.deleteBreak(sessionID: session.id, entryID: UUID())

        #expect(announced == 0)
        #expect(store.all().count == 1)
        #expect(store.all().first?.breaks.isEmpty == true)
    }

    @Test func statisticsCountClockInsAndNetTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let calc = StatisticsCalculator(calendar: cal)
        let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!

        let sessions = [
            ClockSession(
                clockedInAt: day,
                clockedOutAt: day.addingTimeInterval(3600),
                breaks: [WorkBreak(startedAt: day.addingTimeInterval(600),
                                   endedAt: day.addingTimeInterval(1200))] // 10 min
            ),
            ClockSession(
                clockedInAt: day.addingTimeInterval(7200),
                clockedOutAt: day.addingTimeInterval(9000)
            ),
        ]

        #expect(calc.clockInCount(in: sessions, on: day) == 2)
        #expect(calc.clockOutCount(in: sessions, on: day) == 2)
        #expect(calc.breakTime(in: sessions, on: day) == 600)
        #expect(calc.netWorkedTime(in: sessions, on: day) == 3600 - 600 + 1800)
    }
}
