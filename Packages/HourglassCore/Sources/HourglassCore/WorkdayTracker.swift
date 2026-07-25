import Foundation
import Observation

/// Tracks the working day: clocking in and out, and non-Pomodoro breaks taken
/// while clocked in. Observable so the UI reflects the current state live.
@MainActor
@Observable
public final class WorkdayTracker {
    private let store: any WorkdayStoring
    private let clock: any PomodoroClock
    private let calendar: Calendar

    /// Fired when the user clocks in or out, so hosts can update reminders.
    public var onClockStateChanged: (@MainActor (_ clockedIn: Bool) -> Void)?

    public init(
        store: any WorkdayStoring,
        clock: any PomodoroClock = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: State

    /// The open (not yet clocked-out) session — the most recent one, so editing
    /// an old day in the log can never silently retarget today's actions.
    public var currentSession: ClockSession? {
        store.all()
            .filter(\.isActive)
            .max { $0.clockedInAt < $1.clockedInAt }
    }

    public var isClockedIn: Bool { currentSession != nil }
    public var isOnBreak: Bool { currentSession?.isOnBreak ?? false }

    public func sessions() -> [ClockSession] { store.all() }

    // MARK: Intent

    /// Start a working session. No-op if already clocked in *today*; a session
    /// left open on an earlier day is closed off at the end of its own day first,
    /// so a forgotten clock-out can't swallow today's work.
    @discardableResult
    public func clockIn() -> ClockSession? {
        closeStaleSessions()
        guard !isClockedIn else { return currentSession }
        let session = ClockSession(clockedInAt: clock.now)
        store.add(session)
        onClockStateChanged?(true)
        return session
    }

    /// Closes any open session that started before today, at the end of its day.
    private func closeStaleSessions() {
        let today = calendar.startOfDay(for: clock.now)
        for var session in store.all() where session.isActive {
            let sessionDay = calendar.startOfDay(for: session.clockedInAt)
            guard sessionDay < today else { continue }
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: sessionDay) ?? clock.now
            session.clockedOutAt = min(endOfDay, clock.now)
            endActiveBreak(in: &session, at: session.clockedOutAt ?? clock.now)
            store.update(session)
        }
    }

    /// End the working session, closing any running break first.
    public func clockOut() {
        guard var session = currentSession else { return }
        endActiveBreak(in: &session)
        session.clockedOutAt = clock.now
        store.update(session)
        onClockStateChanged?(false)
    }

    public func toggleClock() {
        if isClockedIn { clockOut() } else { clockIn() }
    }

    /// Begin a non-Pomodoro break (clocking in first if needed).
    public func startBreak() {
        if !isClockedIn { clockIn() }
        guard var session = currentSession, !session.isOnBreak else { return }
        session.breaks.append(WorkBreak(startedAt: clock.now))
        store.update(session)
    }

    /// End the running break, if any.
    public func endBreak() {
        guard var session = currentSession, session.isOnBreak else { return }
        endActiveBreak(in: &session)
        store.update(session)
    }

    public func toggleBreak() {
        isOnBreak ? endBreak() : startBreak()
    }

    // MARK: Editing (from the log)

    public func update(_ session: ClockSession) { store.update(normalized(session)) }
    public func delete(id: ClockSession.ID) { store.delete(id: id) }
    public func add(_ session: ClockSession) { store.add(normalized(session)) }

    // MARK: Helpers

    /// Enforces the invariants the live clock path maintains, so edits made in
    /// the log can't persist an impossible session: a closed session never holds
    /// a running break.
    private func normalized(_ session: ClockSession) -> ClockSession {
        guard let out = session.clockedOutAt else { return session }
        var session = session
        for index in session.breaks.indices where session.breaks[index].isActive {
            session.breaks[index].endedAt = out
        }
        return session
    }

    /// Closes every running break (there should only ever be one, but a manual
    /// edit could introduce more).
    private func endActiveBreak(in session: inout ClockSession, at instant: Date? = nil) {
        let end = instant ?? clock.now
        for index in session.breaks.indices where session.breaks[index].isActive {
            session.breaks[index].endedAt = end
        }
    }
}
