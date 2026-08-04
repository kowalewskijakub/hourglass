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

    /// Whether a Pomodoro is under way at all, independently of where in the
    /// cycle it happens to sit.
    ///
    /// The engine has no such flag — it infers it from "position past the first
    /// focus" — and that inference has exactly one blind spot: scrubbing back to
    /// the first focus lands on position 0 with an idle phase, which reads as no
    /// Pomodoro whatsoever. The face dropped the timer and showed a bare
    /// "Break". Remembering it here costs one Bool and closes that hole.
    @ObservationIgnored private var cycleIsUnderWay = false

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
            overrun: engine.overrun,
            isCycleUnderWay: hasPomodoroPhase,
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
    public var hasPomodoroPhase: Bool {
        engine.phase != .idle || engine.cyclePosition > 0 || cycleIsUnderWay
    }

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

        // Anything the engine is visibly doing means a cycle is under way, so a
        // state adopted from another device or restored at launch is picked up
        // here rather than having to be announced.
        if engine.phase != .idle || engine.cyclePosition > 0 { cycleIsUnderWay = true }

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

        if hasPomodoroPhase, isResting {
            // The workday is resting, however it got here — a break phase, a
            // focus the user paused, a skip, or a state mirrored from elsewhere.
            // One rest interval: an already-running break is adopted rather
            // than a second one opened beside it.
            if let active = workday.currentSession?.activeBreak {
                linkedBreak = LinkedBreak(breakID: active.id, kind: engine.kind)
            } else if let session = workday.currentSession,
                      let opened = workday.startBreak(id: linkedBreakID(for: session)) {
                linkedBreak = LinkedBreak(breakID: opened.id, kind: engine.kind)
            }
        } else if engine.kind == .focus, engine.phase == .running, linkedBreak != nil {
            // Work is being recorded again, so the linked rest ends before it
            // starts counting. A *staged* focus deliberately does not qualify:
            // the user has not come back yet, and that time is still break time.
            workday.endBreak()
            linkedBreak = nil
        }
    }

    /// Whether the phase the engine is in means the user has stopped working.
    ///
    /// A break phase, obviously — and a **paused focus**, which is the same
    /// thing said differently: the countdown is frozen because the user stepped
    /// away. Leaving that as "working" meant the day went on billing a coffee
    /// run, and the face said "Focus paused" over a total that kept climbing.
    private var isResting: Bool {
        engine.kind.isBreak || (engine.kind == .focus && engine.phase == .paused)
    }

    /// The identity of the rest a break phase opens.
    ///
    /// Both devices run their own countdown off the same deadline, so both reach
    /// the completion and both reconcile. Deriving the id from the day and the
    /// position in the cycle — facts they already agree on — makes the two
    /// writes upsert into one interval instead of two overlapping rests that
    /// would each be subtracted from the day.
    private func linkedBreakID(for session: ClockSession) -> UUID {
        let base = linkedBreakName()
        var candidate = UUID.deterministic(namespace: session.id, name: base)
        // The derivation can legitimately repeat: a break phase returned to
        // after its rest was closed, a focus paused twice inside one second
        // (the instant below truncates to whole seconds), a peer that closed
        // the rest while this device is still paused. Two rows under one id is
        // corruption — `breakDuration` would charge the day twice — so walk to
        // the next generation, which is still derived and so still something
        // two devices arrive at independently.
        var generation = 2
        while session.breaks.contains(where: { $0.id == candidate }), generation <= 64 {
            candidate = .deterministic(namespace: session.id, name: "\(base)#\(generation)")
            generation += 1
        }
        return candidate
    }

    /// The facts two devices must agree on to name the same rest.
    private func linkedBreakName() -> String {
        // A focus can be paused, resumed and paused again without the cycle
        // position ever moving, so the freeze instant is what tells those
        // rests apart. Both devices carry the same `pausedAt` — it travels in
        // the live state — so they still derive the same name.
        if engine.kind == .focus, let pausedAt = engine.pausedAt {
            return "paused-focus-\(engine.cyclePosition)-\(Int(pausedAt.timeIntervalSince1970))"
        }
        return "linked-break-\(engine.cyclePosition)"
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
        case .endPomodoro:
            endPomodoro()
        case .continuePhase:
            engine.advance()
        case .previousPhase:
            scrub { engine.goToPreviousPhase() }
        case .nextPhase:
            scrub { engine.goToNextPhase() }
        }
        // Which actions mean "there is a Pomodoro going", spelled out rather
        // than inferred. The one that matters is the scrub, which can land back
        // on the first focus and leave the engine looking exactly like a day
        // with no timer in it. Clocking in and taking a manual break start no
        // cycle; leaving one and coming back from a rest must not resurrect it.
        switch action {
        case .startFocus, .startPhase, .restartPhase, .pause, .resume,
             .continuePhase, .previousPhase, .nextPhase:
            cycleIsUnderWay = true
        case .clockIn, .startBreak, .backToWork, .endPomodoro:
            break
        }
        reconcile()
    }

    /// Move to a named phase, and drop the link if that move leaves a break.
    ///
    /// The arrows move the Pomodoro axis and nothing else. Scrubbing off a
    /// break deliberately does **not** close the rest it opened: a user
    /// stepping forward and back through the cycle would otherwise stitch the
    /// afternoon out of a dozen fragments, one rest row per press. What ends is
    /// the *link* — the phase that owned the rest is gone, so what is left is an
    /// ordinary work break, still running, until the user starts the focus or
    /// comes back by hand. Scrubbing onto a break again re-adopts that same
    /// interval in `reconcile()` rather than opening a second one.
    ///
    /// Dropping the link is also what puts a focus back on screen. While it
    /// survived, `PomodoroState.resolve` saw an open linked break under an idle
    /// focus and answered `.completed`, so the face went on saying "Break
    /// complete" and the arrows appeared to step from one break to the next with
    /// no focus in between. `.completed` is left to the case it was written for:
    /// a break whose countdown genuinely ran out.
    private func scrub(_ move: () -> Void) {
        let wasBreakPhase = hasPomodoroPhase && engine.kind.isBreak
        move()
        if wasBreakPhase, !engine.kind.isBreak { linkedBreak = nil }
    }

    /// Leave Pomodoro and go back to work, without ending the working day.
    ///
    /// The workday is the spine: being done with the timer is not being done
    /// for the day, and the only way out used to be clocking out.
    ///
    /// A rest that is open when the cycle ends is closed with it. The action is
    /// only ever offered while a phase exists, so the rest it finds is the one
    /// the timer opened — and someone reaching for "End Pomodoro" in the middle
    /// of a scheduled break is saying they are done being scheduled, not that
    /// they would like to keep resting indefinitely. (Leaving it running put the
    /// user back on the face as though they had started a manual break, which is
    /// the opposite of what they asked for.) Stopping for a rest that is *not*
    /// scheduled is still one tap away: Break.
    public func endPomodoro() {
        engine.endCycle()
        linkedBreak = nil
        cycleIsUnderWay = false
        workday.endBreak()
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
        cycleIsUnderWay = false
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
