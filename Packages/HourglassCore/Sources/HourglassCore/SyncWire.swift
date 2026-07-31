import Foundation

/// Wire models for the synced tables. Kept separate from the app models so the
/// database schema and the local models can evolve independently; kept in the
/// core (they are plain Codable, no networking) so the outbox can persist them
/// and the simulation tests can exercise the exact rows the app sends.
///
/// Two rules every encoder here follows:
/// - **Every column is named explicitly, nils included.** An upsert only
///   touches the columns its payload names, so an omitted nil leaves the old
///   value standing — which is how a cleared clock-out once resurrected, and
///   how a tombstone's `deleted_at` used to survive the edit that should have
///   beaten it.
/// - **`deleted_at` is always written.** The schema-version gate guarantees the
///   column exists before any row is sent, so a live row actively clears an
///   earlier tombstone instead of half-resurrecting under it.

/// How dates are written to the wire.
///
/// Foundation's ISO-8601 formatter TRUNCATES fractional seconds at the binary
/// representation (measured: ~50% of millisecond-aligned values print one
/// millisecond low, and even parse∘format is not a fixpoint). A stamp that
/// prints low breaks every equality the protocol relies on — the reconcile
/// sees its own rows as "newer than the server's copy" forever. So dates are
/// printed from their exact rounded millisecond instead: integer seconds
/// through the formatter (exact), the millisecond remainder appended by hand.
/// Parsing the result yields the binary-nearest of that decimal — the same
/// value `Date.wireAligned` computes — so a stamp survives the round trip
/// bit-for-bit.
public enum SyncWireEncoding {
    /// `2026-07-31T12:00:00.144` — zoneless UTC, the shape the SDK itself
    /// emits and every parser in the pipeline already accepts.
    public static func string(for date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        let whole = Date(timeIntervalSince1970: TimeInterval(ms / 1_000))
        let style = Date.ISO8601FormatStyle().year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
        return whole.formatted(style) + String(format: ".%03d", ms % 1_000)
    }

    /// A `JSONEncoder` for request bodies: SDK-compatible, but with the
    /// faithful date encoding above.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(for: date))
        }
        return encoder
    }
}

/// One row of `live_state` — the mirrored running timer.
public struct LiveStateRow: Codable, Equatable, Sendable {
    public var user_id: String
    public var kind: String
    /// When the current session ends. Nil only while the timer is idle — a
    /// paused timer still carries one, measured from `paused_at`.
    public var end_date: Date?
    public var is_running: Bool
    /// The instant a paused timer froze. `end_date - paused_at` is what is left
    /// to run, so the other device can adopt the pause without the countdown
    /// having drifted by the time it arrives.
    public var paused_at: Date?
    public var cycle_position: Int
    /// The identity of the session on the clock, so every device that witnesses
    /// its completion records it under the same id (upserts dedupe the copies).
    public var session_id: UUID?
    public var origin_device: String
    public var updated_at: Date

    public var sessionKind: SessionKind { SessionKind(rawValue: kind) ?? .focus }

    public init(
        user_id: String,
        kind: String,
        end_date: Date?,
        is_running: Bool,
        paused_at: Date?,
        cycle_position: Int,
        session_id: UUID?,
        origin_device: String,
        updated_at: Date
    ) {
        self.user_id = user_id
        self.kind = kind
        self.end_date = end_date
        self.is_running = is_running
        self.paused_at = paused_at
        self.cycle_position = cycle_position
        self.session_id = session_id
        self.origin_device = origin_device
        self.updated_at = updated_at
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(kind, forKey: .kind)
        try container.encode(end_date, forKey: .end_date)
        try container.encode(is_running, forKey: .is_running)
        try container.encode(paused_at, forKey: .paused_at)
        try container.encode(cycle_position, forKey: .cycle_position)
        try container.encode(session_id, forKey: .session_id)
        try container.encode(origin_device, forKey: .origin_device)
        try container.encode(updated_at, forKey: .updated_at)
    }
}

/// One row of `sessions` — a recorded Pomodoro.
public struct SessionRow: Codable, Equatable, Sendable {
    public var id: UUID
    public var user_id: String
    public var kind: String
    public var planned_duration: Double
    public var started_at: Date
    public var ended_at: Date?
    public var completed: Bool
    /// Stamped on every write — the column default only fires on insert, so
    /// without this the value goes stale the moment a row is first updated.
    public var updated_at: Date
    /// Set on a tombstone, explicitly null on a live row.
    public var deleted_at: Date?

    public init(session: FocusSession, userID: String) {
        id = session.id
        user_id = userID
        kind = session.kind.rawValue
        planned_duration = session.plannedDuration
        started_at = session.startedAt
        ended_at = session.endedAt
        completed = session.completed
        // Carry the local change time so the other device can tell whose copy
        // is newer, rather than blindly taking whatever arrived last. Aligned
        // to the wire's millisecond grid so it survives the round-trip intact.
        updated_at = (session.updatedAt ?? session.endedAt ?? session.startedAt).wireAligned
        deleted_at = nil
    }

