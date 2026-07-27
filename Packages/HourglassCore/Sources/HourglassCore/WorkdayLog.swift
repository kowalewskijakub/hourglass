import Foundation

/// A row recorded *inside* a workday: a Pomodoro session, or a non-Pomodoro
/// break belonging to that workday's clock session.
///
/// Deliberately cannot express the workday itself — the workday is the section
/// these hang under, so a renderer never has to handle a case that can't occur.
public enum LogEntry: Identifiable, Hashable, Sendable {
    case session(FocusSession)
    case workBreak(sessionID: ClockSession.ID, entry: WorkBreak)

    public var id: UUID {
        switch self {
        case .session(let s): return s.id
        case .workBreak(_, let b): return b.id
        }
    }

    public var startedAt: Date {
        switch self {
        case .session(let s): return s.startedAt
        case .workBreak(_, let b): return b.startedAt
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .session(let s): return s.plannedDuration
        case .workBreak(_, let b): return b.duration()
        }
    }

    /// Stable label used in the CSV export.
    public var exportKind: String {
        switch self {
        case .session(let s): return s.kind.rawValue
        case .workBreak: return "break"
        }
    }
}

/// A single row in the flat timeline — an entry, or the workday that contains
/// entries. Only the export walks this; the UI reads the nested workdays.
public enum LogItem: Identifiable, Hashable, Sendable {
    case workday(ClockSession)
    case entry(LogEntry)

    public var id: UUID {
        switch self {
        case .workday(let c): return c.id
        case .entry(let e): return e.id
        }
    }

    public var startedAt: Date {
        switch self {
        case .workday(let c): return c.clockedInAt
        case .entry(let e): return e.startedAt
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .workday(let c): return c.grossDuration()
        case .entry(let e): return e.duration
        }
    }

    /// Stable label used in the CSV export.
    public var exportKind: String {
        switch self {
        case .workday: return "workday"
        case .entry(let e): return e.exportKind
        }
    }
}

/// A workday and everything recorded inside it. `clockSession` is nil for the
/// trailing group of entries recorded while clocked out.
public struct LogWorkday: Identifiable, Hashable, Sendable {
    public let clockSession: ClockSession?
    public let children: [LogEntry]

    public init(clockSession: ClockSession?, children: [LogEntry]) {
        self.clockSession = clockSession
        self.children = children
    }

    /// The trailing group has no session to borrow an id from, and a fresh UUID
    /// each time would make the list rebuild it on every redraw.
    public var id: UUID { clockSession?.id ?? Self.unassignedID }

    private static let unassignedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
}

/// The unified history — workdays with the Pomodoro sessions and breaks that
/// happened inside them — derived from what the two stores hold.
///
/// Pure and value-typed so the rule deciding which workday owns a session is
/// testable without a store, a clock or a view.
public struct WorkdayLog: Sendable {
    /// Workdays newest first, each with its own entries nested underneath, and
    /// a trailing group for anything recorded while clocked out.
    public let workdays: [LogWorkday]

    /// Everything flattened, newest first.
    public let timeline: [LogItem]

    public init(clockSessions: [ClockSession], focusSessions: [FocusSession]) {
        // A session that was skipped or reset never happened as far as the log
        // is concerned.
        let recorded = focusSessions.filter(\.completed)
        let ordered = clockSessions.sorted { $0.clockedInAt > $1.clockedInAt }

        // Where each workday stops claiming. An open workday claims up to the
        // moment the next one opens — left unbounded it would claim every
        // session that followed it, including work a later workday already owns,
        // and the same session would then render under two sections at once.
        let ends: [Date] = ordered.indices.map { index in
            if let out = ordered[index].clockedOutAt { return out }
            return index > 0 ? ordered[index - 1].clockedInAt : .distantFuture
        }

        var children: [[LogEntry]] = ordered.map { clockSession in
            clockSession.breaks.map { .workBreak(sessionID: clockSession.id, entry: $0) }
        }
        var unassigned: [LogEntry] = []

        for session in recorded {
            // Newest first, and the first match wins, so overlapping workdays
            // (two devices, or a manual edit) still claim a session exactly once.
            let owner = ordered.indices.first { index in
                session.startedAt >= ordered[index].clockedInAt && session.startedAt <= ends[index]
            }
            if let owner {
                children[owner].append(.session(session))
            } else {
                unassigned.append(.session(session))
            }
        }

        var workdays = zip(ordered, children).map { clockSession, entries in
            LogWorkday(clockSession: clockSession, children: entries.sorted { $0.startedAt > $1.startedAt })
        }
        if !unassigned.isEmpty {
            workdays.append(
                LogWorkday(clockSession: nil, children: unassigned.sorted { $0.startedAt > $1.startedAt })
            )
        }
        self.workdays = workdays

        var timeline: [LogItem] = recorded.map { .entry(.session($0)) }
        for clockSession in clockSessions {
            timeline.append(.workday(clockSession))
            timeline += clockSession.breaks.map { .entry(.workBreak(sessionID: clockSession.id, entry: $0)) }
        }
        self.timeline = timeline.sorted { $0.startedAt > $1.startedAt }
    }

    /// The whole log as CSV, oldest first, for export.
    public func exportCSV() -> String {
        var lines = ["type,start,end,duration_minutes"]
        let formatter = ISO8601DateFormatter()
        for item in timeline.sorted(by: { $0.startedAt < $1.startedAt }) {
            let minutes = String(format: "%.1f", item.duration / 60)
            let start = formatter.string(from: item.startedAt)
            let end = formatter.string(from: item.startedAt.addingTimeInterval(item.duration))
            lines.append("\(item.exportKind),\(start),\(end),\(minutes)")
        }
        return lines.joined(separator: "\n")
    }
}
