import Foundation
import Observation

/// Tracks the working day: clocking in and out, and non-Pomodoro breaks taken
/// while clocked in. Observable so the UI reflects the current state live.
@MainActor
@Observable
public final class WorkdayTracker {
    private let store: any WorkdayStoring
    private let clock: any PomodoroClock
    private let stamps: any UpdateStamping
    private let calendar: Calendar

    /// Fired whenever a clock session is created or modified (in/out, breaks,
    /// manual edits), so hosts can mirror it to other devices.
    public var onSessionChanged: (@MainActor (ClockSession) -> Void)?

    /// Fired when a clock session is deleted.
    public var onSessionDeleted: (@MainActor (ClockSession.ID) -> Void)?

    /// Fired when a single break is deleted. Breaks sync as their own rows, and
    /// a deletion erases its evidence from the parent session — without this,
    /// nothing would carry the tombstone and the break would resurrect from the
    /// server on the next pull.
    public var onBreakDeleted: (@MainActor (ClockSession.ID, WorkBreak.ID) -> Void)?

    public init(
        store: any WorkdayStoring,
        clock: any PomodoroClock = SystemClock(),
        stamps: (any UpdateStamping)? = nil,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.clock = clock
        // Defaults to the injected clock, so stamps stay deterministic under
        // test clocks; the app swaps in the shared hybrid clock for sync.
        self.stamps = stamps ?? WallClockStamps(wallClock: { clock.now })
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
        let session = ClockSession(clockedInAt: clock.now, updatedAt: stamps.next())
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
    /// working, so a running break ends — leaving it open would keep charging
    /// break time against the work you're actually doing.
    ///
    /// A *break* timer starting does the opposite of what it used to: a Pomodoro
    /// short or long break is now the same rest interval the workday records, so
    /// the running work break continues rather than being closed under it. The
    /// linking itself belongs to ``PomodoroWorkdayCoordinator``; all that matters
    /// here is that a break phase never ends a work break.
    public func sessionStarted(kind: SessionKind) {
        guard kind == .focus else { return }
        clockIn()
        endBreak()
    }

    /// Begin a work break (clocking in first if needed), and hand back the
    /// interval that was opened so a caller can remember which one it owns.
    ///
    /// `id` exists for the linked Pomodoro break: two devices both witness the
    /// same focus completing and both open a rest, so the coordinator derives an
    /// identity they agree on rather than each minting its own. Without it the
    /// two rows sync into two overlapping rests and the day loses the time
    /// twice. A manual break needs no such agreement and takes a fresh id.
    @discardableResult
    public func startBreak(id: UUID = UUID()) -> WorkBreak? {
        if !isClockedIn { clockIn() }
        guard var session = currentSession, !session.isOnBreak else { return nil }
        // Two rows under one id is corruption, not a duplicate: `breakDuration`
        // reduces over the array and charges the day twice, every edit resolves
        // by `firstIndex(where:)` and can only ever reach the first copy, and
        // the outbox coalesces on the id so only one of them ever reaches the
        // server. A caller passing a derived id can collide (see
        // `PomodoroWorkdayCoordinator.linkedBreakID`); refusing here is what
        // makes that a no-op rather than a wrong number.
        guard !session.breaks.contains(where: { $0.id == id }) else { return nil }
        let entry = WorkBreak(id: id, startedAt: clock.now, updatedAt: stamps.next())
        session.breaks.append(entry)
        persist(session)
        return entry
    }

    /// End the running break, if any.
    public func endBreak() {
        guard var session = currentSession, session.isOnBreak else { return }
        endActiveBreak(in: &session)
        persist(session)
    }

    public func toggleBreak() {
        if isOnBreak { endBreak() } else { startBreak() }
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
        var entry = entry
        entry.updatedAt = stamps.next()
        session.breaks[index] = entry
        persist(normalized(session))
    }

    public func deleteBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID) {
        guard var session = store.all().first(where: { $0.id == sessionID }),
              session.breaks.contains(where: { $0.id == entryID }) else { return }
        session.breaks.removeAll { $0.id == entryID }
        persist(normalized(session))
        onBreakDeleted?(sessionID, entryID)
    }

    public func add(_ session: ClockSession) {
        var session = normalized(session)
        session.updatedAt = stamps.next()
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
    ///
    /// Only the clock stamps travel with the session row; breaks are their own
    /// rows with their own stamps, applied through ``applyRemoteBreak``. The
    /// local breaks are therefore always preserved here — a session-level
    /// last-writer-wins that swallowed the breaks array is exactly how a stale
    /// offline device used to erase a whole day's breaks.
    public func applyRemote(_ session: ClockSession) {
        guard let existing = store.all().first(where: { $0.id == session.id }) else {
            store.add(session)
            return
        }
        let mine = existing.updatedAt ?? .distantPast
        let theirs = session.updatedAt ?? .distantPast
        guard theirs >= mine else { return }
        var merged = session
        merged.breaks = existing.breaks
        store.update(merged)
    }

    /// Adopts one break from another device, last writer winning per break.
    /// Returns false when the parent session isn't here yet, so the caller can
    /// hold the row until it is — session and break rows travel independently.
    @discardableResult
    public func applyRemoteBreak(sessionID: ClockSession.ID, entry: WorkBreak) -> Bool {
        guard var session = store.all().first(where: { $0.id == sessionID }) else { return false }
        if let index = session.breaks.firstIndex(where: { $0.id == entry.id }) {
            let mine = session.breaks[index].updatedAt ?? .distantPast
            let theirs = entry.updatedAt ?? .distantPast
            guard theirs >= mine else { return true }
            session.breaks[index] = entry
        } else {
            session.breaks.append(entry)
            session.breaks.sort { $0.startedAt < $1.startedAt }
        }
        store.update(session)
        return true
    }

    /// Applies a break deletion from another device — unless our copy of the
    /// break is newer than the deletion, which would mean the tombstone is
    /// stale and the edit it would erase should stand.
    public func deleteBreakLocally(sessionID: ClockSession.ID, entryID: WorkBreak.ID, unlessEditedAfter stamp: Date) {
        guard var session = store.all().first(where: { $0.id == sessionID }),
              let index = session.breaks.firstIndex(where: { $0.id == entryID }) else { return }
        let mine = session.breaks[index].updatedAt ?? .distantPast
        guard stamp >= mine else { return }
        session.breaks.remove(at: index)
        store.update(session)
    }

    public func deleteLocally(id: ClockSession.ID) { store.delete(id: id) }

    // MARK: Persistence

    /// Single write path, so every mutation notifies the sync layer.
    private func persist(_ session: ClockSession) {
        var session = session
        session.updatedAt = stamps.next()
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
            session.breaks[index].updatedAt = stamps.next()
        }
        return session
    }

    /// Closes every running break (there should only ever be one, but a manual
    /// edit could introduce more).
    private func endActiveBreak(in session: inout ClockSession, at instant: Date? = nil) {
        let end = instant ?? clock.now
        for index in session.breaks.indices where session.breaks[index].isActive {
            session.breaks[index].endedAt = end
            session.breaks[index].updatedAt = stamps.next()
        }
    }
}
