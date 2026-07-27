import Foundation
import HourglassCore

/// Wire models for the Supabase tables. Kept separate from the app models so the
/// database schema and the local models can evolve independently.

/// One row of `live_state` — the mirrored running timer.
struct LiveStateRow: Codable, Equatable {
    var user_id: String
    var kind: String
    /// When the current session ends. Nil only while the timer is idle — a
    /// paused timer still carries one, measured from `paused_at`.
    var end_date: Date?
    var is_running: Bool
    /// The instant a paused timer froze. `end_date - paused_at` is what is left
    /// to run, so the other device can adopt the pause without the countdown
    /// having drifted by the time it arrives.
    var paused_at: Date?
    var cycle_position: Int
    var origin_device: String
    var updated_at: Date

    var sessionKind: SessionKind { SessionKind(rawValue: kind) ?? .focus }

    /// Encoded by hand because the synthesized encoder leaves nil optionals out
    /// of the payload entirely, and an upsert only touches the columns its
    /// payload names. A timer going from paused back to idle would therefore
    /// leave the old `paused_at` standing on the server, and every other device
    /// would keep reading an idle timer as paused. Clearing has to be explicit.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(kind, forKey: .kind)
        try container.encode(end_date, forKey: .end_date)
        try container.encode(is_running, forKey: .is_running)
        try container.encode(paused_at, forKey: .paused_at)
        try container.encode(cycle_position, forKey: .cycle_position)
        try container.encode(origin_device, forKey: .origin_device)
        try container.encode(updated_at, forKey: .updated_at)
    }
}

/// One row of `sessions` — a recorded Pomodoro.
struct SessionRow: Codable, Equatable {
    var id: UUID
    var user_id: String
    var kind: String
    var planned_duration: Double
    var started_at: Date
    var ended_at: Date?
    var completed: Bool
    /// Stamped on every write — the column default only fires on insert, so
    /// without this the value goes stale the moment a row is first updated.
    var updated_at: Date
    /// Set only on a tombstone; nil on a live row, and then left out of the
    /// payload altogether, so a live row still writes to a database where this
    /// column has yet to be added.
    var deleted_at: Date?

    init(session: FocusSession, userID: String) {
        id = session.id
        user_id = userID
        kind = session.kind.rawValue
        planned_duration = session.plannedDuration
        started_at = session.startedAt
        ended_at = session.endedAt
        completed = session.completed
        // Carry the local change time so the other device can tell whose copy
        // is newer, rather than blindly taking whatever arrived last.
        updated_at = session.updatedAt ?? Date()
        deleted_at = nil
    }

    /// Records that the session is gone. A hard DELETE cannot say that: the
    /// Realtime payload for one carries no row the peers can match, and a device
    /// that was offline at the time sees nothing at all and re-uploads its copy
    /// on the next connect. Kept as a row, the deletion travels as an ordinary
    /// update and can be compared for staleness like any other change.
    ///
    /// Every field but `id`, `updated_at` and `deleted_at` is a placeholder:
    /// each apply path checks `deleted_at` before reading anything else, so
    /// their values are never observed. They are here only because Postgres
    /// still checks the NOT NULL constraints on the proposed row, even when the
    /// upsert ends up taking its ON CONFLICT branch.
    ///
    /// The placeholders are nonetheless chosen to be *inert*: a device still on
    /// a build that predates tombstones ignores `deleted_at` and reads this as
    /// an ordinary row, so it must describe a zero-length, already-finished
    /// session rather than something that alters its clock state or statistics.
    static func tombstone(id: UUID, userID: String, at instant: Date) -> SessionRow {
        var row = SessionRow(
            session: FocusSession(
                id: id,
                kind: .focus,
                plannedDuration: 0,
                startedAt: instant,
                endedAt: instant
            ),
            userID: userID
        )
        row.updated_at = instant
        row.deleted_at = instant
        return row
    }

