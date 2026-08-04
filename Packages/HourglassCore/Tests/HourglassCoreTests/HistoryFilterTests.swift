import Testing
import Foundation
@testable import HourglassCore

@Suite struct HistoryFilterTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let en = Locale(identifier: "en_US")

    /// 2026-03-10 is a Tuesday.
    private func at(_ day: Int, _ hour: Double) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = day
        return utc.date(from: comps)!.addingTimeInterval(hour * 3600)
    }

    private var now: Date { at(10, 18) }

    private func focus(_ start: Date, minutes: Double = 25, label: String? = nil) -> FocusSession {
        FocusSession(
            kind: .focus,
            plannedDuration: minutes * 60,
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60),
            completed: true,
            taskLabel: label
        )
    }

    private func filter(
        _ text: String = "",
        kinds: Set<HistoryKind> = [],
        range: HistoryRange = .all
    ) -> HistoryFilter {
        HistoryFilter(searchText: text, kinds: kinds, range: range)
    }

    private func apply(_ filter: HistoryFilter, to log: WorkdayLog) -> FilteredHistory {
        log.filtered(by: filter, now: now, calendar: utc, locale: en)
    }

    /// One workday holding a focus session, a Pomodoro break and a manual break.
    private func mixedLog() -> WorkdayLog {
        let pomodoroRest = WorkBreak(startedAt: at(10, 11), endedAt: at(10, 11.1))
        let manualRest = WorkBreak(startedAt: at(10, 13), endedAt: at(10, 13.5))
        let workday = ClockSession(
            clockedInAt: at(10, 9),
            clockedOutAt: at(10, 17),
            breaks: [pomodoroRest, manualRest]
        )
        let phase = FocusSession(
            kind: .shortBreak,
            plannedDuration: 6 * 60,
            startedAt: at(10, 11),
            endedAt: at(10, 11.1),
            completed: true
        )
        return WorkdayLog(
            clockSessions: [workday],
            focusSessions: [focus(at(10, 10)), phase],
            now: now
        )
    }

    // MARK: Kinds

    @Test func everyRowIsClassifiedByWhatOpenedIt() {
        let log = mixedLog()
        let kinds = log.workdays[0].children.map(\.historyKind)
        #expect(Set(kinds) == [.focus, .pomodoroBreak, .manualBreak])
    }

    @Test func anEmptyKindSetFiltersNothing() {
        let log = mixedLog()
        #expect(apply(filter(), to: log).entryCount == 3)
        #expect(filter().isActive == false)
    }

    @Test func kindsNarrowToTheRowsAsked() {
        let log = mixedLog()

        let onlyFocus = apply(filter(kinds: [.focus]), to: log)
        #expect(onlyFocus.entryCount == 1)
        #expect(onlyFocus.groups[0].children.allSatisfy { $0.historyKind == .focus })

        let onlyManual = apply(filter(kinds: [.manualBreak]), to: log)
        #expect(onlyManual.entryCount == 1)
        #expect(onlyManual.focusDuration == 0)
        #expect(onlyManual.breakDuration == 30 * 60)
    }

    /// The section header is the only thing naming the day, so it survives even
    /// when workdays themselves are filtered out — as context, not as a match.
    @Test func aFilteredOutWorkdayStillHeadsItsMatchingRows() {
        let result = apply(filter(kinds: [.focus]), to: mixedLog())

        #expect(result.groups.count == 1)
        #expect(result.groups[0].clockSession != nil)
        #expect(result.groups[0].headerMatches == false)
        #expect(result.workdayCount == 0)
        #expect(result.selectableIDs.count == 1)      // the focus row alone
    }

    @Test func selectingOnlyWorkdaysKeepsTheHeadersAndDropsTheRows() {
        let result = apply(filter(kinds: [.workday]), to: mixedLog())

        #expect(result.entryCount == 0)
        #expect(result.workdayCount == 1)
        #expect(result.groups[0].headerMatches)
        #expect(result.workedDuration == 7.4 * 3600)  // 8h clocked in, 36m rested
    }

    @Test func aWorkdayWithNoMatchesAtAllDisappears() {
        let empty = ClockSession(clockedInAt: at(9, 9), clockedOutAt: at(9, 17))
        let log = WorkdayLog(clockSessions: [empty], focusSessions: [], now: now)

        #expect(apply(filter(kinds: [.focus]), to: log).isEmpty)
        #expect(apply(filter(kinds: [.workday]), to: log).groups.count == 1)
    }

    // MARK: Range

    @Test func trailingRangesCoverWholeDaysEndingTonight() {
        let range = HistoryRange.last7.interval(now: now, calendar: utc)
        #expect(range?.start == at(4, 0))
        #expect(range?.end == at(11, 0))
        #expect(HistoryRange.all.interval(now: now, calendar: utc) == nil)
    }

    @Test func aRangeDropsTheDaysOutsideIt() {
        let old = ClockSession(clockedInAt: at(1, 9), clockedOutAt: at(1, 17))
        let recent = ClockSession(clockedInAt: at(10, 9), clockedOutAt: at(10, 17))
        let log = WorkdayLog(
            clockSessions: [old, recent],
            focusSessions: [focus(at(1, 10)), focus(at(10, 10))],
            now: now
        )

        #expect(apply(filter(range: .all), to: log).entryCount == 2)
        #expect(apply(filter(range: .last7), to: log).entryCount == 1)
        #expect(apply(filter(range: .today), to: log).entryCount == 1)
        #expect(apply(filter(range: .thisMonth), to: log).entryCount == 2)
    }

    /// A stretch that began before the window opened still ran inside it.
    @Test func aRowStraddlingTheRangeBoundaryIsKept() {
        let overnight = ClockSession(clockedInAt: at(9, 22), clockedOutAt: at(10, 6))
        let log = WorkdayLog(clockSessions: [overnight], focusSessions: [], now: now)

        let today = apply(filter(kinds: [.workday], range: .today), to: log)
        #expect(today.workdayCount == 1)
    }

    /// The other end of the same boundary. A day's interval runs *to* the
    /// following midnight, so a row starting exactly as tomorrow begins belongs
    /// to tomorrow — an inclusive end let it count as today's.
    @Test func aRowStartingExactlyAtTheWindowsEndBelongsToTheNextDay() {
        let tomorrow = ClockSession(clockedInAt: at(11, 0), clockedOutAt: at(11, 1))
        let log = WorkdayLog(clockSessions: [tomorrow], focusSessions: [], now: now)

        #expect(apply(filter(kinds: [.workday], range: .today), to: log).workdayCount == 0)
        #expect(apply(filter(kinds: [.workday], range: .all), to: log).workdayCount == 1)
    }

    /// And a zero-length row sitting exactly on midnight is still inside its own
    /// day: the window's start stays inclusive.
    @Test func aZeroLengthRowOnMidnightStaysInsideItsOwnDay() {
        let instant = focus(at(10, 0), minutes: 0)
        let workday = ClockSession(clockedInAt: at(10, 0), clockedOutAt: at(10, 17))
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [instant], now: now)

        #expect(apply(filter(range: .today), to: log).entryCount == 1)
    }

    // MARK: Search

    @Test func searchMatchesKindNamesAndTaskLabels() {
        let workday = ClockSession(clockedInAt: at(10, 9), clockedOutAt: at(10, 17))
        let log = WorkdayLog(
            clockSessions: [workday],
            focusSessions: [focus(at(10, 10), label: "Quarterly report"), focus(at(10, 12))],
            now: now
        )

        #expect(apply(filter("quarterly"), to: log).entryCount == 1)
        #expect(apply(filter("REPORT"), to: log).entryCount == 1)   // case-insensitive
        #expect(apply(filter("focus"), to: log).entryCount == 2)
        #expect(apply(filter("nothing here"), to: log).isEmpty)
    }

    /// Searching for a day means "show me that day", not "show me rows that
    /// happen to repeat the word".
    @Test func searchingADayNameBringsThatDaysRowsThrough() {
        let tuesday = ClockSession(clockedInAt: at(10, 9), clockedOutAt: at(10, 17))
        let wednesday = ClockSession(clockedInAt: at(11, 9), clockedOutAt: at(11, 17))
        let log = WorkdayLog(
            clockSessions: [tuesday, wednesday],
            focusSessions: [focus(at(10, 10)), focus(at(11, 10))],
            now: at(11, 18)
        )

        let result = log.filtered(by: filter("Tuesday"), now: at(11, 18), calendar: utc, locale: en)
        #expect(result.groups.count == 1)
        #expect(result.entryCount == 1)
        #expect(result.groups[0].headerMatches)
    }

    @Test func whitespaceOnlySearchIsNotASearch() {
        #expect(filter("   ").isActive == false)
        #expect(apply(filter("   "), to: mixedLog()).entryCount == 3)
    }

    // MARK: Counts

    @Test func theSummaryReportsWhatWasKeptAndWhatThereWas() {
        let result = apply(filter(kinds: [.focus]), to: mixedLog())

        #expect(result.totalEntryCount == 3)
        #expect(result.entryCount == 1)
        #expect(result.focusDuration == 25 * 60)
        #expect(result.isFiltered)
        #expect(apply(filter(), to: mixedLog()).isFiltered == false)
    }

    // MARK: Resolving a selection

    @Test func selectedIDsResolveToTheRecordsBehindThem() {
        let log = mixedLog()
        let workday = log.workdays[0].clockSession!
        let session = log.workdays[0].children.first { $0.historyKind == .focus }!
        let manual = log.workdays[0].children.first { $0.historyKind == .manualBreak }!

        let targets = log.targets(for: [session.id, manual.id])
        #expect(targets.count == 2)
        #expect(targets.contains(.session(session.id)))
        #expect(targets.contains(.workBreak(sessionID: workday.id, entryID: manual.id)))
    }

    /// Deleting the workday takes its breaks with it; asking the tracker to
    /// delete them separately is a write against a session that is already gone.
    @Test func aBreakInsideASelectedWorkdayIsNotDeletedTwice() {
        let log = mixedLog()
        let workday = log.workdays[0].clockSession!
        let manual = log.workdays[0].children.first { $0.historyKind == .manualBreak }!
        let session = log.workdays[0].children.first { $0.historyKind == .focus }!

        let targets = log.targets(for: [workday.id, manual.id, session.id])
        #expect(targets.contains(.clockSession(workday.id)))
        #expect(targets.contains(.session(session.id)))     // its own store, survives
        #expect(!targets.contains(.workBreak(sessionID: workday.id, entryID: manual.id)))
        #expect(targets.count == 2)
    }

    /// A Pomodoro rest is one row standing for two records. Resolving only the
    /// interval left the phase in history with nothing to absorb it, and the log
    /// put it straight back as a standalone break row — so Delete did nothing
    /// the user could see.
    @Test func deletingAPomodoroRestTakesThePhasePairedIntoItsRow() {
        let log = mixedLog()
        let workday = log.workdays[0].clockSession!
        let rest = log.workdays[0].children.first { $0.historyKind == .pomodoroBreak }!

        let targets = log.targets(for: [rest.id])
        #expect(targets.contains(.workBreak(sessionID: workday.id, entryID: rest.id)))
        #expect(targets.count == 2)
        guard case .session(let phaseID)? = targets.first(where: {
            if case .session = $0 { return true } else { return false }
        }) else { return #expect(Bool(false), "the paired phase was not resolved") }

        // And with both applied, the row is actually gone.
        var stripped = workday
        stripped.breaks.removeAll { $0.id == rest.id }
        let after = WorkdayLog(
            clockSessions: [stripped],
            focusSessions: [focus(at(10, 10))].filter { $0.id != phaseID },
            now: now
        )
        #expect(after.workdays[0].children.contains { $0.historyKind == .pomodoroBreak } == false)
    }

    /// A manual rest has no phase behind it, so its row resolves to one record.
    @Test func deletingAManualRestTouchesNothingElse() {
        let log = mixedLog()
        let manual = log.workdays[0].children.first { $0.historyKind == .manualBreak }!
        #expect(log.targets(for: [manual.id]).count == 1)
    }

    @Test func unknownIDsResolveToNothing() {
        #expect(mixedLog().targets(for: [UUID()]).isEmpty)
    }

    // MARK: Exporting a subset

    @Test func exportingASubsetWritesOnlyTheSelectedRows() {
        let log = mixedLog()
        let session = log.workdays[0].children.first { $0.historyKind == .focus }!

        let all = log.exportCSV().split(separator: "\n")
        let subset = log.exportCSV(ids: [session.id]).split(separator: "\n")

        #expect(all.count > subset.count)
        #expect(subset.count == 2)                       // header + one row
        #expect(subset[1].hasPrefix("focus,"))
    }

    @Test func exportingWithNoSelectionWritesNothingButTheHeader() {
        #expect(mixedLog().exportCSV(ids: []).split(separator: "\n").count == 1)
    }
}
