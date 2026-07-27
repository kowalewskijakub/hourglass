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

    /// Fired whenever a clock session is created or modified (in/out, breaks,
    /// manual edits), so hosts can mirror it to other devices.
    public var onSessionChanged: (@MainActor (ClockSession) -> Void)?

    /// Fired when a clock session is deleted.
    public var onSessionDeleted: (@MainActor (ClockSession.ID) -> Void)?

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
        let session = ClockSession(clockedInAt: clock.now, updatedAt: clock.now)
        store.add(session)
        onSessionChanged?(session)
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
            persist(session)
        }
    }

    /// End the working session, closing any running break first.
    public func clockOut() {
        guard var session = currentSession else { return }
        endActiveBreak(in: &session)
        session.clockedOutAt = clock.now
        persist(session)
    }

    public func toggleClock() {
        if isClockedIn { clockOut() } else { clockIn() }
    }

    /// A Pomodoro started, so the workday follows it: focusing means you're
    /// working, and starting any timer means you're back at it, so a running
    /// coffee break ends — leaving it open would keep charging break time
    /// against the session you're actually working through.
    ///
    /// The mirror of `clockOut`, which closes a running break from the other end.
    public func sessionStarted(kind: SessionKind) {
        if kind == .focus { clockIn() }
        endBreak()
    }

    /// Begin a non-Pomodoro break (clocking in first if needed).
    public func startBreak() {
        if !isClockedIn { clockIn() }
        guard var session = currentSession, !session.isOnBreak else { return }
        session.breaks.append(WorkBreak(startedAt: clock.now))
        persist(session)
    }

    /// End the running break, if any.
    public func endBreak() {
        guard var session = currentSession, session.isOnBreak else { return }
        endActiveBreak(in: &session)
        persist(session)
    }

    public func toggleBreak() {
        isOnBreak ? endBreak() : startBreak()
    }

    // MARK: Editing (from the log)
    //
    // Every edit is keyed by id and re-reads the stored session, applying only
    // the fields its editor owns. A log sheet can sit open while the session
    // changes underneath it — a break started on this device, a clock-out
    // mirrored from another — and handing back the whole session would silently
    // undo all of it, which is why there is no whole-session write here.

    /// The workday editor owns the two clock stamps and nothing else.
    public func updateClockSession(id: ClockSession.ID, clockedInAt: Date, clockedOutAt: Date?) {
        guard var session = store.all().first(where: { $0.id == id }) else { return }
        session.clockedInAt = clockedInAt
        session.clockedOutAt = clockedOutAt
        persist(normalized(session))
    }

    /// The break editor owns one break's stamps.
    public func updateBreak(sessionID: ClockSession.ID, entry: WorkBreak) {
        guard var session = store.all().first(where: { $0.id == sessionID }),
              let index = session.breaks.firstIndex(where: { $0.id == entry.id }) else { return }
        session.breaks[index] = entry
        persist(normalized(session))
    }

    public func deleteBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID) {
        guard var session = store.all().first(where: { $0.id == sessionID }),
              session.breaks.contains(where: { $0.id == entryID }) else { return }
        session.breaks.removeAll { $0.id == entryID }
        persist(normalized(session))
    }

    public func add(_ session: ClockSession) {
        var session = normalized(session)
        session.updatedAt = clock.now
        store.add(session)
        onSessionChanged?(session)
    }
    public func delete(id: ClockSession.ID) {
        store.delete(id: id)
        onSessionDeleted?(id)
    }

    /// Adopts a session mirrored from another device without echoing it back,
    /// unless what we hold is newer — a stale copy would silently undo a local
    /// edit.
    public func applyRemote(_ session: ClockSession) {
        guard let existing = store.all().first(where: { $0.id == session.id }) else {
            store.add(session)
            return
        }
        let mine = existing.updatedAt ?? .distantPast
        let theirs = session.updatedAt ?? .distantPast
        guard theirs >= mine else { return }
        store.update(session)
    }

    public func deleteLocally(id: ClockSession.ID) { store.delete(id: id) }

    // MARK: Persistence

    /// Single write path, so every mutation notifies the sync layer.
    private func persist(_ session: ClockSession) {
        var session = session
        session.updatedAt = clock.now
        store.update(session)
        onSessionChanged?(session)
    }

    // MARK: Helpers

    /// Enforces the invariants the live clock path maintains, so edits made in
    /// the log can't persist an impossible session: a day never ends before it
    /// starts, and a closed session never holds a running break.
    private func normalized(_ session: ClockSession) -> ClockSession {
        guard let out = session.clockedOutAt else { return session }
        var session = session
        // The log's date pickers are unbounded, so a clock-out can be dragged
        // behind the clock-in; a day of no length beats one of negative length.
        let end = max(out, session.clockedInAt)
        session.clockedOutAt = end
        for index in session.breaks.indices where session.breaks[index].isActive {
            session.breaks[index].endedAt = end
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
