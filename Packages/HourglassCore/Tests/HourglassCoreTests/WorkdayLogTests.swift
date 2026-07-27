import Testing
import Foundation
@testable import HourglassCore

@Suite struct WorkdayLogTests {

    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    private func focus(at start: Date, minutes: Double = 25, completed: Bool = true) -> FocusSession {
        FocusSession(
            kind: .focus,
            plannedDuration: minutes * 60,
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60),
            completed: completed
        )
    }

    private func sessionIDs(of workday: LogWorkday) -> [FocusSession.ID] {
        workday.children.compactMap { child in
            if case .session(let session) = child { return session.id }
            return nil
        }
    }

    // MARK: Claiming

    @Test func aWorkdayClaimsTheSessionsRecordedInsideIt() {
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17))
        let inside = focus(at: at(10))
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [inside])

        #expect(log.workdays.count == 1)
        #expect(sessionIDs(of: log.workdays[0]) == [inside.id])
    }

    @Test func breaksHangUnderTheWorkdayThatHoldsThem() {
        let entry = WorkBreak(startedAt: at(12), endedAt: at(12.5))
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17), breaks: [entry])
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [])

        #expect(log.workdays[0].children.map(\.id) == [entry.id])
        #expect(log.workdays[0].children.first?.exportKind == "break")
    }

    /// Regression: an open workday used to claim up to `distantFuture`, so it
    /// swallowed every session that came after it — including ones a later
    /// workday had already claimed, which then rendered under both sections.
    @Test func anOpenWorkdayDoesNotClaimALaterWorkdaysSessions() {
        let stale = ClockSession(clockedInAt: at(9))                       // never clocked out
        let today = ClockSession(clockedInAt: at(33), clockedOutAt: at(41)) // the next day
        let session = focus(at: at(35))
        let log = WorkdayLog(clockSessions: [stale, today], focusSessions: [session])

        let claimed = log.workdays.flatMap { sessionIDs(of: $0) }
        #expect(claimed == [session.id])                                    // claimed exactly once
        #expect(sessionIDs(of: log.workdays[0]) == [session.id])            // by the newer workday
        #expect(log.workdays[1].clockSession?.id == stale.id)
        #expect(log.workdays[1].children.isEmpty)                           // not by the open one
    }

    /// Two devices can each hold an open session, so "open" alone can't decide
    /// ownership — the newest open workday takes the work, the older one stops
    /// where that one began.
    @Test func theNewestOfTwoOpenWorkdaysClaimsTheSession() {
        let first = ClockSession(clockedInAt: at(9))
        let second = ClockSession(clockedInAt: at(10))
        let before = focus(at: at(9.5))
        let after = focus(at: at(11))
        let log = WorkdayLog(clockSessions: [first, second], focusSessions: [before, after])

        #expect(log.workdays[0].clockSession?.id == second.id)
        #expect(sessionIDs(of: log.workdays[0]) == [after.id])
        #expect(sessionIDs(of: log.workdays[1]) == [before.id])
    }

    /// Both ends of a workday's window are inclusive, so a session starting the
    /// instant one day ends and the next begins matched twice.
    @Test func aSessionOnTheBoundaryIsClaimedByTheNewerWorkday() {
        let morning = ClockSession(clockedInAt: at(9), clockedOutAt: at(13))
        let afternoon = ClockSession(clockedInAt: at(13), clockedOutAt: at(17))
        let session = focus(at: at(13))
        let log = WorkdayLog(clockSessions: [morning, afternoon], focusSessions: [session])

        #expect(log.workdays.flatMap { sessionIDs(of: $0) } == [session.id])
        #expect(sessionIDs(of: log.workdays[0]) == [session.id]) // the afternoon
        #expect(log.workdays[1].children.isEmpty)
    }

    @Test func sessionsOutsideEveryWorkdayLandInTheTrailingGroup() {
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17))
        let evening = focus(at: at(21))
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [evening])

        #expect(log.workdays.count == 2)
        #expect(log.workdays[0].clockSession?.id == workday.id)
        #expect(log.workdays[1].clockSession == nil)
        #expect(sessionIDs(of: log.workdays[1]) == [evening.id])
    }

    @Test func thereIsNoTrailingGroupWhenEverySessionIsClaimed() {
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17))
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [focus(at: at(10))])
        #expect(log.workdays.allSatisfy { $0.clockSession != nil })
    }

    @Test func abandonedSessionsAreNotLogged() {
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17))
        let abandoned = focus(at: at(10), completed: false)
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [abandoned])

        #expect(log.workdays[0].children.isEmpty)
        #expect(log.timeline.count == 1) // the workday itself
    }

    // MARK: Ordering

    @Test func workdaysAndTheirChildrenAreNewestFirst() {
        let older = ClockSession(clockedInAt: at(9), clockedOutAt: at(17))
        let newer = ClockSession(clockedInAt: at(33), clockedOutAt: at(41))
        let early = focus(at: at(10))
        let late = focus(at: at(15))
        let log = WorkdayLog(clockSessions: [older, newer], focusSessions: [early, late])

        #expect(log.workdays.map(\.id) == [newer.id, older.id])
        #expect(sessionIDs(of: log.workdays[1]) == [late.id, early.id])
        #expect(log.timeline.map(\.startedAt) == log.timeline.map(\.startedAt).sorted(by: >))
    }

    // MARK: Export

    @Test func exportCSVListsEveryItemOldestFirst() {
        let entry = WorkBreak(startedAt: at(12), endedAt: at(12.5))
        let workday = ClockSession(clockedInAt: at(9), clockedOutAt: at(17), breaks: [entry])
        let log = WorkdayLog(clockSessions: [workday], focusSessions: [focus(at: at(10))])

        let lines = log.exportCSV().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fields = lines.map { $0.split(separator: ",").map(String.init) }
        #expect(lines.first == "type,start,end,duration_minutes")
        #expect(lines.count == 4) // header + workday + focus + break
        #expect(fields.dropFirst().map { $0[0] } == ["workday", "focus", "break"])

        // Every row is kind, ISO-8601 start, ISO-8601 end, minutes to one place.
        let workdayRow = fields[1]
        #expect(workdayRow.count == 4)
        #expect(ISO8601DateFormatter().date(from: workdayRow[1]) == at(9))
        #expect(ISO8601DateFormatter().date(from: workdayRow[2]) == at(17))
        #expect(workdayRow[3] == "480.0")
        #expect(lines[2].hasSuffix(",25.0"))
        #expect(lines[3].hasSuffix(",30.0"))
    }

    @Test func exportOfAnEmptyLogIsJustTheHeader() {
        #expect(WorkdayLog(clockSessions: [], focusSessions: []).exportCSV() == "type,start,end,duration_minutes")
    }
}
