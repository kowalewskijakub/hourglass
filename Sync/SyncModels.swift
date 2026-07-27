import Foundation
import HourglassCore

/// Wire models for the Supabase tables. Kept separate from the app models so the
/// database schema and the local models can evolve independently.

/// One row of `live_state` — the mirrored running timer.
struct LiveStateRow: Codable, Equatable {
    var user_id: String
    var kind: String
    var end_date: Date?
    var is_running: Bool
    var paused_at: Date?
    var cycle_position: Int
    var origin_device: String
    var updated_at: Date

    var sessionKind: SessionKind { SessionKind(rawValue: kind) ?? .focus }
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

    init(session: FocusSession, userID: String) {
        id = session.id
        user_id = userID
        kind = session.kind.rawValue
        planned_duration = session.plannedDuration
        started_at = session.startedAt
        ended_at = session.endedAt
        completed = session.completed
    }

    var focusSession: FocusSession {
        FocusSession(
            id: id,
            kind: SessionKind(rawValue: kind) ?? .focus,
            plannedDuration: planned_duration,
            startedAt: started_at,
            endedAt: ended_at,
            completed: completed
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

    init(session: ClockSession, userID: String) {
        id = session.id
        user_id = userID
        clocked_in_at = session.clockedInAt
        clocked_out_at = session.clockedOutAt
        breaks = session.breaks
    }

    var clockSession: ClockSession {
        ClockSession(
            id: id,
            clockedInAt: clocked_in_at,
            clockedOutAt: clocked_out_at,
            breaks: breaks
        )
    }
}

/// One row of `settings` — the user's `TimerSettings` as JSON.
struct SettingsRow: Codable, Equatable {
    var user_id: String
    var payload: TimerSettings
    var updated_at: Date
}