    /// Encoded by hand for the same reason as `LiveStateRow`: the synthesized
    /// encoder leaves nil optionals out, and an upsert only writes the columns
    /// its payload names. A live row would therefore leave an earlier
    /// tombstone's `deleted_at` standing — so a row that was ever deleted could
    /// never come back, and the reconcile's decision that a later local edit
    /// beats the tombstone would destroy that edit instead of applying it.
    /// Clearing `ended_at` needs the same explicitness.
    ///
    /// `deleted_at` is the one exception: it is written only when set, because
    /// the column does not exist in every database yet and naming it in a live
    /// row's payload would fail the write outright.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(kind, forKey: .kind)
        try container.encode(planned_duration, forKey: .planned_duration)
        try container.encode(started_at, forKey: .started_at)
        try container.encode(ended_at, forKey: .ended_at)
        try container.encode(completed, forKey: .completed)
        try container.encode(updated_at, forKey: .updated_at)
        try container.encodeIfPresent(deleted_at, forKey: .deleted_at)
    }

    var focusSession: FocusSession {
        FocusSession(
            id: id,
            kind: SessionKind(rawValue: kind) ?? .focus,
            plannedDuration: planned_duration,
            startedAt: started_at,
            endedAt: ended_at,
            completed: completed,
            updatedAt: updated_at
        )
    }
}

/// One row of `clock_sessions` — a clocked-in stretch and its breaks.
struct ClockSessionRow: Codable, Equatable {
    var id: UUID
    var user_id: String
    var clocked_in_at: Date
    var clocked_out_at: Date?
    var breaks: [WorkBreak]
    /// Stamped on every write — the column default only fires on insert, so
    /// without this the value goes stale the moment a row is first updated.
    var updated_at: Date
    /// Set only on a tombstone — see `SessionRow.deleted_at`.
    var deleted_at: Date?

    init(session: ClockSession, userID: String) {
        id = session.id
        user_id = userID
        clocked_in_at = session.clockedInAt
        clocked_out_at = session.clockedOutAt
        breaks = session.breaks
        // Carry the local change time so the other device can tell whose copy
        // is newer, rather than blindly taking whatever arrived last.
        updated_at = session.updatedAt ?? Date()
        deleted_at = nil
    }

    /// Records that the clocked-in stretch is gone — see `SessionRow.tombstone`
    /// for why a deletion has to be a row rather than a DELETE, and why the
    /// placeholders are inert. Clocking out at the same instant matters here:
    /// left open, a device that predates tombstones reads the row as a workday
    /// it is *currently clocked into*.
    static func tombstone(id: UUID, userID: String, at instant: Date) -> ClockSessionRow {
        var row = ClockSessionRow(
            session: ClockSession(id: id, clockedInAt: instant, clockedOutAt: instant),
            userID: userID
        )
        row.updated_at = instant
        row.deleted_at = instant
        return row
    }

    /// Encoded by hand for the same reason as `SessionRow` — and this is the row
    /// where it was already costing something: reopening a workday sets
    /// `clockedOutAt` back to nil, the synthesized encoder dropped the column
    /// from the payload, the server kept its old clock-out, and the edit came
    /// straight back undone on the next echo.
    ///
    /// `deleted_at` stays conditional; see `SessionRow.encode(to:)`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(clocked_in_at, forKey: .clocked_in_at)
        try container.encode(clocked_out_at, forKey: .clocked_out_at)
        try container.encode(breaks, forKey: .breaks)
        try container.encode(updated_at, forKey: .updated_at)
        try container.encodeIfPresent(deleted_at, forKey: .deleted_at)
    }

    var clockSession: ClockSession {
        ClockSession(
            id: id,
            clockedInAt: clocked_in_at,
            clockedOutAt: clocked_out_at,
            breaks: breaks,
            updatedAt: updated_at
        )
    }
}

/// One row of `settings` — the user's `TimerSettings` as JSON.
struct SettingsRow: Codable, Equatable {
    var user_id: String
    var payload: TimerSettings
    var updated_at: Date
}

/// Just enough of a synced row to decide whether ours is worth uploading.
/// Fetched instead of the whole row because the contents are irrelevant to that
/// decision — only which copy changed last is — and because a row that is now a
/// tombstone still answers it.
struct RowStamp: Decodable {
    var id: UUID
    var updated_at: Date
}
