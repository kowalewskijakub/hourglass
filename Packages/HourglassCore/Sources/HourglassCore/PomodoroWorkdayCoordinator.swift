import Foundation
import Observation

/// Keeps the Pomodoro phase and the workday telling one story.
///
/// From the user's point of view a Pomodoro short or long break and a manual
/// work break are the same thing: they stopped working for a bit. So a break
/// phase opens exactly one work-break interval — the same interval the daily
/// totals and History already count — and coming back to work closes it.
///
/// Everything here is expressed as one idempotent ``reconcile()`` rather than a
/// set of transition handlers, because the transitions arrive more than once and
/// out of order: a completion callback fires, the app returns from the
/// background, a sync pull mirrors the same phase from another device, and a
/// restore replays it all after a cold launch. A handler per transition opened a
/// second break every time; converging on the state instead cannot.
@MainActor
@Observable
public final class PomodoroWorkdayCoordinator {
    private let engine: PomodoroEngine
    private let workday: WorkdayTracker

    /// The work break the current Pomodoro break phase owns, if any. This is
    /// what makes "Pomodoro" versus "Manual" answerable for the live state
    /// without a second persisted field on the break itself.
    public private(set) var linkedBreak: LinkedBreak?

    /// Guards against the re-entrancy the tracker's own change notifications
    /// would otherwise cause: starting a break notifies observers, and an
    /// observer that reconciles would run inside the write that caused it.
    @ObservationIgnored private var isReconciling = false

    public init(engine: PomodoroEngine, workday: WorkdayTracker) {
        self.engine = engine
        self.workday = workday
    }

    // MARK: State

    /// The workday axis as the surfaces should read it.
    public var workdayState: WorkdayState {
        WorkdayState.resolve(session: workday.currentSession, linkedBreak: linkedBreak)
    }

    /// The Pomodoro axis as the surfaces should read it.
    public var pomodoroState: PomodoroState {
        PomodoroState.resolve(
            phase: enginePhase,
            kind: engine.kind,
            remaining: engine.remaining,
            plannedDuration: engine.plannedDuration,
            cyclePosition: engine.cyclePosition,
            linkedBreak: linkedBreak
        )
    }

    private var enginePhase: EnginePhase {
        switch engine.phase {
        case .idle: return .idle
        case .running: return .running
        case .paused: return .paused
        }
    }

    /// True while any Pomodoro phase exists — running, paused, staged, or a
    /// finished break still waiting for the user. Exactly when the separate
    /// workday Break action must be hidden.
    public var hasPomodoroPhase: Bool { engine.phase != .idle || engine.cyclePosition > 0 }

    // MARK: Reconciliation

    /// Bring the workday into agreement with the phase the engine is in.
    ///
    /// Safe to call as often as anything changes — after an engine callback, on
    /// returning to the foreground, after a sync pull, after a restore. Calling
    /// it twice does nothing the first call did not already do.
    public func reconcile() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        // Drop a link whose interval is no longer the running one: it was ended
        // here, edited away in History, or replaced by a pull from another
        // device. Without this a later manual break would inherit "Pomodoro".
        if let linked = linkedBreak, workday.currentSession?.activeBreak?.id != linked.breakID {
            linkedBreak = nil
        }

        guard workday.isClockedIn else {
            linkedBreak = nil
            return
        }

        if hasPomodoroPhase, engine.kind.isBreak {
            // A break phase means the workday is resting, however it got here —
            // a focus completing, a skip, or a state mirrored from elsewhere.
            // One rest interval: an already-running break is adopted rather
            // than a second one opened beside it.
            if let active = workday.currentSession?.activeBreak {
                linkedBreak = LinkedBreak(breakID: active.id, kind: engine.kind)
            } else if let session = workday.currentSession,
                      let opened = workday.startBreak(id: linkedBreakID(for: session)) {
                linkedBreak = LinkedBreak(breakID: opened.id, kind: engine.kind)
            }
        } else if engine.kind == .focus, engine.phase != .idle, linkedBreak != nil {
            // Work is being recorded again, so the linked rest ends before it
            // starts counting. A *staged* focus deliberately does not qualify:
            // the user has not come back yet, and that time is still break time.
            workday.endBreak()
            linkedBreak = nil
        }
    }

    /// The identity of the rest a break phase opens.
    ///
    /// Both devices run their own countdown off the same deadline, so both reach
    /// the completion and both reconcile. Deriving the id from the day and the
    /// position in the cycle — facts they already agree on — makes the two
    /// writes upsert into one interval instead of two overlapping rests that
    /// would each be subtracted from the day.
    private func linkedBreakID(for session: ClockSession) -> UUID {
        .deterministic(namespace: session.id, name: "linked-break-\(engine.cyclePosition)")
    }

    // MARK: Intent

    /// Run one resolved action. The coordinator owns these rather than the views
    /// because most of them mean two things at once — "leave the break phase"
    /// *and* "close the work break it opened".
    public func perform(_ action: OrbitAction) {
        switch action {
        case .clockIn:
            workday.clockIn()
        case .startFocus:
            startFocus()
        case .startBreak:
            startManualBreak()
        case .startPhase:
            engine.start()
        case .backToWork:
            backToWork()
        case .restartPhase:
            restartPhase()
        case .pause:
            engine.pause()
        case .resume:
            engine.resume()
        case .previousPhase:
            engine.goToPreviousPhase()
        case .nextPhase:
            engine.goToNextPhase()
        }
        reconcile()
    }

    /// Leave Pomodoro without ending the working day.
    ///
    /// The workday is the spine: being done with the timer is not being done
    /// for the day, and the only way out used to be clocking out. A rest that
    /// is open when the cycle ends simply carries on as a manual break — the
    /// user is still resting, whatever stopped scheduling it.
    public func endPomodoro() {
        engine.endCycle()
        linkedBreak = nil
        reconcile()
    }

    /// Start a manual work break. Valid only while working with no Pomodoro
    /// phase of any kind — the same rule the Break button's visibility uses, so
    /// a stale tap cannot open a break the UI would then have to explain.
    public func startManualBreak() {
        guard workday.isClockedIn, !workday.isOnBreak, !hasPomodoroPhase else { return }
        workday.startBreak()
        linkedBreak = nil // started by hand, not by a phase
    }

    /// End the working day. Stops any phase, closes any open break, and leaves
    /// no staged phase behind to keep describing a Pomodoro that is over.
    public func clockOut() {
        engine.endCycle()
        workday.clockOut()
        linkedBreak = nil
    }

    private func startFocus() {
        // Defensive: the resolver only offers Start focus on a focus phase, but
        // a state mirrored mid-transition could disagree.
        if engine.kind != .focus { engine.goToNextPhase() }
        engine.start()
    }

    /// Restart the current phase from its full duration. Going through `reset()`
    /// first is deliberate: a focus that already ran a meaningful stretch is
    /// recorded as real focused time rather than silently discarded.
    private func restartPhase() {
        engine.reset()
        engine.start()
    }

    /// Leave the current work break and resume working.
    ///
    /// For a Pomodoro break this also leaves the break phase, so the next thing
    /// the engine offers is the focus the user is going back to. For a manual
    /// break it does exactly one thing — end the break — and never invents a
    /// Pomodoro phase the user did not ask for.
    private func backToWork() {
        if hasPomodoroPhase, engine.kind.isBreak {
            engine.goToNextPhase()
        }
        workday.endBreak()
        linkedBreak = nil

        if engine.settings.autoStartFocus,
           engine.cyclePosition > 0,
           engine.kind == .focus,
           engine.phase == .idle {
            engine.start()
        }
    }
}
