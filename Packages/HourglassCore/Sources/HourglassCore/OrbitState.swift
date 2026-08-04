import Foundation

/// The two orthogonal axes the Orbit surfaces are resolved from.
///
/// The workday is the spine: clocking in, working, resting and clocking out stay
/// meaningful even if the user never starts a Pomodoro. A Pomodoro phase is an
/// optional bounded layer over that workday. Modelling them as one flattened
/// state is what used to produce contradictions — a "paused" face that had also
/// stopped the workday, or a Break button offered in the middle of a Pomodoro
/// break — so they are kept apart here and combined only in the resolver.

// MARK: - Workday axis

/// Why the workday is resting. A Pomodoro short or long break and a manual work
/// break are one underlying rest interval; only the *reason* differs, and only
/// for what the UI says about it.
public enum BreakSource: Equatable, Sendable, Hashable {
    case manual
    case pomodoro(SessionKind)

    public var isPomodoro: Bool {
        if case .pomodoro = self { return true }
        return false
    }
}

public enum WorkdayState: Equatable, Sendable {
    case clockedOut
    case working(startedAt: Date)
    case onBreak(startedAt: Date, source: BreakSource)

    public var isClockedIn: Bool { self != .clockedOut }

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    public var isOnBreak: Bool {
        if case .onBreak = self { return true }
        return false
    }

    /// The source of the running break, if the workday is resting.
    public var breakSource: BreakSource? {
        if case .onBreak(_, let source) = self { return source }
        return nil
    }
}

// MARK: - Pomodoro axis

/// The bounded phase layered over the workday.
///
/// `ready` is a phase that has been selected but is not advancing — the state
/// the engine sits in when auto-start is off. `completed` is specifically a
/// finished *break* whose linked work break is still open, waiting for the user
/// to come back; the workday must not resume counting work until they do.
public enum PomodoroState: Equatable, Sendable {
    case idle
    case ready(kind: SessionKind, remaining: TimeInterval)
    case running(kind: SessionKind, remaining: TimeInterval)
    case paused(kind: SessionKind, remaining: TimeInterval)
    /// The clock ran out and the phase is counting on past it, waiting for the
    /// user to continue. Nothing advances by itself.
    case overrun(kind: SessionKind, over: TimeInterval)
    case completed(kind: SessionKind)

    public var isIdle: Bool { self == .idle }

    /// True whenever *any* Pomodoro phase exists — which is exactly when the
    /// separate workday Break action must be hidden.
    public var exists: Bool { self != .idle }

    public var kind: SessionKind? {
        switch self {
        case .idle: return nil
        case .ready(let kind, _), .running(let kind, _), .paused(let kind, _),
             .overrun(let kind, _), .completed(let kind):
            return kind
        }
    }

    /// How far past its planned end this phase has run. Zero unless overrunning.
    public var overrun: TimeInterval {
        if case .overrun(_, let over) = self { return over }
        return 0
    }

    public var remaining: TimeInterval {
        switch self {
        case .idle, .completed, .overrun: return 0
        case .ready(_, let remaining), .running(_, let remaining), .paused(_, let remaining):
            return remaining
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// Whether this phase is a break — the state in which the workday is
    /// resting under Pomodoro control.
    public var isBreakPhase: Bool { kind?.isBreak ?? false }
}

// MARK: - Deriving the axes from the engine and the tracker

/// The phase vocabulary the resolver reads, kept free of the engine type so the
/// resolver and its tests never have to build a live `PomodoroEngine`.
public enum EnginePhase: String, Equatable, Sendable {
    case idle
    case running
    case paused
}

/// The break the Pomodoro coordinator opened, if the workday is resting under
/// Pomodoro control. Identity travels with it so a break started by hand and a
/// break started by a phase are never confused after a restore.
public struct LinkedBreak: Equatable, Sendable, Hashable {
    public let breakID: WorkBreak.ID
    public let kind: SessionKind

    public init(breakID: WorkBreak.ID, kind: SessionKind) {
        self.breakID = breakID
        self.kind = kind
    }
}

extension WorkdayState {
    /// The workday axis, read off the stored clock session.
    public static func resolve(session: ClockSession?, linkedBreak: LinkedBreak?) -> WorkdayState {
        guard let session else { return .clockedOut }
        if let active = session.activeBreak {
            let source: BreakSource =
                (linkedBreak?.breakID == active.id) ? .pomodoro(linkedBreak!.kind) : .manual
            return .onBreak(startedAt: active.startedAt, source: source)
        }
        return .working(startedAt: session.clockedInAt)
    }
}

extension PomodoroState {
    /// The Pomodoro axis, read off the engine.
    ///
    /// The engine has no separate "a cycle is under way" flag: it expresses that
    /// as a cycle position past the first focus. Position 0 while idle therefore
    /// means no phase exists at all, which is the state that makes the manual
    /// Break action valid.
    public static func resolve(
        phase: EnginePhase,
        kind: SessionKind,
        remaining: TimeInterval,
        plannedDuration: TimeInterval,
        overrun: TimeInterval,
        isCycleUnderWay: Bool,
        linkedBreak: LinkedBreak?
    ) -> PomodoroState {
        switch phase {
        case .running:
            // Past the deadline and still counting: the phase has finished but
            // has not been left, and only the user leaves it.
            guard overrun <= 0 else { return .overrun(kind: kind, over: overrun) }
            return .running(kind: kind, remaining: remaining)
        case .paused:
            return .paused(kind: kind, remaining: remaining)
        case .idle:
            // Deliberately not "position past the first focus", which is what
            // this used to ask. That reading had one blind spot and the user
            // found it: scrubbing back to the first focus leaves position 0 and
            // an idle phase, and the app concluded there was no Pomodoro at all
            // — the face dropped to a bare "Break" with the timer gone.
            guard isCycleUnderWay else { return .idle }
            // A break that ran out while auto-start-next-focus was off: the
            // engine has already staged the focus, but the linked work break is
            // still open and work must not resume until the user acts.
            if kind == .focus, let linkedBreak {
                return .completed(kind: linkedBreak.kind)
            }
            return .ready(kind: kind, remaining: plannedDuration)
        }
    }
}