    /// Records that the session is gone. A hard DELETE cannot say that: the
    /// Realtime payload for one carries no row the peers can match, and a device
    /// that was offline at the time sees nothing at all and re-uploads its copy
    /// on the next connect. Kept as a row, the deletion travels as an ordinary
    /// update and can be compared for staleness like any other change.
    ///
    /// Every field but `id`, `updated_at` and `deleted_at` is an inert
    /// placeholder — a zero-length, already-finished session — because Postgres
    /// still checks NOT NULL constraints on the proposed row even when the
    /// upsert takes its ON CONFLICT branch.
    public static func tombstone(id: UUID, userID: String, at instant: Date) -> SessionRow {
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(kind, forKey: .kind)
        try container.encode(planned_duration, forKey: .planned_duration)
        try container.encode(started_at, forKey: .started_at)
        try container.encode(ended_at, forKey: .ended_at)
        try container.encode(completed, forKey: .completed)
        try container.encode(updated_at, forKey: .updated_at)
        try container.encode(deleted_at, forKey: .deleted_at)
    }

    public var focusSession: FocusSession {
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

/// One row of `clock_sessions` — a clocked-in stretch. Its breaks are NOT in
/// this row: they travel as `work_breaks` rows of their own, so two devices
/// editing different parts of the same day merge instead of the later
/// session-level write erasing the earlier one's breaks.
public struct ClockSessionRow: Codable, Equatable, Sendable {
    public var id: UUID
    public var user_id: String
    public var clocked_in_at: Date
    public var clocked_out_at: Date?
    /// Stamped on every write — the column default only fires on insert.
    public var updated_at: Date
    /// Set on a tombstone, explicitly null on a live row.
    public var deleted_at: Date?

    public init(session: ClockSession, userID: String) {
        id = session.id
        user_id = userID
        clocked_in_at = session.clockedInAt
        clocked_out_at = session.clockedOutAt
        updated_at = (session.updatedAt ?? session.clockedInAt).wireAligned
        deleted_at = nil
    }

    /// See `SessionRow.tombstone`. Clocking out at the same instant matters
    /// here: left open, an old build reads the row as a workday it is
    /// *currently clocked into*.
    public static func tombstone(id: UUID, userID: String, at instant: Date) -> ClockSessionRow {
        var row = ClockSessionRow(
            session: ClockSession(id: id, clockedInAt: instant, clockedOutAt: instant),
            userID: userID
        )
        row.updated_at = instant
        row.deleted_at = instant
        return row
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(clocked_in_at, forKey: .clocked_in_at)
        try container.encode(clocked_out_at, forKey: .clocked_out_at)
        try container.encode(updated_at, forKey: .updated_at)
        try container.encode(deleted_at, forKey: .deleted_at)
    }

    /// The local session this row describes — with no breaks; they arrive as
    /// their own rows and the tracker preserves the local ones on merge.
    public var clockSession: ClockSession {
        ClockSession(
            id: id,
            clockedInAt: clocked_in_at,
            clockedOutAt: clocked_out_at,
            breaks: [],
            updatedAt: updated_at
        )
    }
}

/// One row of `work_breaks` — a single break, keyed to its clock session.
public struct WorkBreakRow: Codable, Equatable, Sendable {
    public var id: UUID
    public var user_id: String
    public var clock_session_id: UUID
    public var started_at: Date
    /// Explicitly null while the break is running — and the null must reach the
    /// wire, or re-opening a break could never clear an old end on the server.
    public var ended_at: Date?
    public var updated_at: Date
    /// Set on a tombstone, explicitly null on a live row.
    public var deleted_at: Date?

    public init(entry: WorkBreak, sessionID: UUID, userID: String) {
        id = entry.id
        user_id = userID
        clock_session_id = sessionID
        started_at = entry.startedAt
        ended_at = entry.endedAt
        updated_at = (entry.updatedAt ?? entry.startedAt).wireAligned
        deleted_at = nil
    }

    public static func tombstone(id: UUID, sessionID: UUID, userID: String, at instant: Date) -> WorkBreakRow {
        var row = WorkBreakRow(
            entry: WorkBreak(id: id, startedAt: instant, endedAt: instant),
            sessionID: sessionID,
            userID: userID
        )
        row.updated_at = instant
        row.deleted_at = instant
        return row
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(user_id, forKey: .user_id)
        try container.encode(clock_session_id, forKey: .clock_session_id)
        try container.encode(started_at, forKey: .started_at)
        try container.encode(ended_at, forKey: .ended_at)
        try container.encode(updated_at, forKey: .updated_at)
        try container.encode(deleted_at, forKey: .deleted_at)
    }

    public var workBreak: WorkBreak {
        WorkBreak(id: id, startedAt: started_at, endedAt: ended_at, updatedAt: updated_at)
    }
}

/// One row of `settings` — the user's `TimerSettings` as JSON.
public struct SettingsRow: Codable, Equatable, Sendable {
    public var user_id: String
    public var payload: TimerSettings
    public var updated_at: Date

    public init(user_id: String, payload: TimerSettings, updated_at: Date) {
        self.user_id = user_id
        self.payload = payload
        self.updated_at = updated_at
    }
}

/// Just enough of a synced row to decide whether ours is worth uploading.
/// Fetched instead of the whole row because the contents are irrelevant to that
/// decision — only which copy changed last is — and because a row that is now a
/// tombstone still answers it.
public struct RowStamp: Decodable, Sendable {
    public var id: UUID
    public var updated_at: Date

    public init(id: UUID, updated_at: Date) {
        self.id = id
        self.updated_at = updated_at
    }
}
