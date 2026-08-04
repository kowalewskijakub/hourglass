import Testing
import Foundation
@testable import HourglassCore

/// The coordinator is what makes "a Pomodoro break is a work break" true rather
/// than merely stated. These tests pin the transition table and, just as
/// importantly, the idempotency: the same transition arrives repeatedly — from a
/// callback, from a foreground refresh, from a sync pull — and must never open a
/// second rest interval.
@MainActor
@Suite struct PomodoroWorkdayCoordinatorTests {

    private struct Rig {
        let engine: PomodoroEngine
        let workday: WorkdayTracker
        let coordinator: PomodoroWorkdayCoordinator
        let clock: TestClock
        let store: InMemoryWorkdayStore
    }

    /// Fast durations: focus 100s, short break 20s, long break 40s.
    private func makeRig(
        autoStartBreaks: Bool = false,
        autoStartFocus: Bool = false
    ) -> Rig {
        let settings = TimerSettings(
            focusDuration: 100,
            shortBreakDuration: 20,
            longBreakDuration: 40,
            sessionsUntilLongBreak: 4,
            autoStartBreaks: autoStartBreaks,
            autoStartFocus: autoStartFocus
        )
        let clock = TestClock()
        let workdayStore = InMemoryWorkdayStore()
        let engine = PomodoroEngine(
            settingsStore: InMemorySettingsStore(settings: settings),
            history: InMemoryHistoryStore(),
            clock: clock,
            tickInterval: 1
        )
        let workday = WorkdayTracker(store: workdayStore, clock: clock)
        let coordinator = PomodoroWorkdayCoordinator(engine: engine, workday: workday)

        // Wired the way the app wires it: the tracker follows a focus starting,
        // and the coordinator reconciles after anything the engine announces.
        engine.onSessionStarted = { kind, _ in
            workday.sessionStarted(kind: kind)
            coordinator.reconcile()
        }
        engine.onSessionCompleted = { _ in coordinator.reconcile() }
        engine.onSessionInterrupted = { _ in coordinator.reconcile() }

        return Rig(engine: engine, workday: workday, coordinator: coordinator,
                   clock: clock, store: workdayStore)
    }

    private func breaks(_ rig: Rig) -> [WorkBreak] {
        rig.workday.currentSession?.breaks ?? []
    }

    /// Run the current phase out **and take the user's Continue**.
    ///
    /// Reaching zero no longer moves anything: the phase records itself and
    /// counts on until the user says they are done with it. Every test that
    /// used to write `clock.advance(by: 100)` and mean "and now we are on the
    /// break" says both halves through this.
    private func finish(_ rig: Rig, after seconds: TimeInterval) {
        rig.clock.advance(by: seconds)
        rig.coordinator.perform(.continuePhase)
    }

    // MARK: One linked interval

    @Test func aCompletedFocusOpensExactlyOneWorkBreak() {
        let rig = makeRig()
        rig.engine.start()
        #expect(rig.workday.isClockedIn)

        finish(rig, after: 100) // focus runs out, user continues

        #expect(rig.engine.kind == .shortBreak)
        #expect(rig.workday.isOnBreak)
        #expect(breaks(rig).count == 1)
        #expect(rig.coordinator.workdayState.breakSource == .pomodoro(.shortBreak))
    }

    @Test func aLongBreakOpensOneWorkBreakToo() {
        let rig = makeRig()
        rig.workday.clockIn()
        // Land on the long break: position 7 in a four-focus cycle.
        for _ in 0..<7 { rig.engine.goToNextPhase() }
        rig.coordinator.reconcile()

        #expect(rig.engine.kind == .longBreak)
        #expect(breaks(rig).count == 1)
        #expect(rig.coordinator.workdayState.breakSource == .pomodoro(.longBreak))
    }

    @Test func autoStartedBreakContinuesTheSameInterval() {
        let rig = makeRig(autoStartBreaks: true)
        rig.engine.start()
        finish(rig, after: 100)

        // The break auto-started; the interval opened at the continue is the one
        // still running, not a second one opened by the timer starting.
        #expect(rig.engine.phase == .running)
        #expect(breaks(rig).count == 1)
        #expect(rig.workday.isOnBreak)
    }

    @Test func aStagedBreakHasAlreadyStoppedWorkTimeAccumulating() {
        let rig = makeRig(autoStartBreaks: false)
        rig.engine.start()
        finish(rig, after: 100)

        // Auto-start is off, so the countdown waits at full duration — but the
        // workday is already resting, because the user stopped working.
        #expect(rig.engine.phase == .idle)
        #expect(rig.engine.remaining == 20)
        #expect(rig.workday.isOnBreak)
        #expect(rig.coordinator.pomodoroState == .ready(kind: .shortBreak, remaining: 20))
    }

    @Test func startingTheStagedBreakTimerDoesNotOpenASecondInterval() {
        let rig = makeRig(autoStartBreaks: false)
        rig.engine.start()
        finish(rig, after: 100)
        let opened = breaks(rig).first?.id

        rig.coordinator.perform(.startPhase)

        #expect(rig.engine.phase == .running)
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.id == opened)
    }

    // MARK: Coming back

    @Test func backToWorkEndsTheLinkedBreakAndLeavesThePhase() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)
        rig.clock.jump(by: 12)

        rig.coordinator.perform(.backToWork)

        #expect(rig.workday.isOnBreak == false)
        #expect(rig.workday.currentSession?.breakDuration(asOf: rig.clock.now) == 12)
        #expect(rig.engine.kind == .focus)
        #expect(rig.coordinator.linkedBreak == nil)
        #expect(rig.coordinator.pomodoroState == .ready(kind: .focus, remaining: 100))
    }

    @Test func startingTheNextFocusEndsTheLinkedBreak() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)
        rig.clock.jump(by: 8)

        rig.coordinator.perform(.nextPhase) // break -> focus, still staged
        #expect(rig.workday.isOnBreak, "a staged focus must not resume work on its own")

        rig.coordinator.perform(.startFocus)

        #expect(rig.workday.isOnBreak == false)
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.endedAt != nil)
    }

    // MARK: Scrubbing through the cycle

    /// The reported bug: from a break, ">" appeared to skip focus entirely and
    /// step from one break to the next. The link outliving the phase is what did
    /// it — an open linked break under an idle focus resolves as `.completed`,
    /// which the face draws as "Break complete".
    @Test func scrubbingOffABreakLandsOnAFocusRatherThanOnBreakComplete() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100) // focus runs out, user continues to the break
        #expect(rig.engine.kind == .shortBreak)

        rig.coordinator.perform(.nextPhase)

        #expect(rig.engine.kind == .focus)
        #expect(rig.coordinator.linkedBreak == nil)
        #expect(rig.coordinator.pomodoroState == .ready(kind: .focus, remaining: 100))
        #expect(OrbitPresentationResolver.state(
            workday: rig.coordinator.workdayState,
            pomodoro: rig.coordinator.pomodoroState
        ) == .focusStaged)
    }

    /// Scrubbing moves the Pomodoro axis and nothing else. The rest stays open —
    /// the user has not come back yet — and it is the *same* rest, so stepping
    /// through the cycle cannot shred the afternoon into a row per keypress.
    @Test func scrubbingNeverFragmentsTheRestItPassesThrough() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)
        let opened = breaks(rig).first?.id

        rig.coordinator.perform(.nextPhase)     // break -> focus
        #expect(rig.workday.isOnBreak, "a staged focus must not resume work on its own")
        #expect(rig.coordinator.workdayState.breakSource == .manual)

        rig.coordinator.perform(.previousPhase) // focus -> break again
        #expect(rig.coordinator.linkedBreak?.breakID == opened)

        rig.coordinator.perform(.nextPhase)
        rig.coordinator.perform(.previousPhase)

        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.id == opened)
    }

    /// The state `.completed` was written for, kept intact: a break whose
    /// countdown genuinely ran out still waits with the workday resting.
    @Test func aBreakThatRanOutStillReadsAsBreakComplete() {
        let rig = makeRig(autoStartBreaks: true, autoStartFocus: false)
        rig.engine.start()
        finish(rig, after: 100)   // focus out, continue -> break auto-starts
        finish(rig, after: 20)    // break out, continue -> focus staged

        #expect(rig.coordinator.pomodoroState == .completed(kind: .shortBreak))
        #expect(rig.coordinator.linkedBreak != nil)
    }

    @Test func endPomodoroIsReachableAsAnAction() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)

        rig.coordinator.perform(.endPomodoro)

        #expect(rig.coordinator.hasPomodoroPhase == false)
        #expect(rig.coordinator.linkedBreak == nil)
        // The day carries on; only the timer is finished with.
        #expect(rig.workday.isClockedIn)
    }

    @Test func aFinishedBreakWaitsWithTheWorkdayStillResting() {
        let rig = makeRig(autoStartBreaks: true, autoStartFocus: false)
        rig.engine.start()
        finish(rig, after: 100) // focus out, continue -> break auto-starts
        finish(rig, after: 20)  // break out, continue -> focus staged

        #expect(rig.engine.kind == .focus)
        #expect(rig.engine.phase == .idle)
        #expect(rig.workday.isOnBreak, "work must not resume until the user acts")
        #expect(rig.coordinator.pomodoroState == .completed(kind: .shortBreak))

        rig.coordinator.perform(.backToWork)
        #expect(rig.workday.isOnBreak == false)
    }

    @Test func autoStartedNextFocusEndsTheBreakByItself() {
        let rig = makeRig(autoStartBreaks: true, autoStartFocus: true)
        rig.engine.start()
        finish(rig, after: 100)
        finish(rig, after: 20)

        #expect(rig.engine.kind == .focus)
        #expect(rig.engine.phase == .running)
        #expect(rig.workday.isOnBreak == false)
        #expect(breaks(rig).count == 1)
    }

    // MARK: Manual breaks

    @Test func manualBreakIsOnlyPossibleWithNoPomodoroPhase() {
        let rig = makeRig()
        rig.workday.clockIn()

        rig.coordinator.startManualBreak()
        #expect(rig.workday.isOnBreak)
        #expect(rig.coordinator.workdayState.breakSource == .manual)

        rig.coordinator.perform(.backToWork)
        #expect(rig.workday.isOnBreak == false)

        // With a phase in play the action is inert — the UI hides it, and a
        // stale tap must not open a break the face would have to explain.
        rig.engine.start()
        rig.coordinator.startManualBreak()
        #expect(rig.workday.isOnBreak == false)
    }

    @Test func backToWorkFromAManualBreakStartsNoPomodoro() {
        let rig = makeRig(autoStartFocus: true)
        rig.workday.clockIn()
        rig.coordinator.startManualBreak()

        rig.coordinator.perform(.backToWork)

        #expect(rig.workday.isOnBreak == false)
        #expect(rig.engine.phase == .idle)
        #expect(rig.coordinator.pomodoroState == .idle)
    }

    // MARK: Focus pause

    /// Pausing a focus is taking a break, so the workday stops counting the time
    /// as work. Leaving it as "working" meant the day went on billing a coffee
    /// run while the face said the timer was paused.
    @Test func pausingFocusOpensARealBreak() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 30)

        rig.coordinator.perform(.pause)

        #expect(rig.workday.isClockedIn)
        #expect(rig.workday.isOnBreak)
        #expect(rig.coordinator.workdayState.breakSource == .pomodoro(.focus))
        #expect(rig.engine.pausedAt == rig.clock.now)
        #expect(breaks(rig).count == 1)
    }

    /// Resuming closes it and the focus carries on from where it stopped —
    /// pausing costs the day its break time, never its focus progress.
    @Test func resumingClosesTheBreakAndKeepsTheFocusWhereItWas() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 30)
        rig.coordinator.perform(.pause)
        let remaining = rig.engine.remaining
        rig.clock.jump(by: 45)

        rig.coordinator.perform(.resume)

        #expect(rig.workday.isOnBreak == false)
        #expect(rig.coordinator.workdayState.isWorking)
        #expect(rig.engine.remaining == remaining, "the focus resumes where it was frozen")
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.endedAt != nil)
        #expect(rig.workday.currentSession?.breakDuration(asOf: rig.clock.now) == 45)
    }

    /// Pause, resume, pause again inside one cycle position is two rests, not
    /// one row written twice: the freeze instant is part of the derived id.
    @Test func pausingTwiceRecordsTwoSeparateRests() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 10)

        rig.coordinator.perform(.pause)
        rig.clock.jump(by: 20)
        rig.coordinator.perform(.resume)
        rig.clock.advance(by: 10)
        rig.coordinator.perform(.pause)

        #expect(breaks(rig).count == 2)
        #expect(Set(breaks(rig).map(\.id)).count == 2)
    }

    /// Two rows under one id is corruption, not a duplicate: the day's break
    /// total reduces over the array and would charge the pause twice, and every
    /// edit resolves by id and could only ever reach the first copy.
    ///
    /// The derivation can legitimately repeat — a peer closes the rest while
    /// this device is still paused, or two pauses land inside one second — so
    /// this is the case that has to stay safe.
    @Test func aRestClosedElsewhereWhilePausedNeverProducesTwoRowsUnderOneID() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 10)
        rig.coordinator.perform(.pause)
        let opened = breaks(rig).first!

        // What a peer's "resumed over there" looks like locally: the interval is
        // closed by its own row arriving, while this engine is still paused.
        var closed = opened
        closed.endedAt = rig.clock.now
        rig.workday.updateBreak(sessionID: rig.workday.currentSession!.id, entry: closed)

        rig.coordinator.reconcile()
        rig.coordinator.reconcile()

        #expect(Set(breaks(rig).map(\.id)).count == breaks(rig).count,
                "every rest must have its own id")
        #expect(breaks(rig).filter(\.isActive).count <= 1)
    }

    /// The same guard one level down: the tracker refuses an id it already
    /// holds, whoever asks and however the id was derived.
    @Test func theTrackerRefusesARestIDItAlreadyHolds() {
        let rig = makeRig()
        rig.workday.clockIn()
        let id = UUID()
        let first = rig.workday.startBreak(id: id)
        rig.workday.endBreak()

        #expect(first != nil)
        #expect(rig.workday.startBreak(id: id) == nil, "an id already in the day is refused")
        #expect(breaks(rig).count == 1)
    }

    /// Reconciling repeatedly while paused must not open a second rest.
    @Test func reconcilingAPausedFocusIsIdempotent() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 30)
        rig.coordinator.perform(.pause)

        rig.coordinator.reconcile()
        rig.coordinator.reconcile()

        #expect(breaks(rig).count == 1)
    }

    // MARK: Idempotency and restoration

    @Test func repeatedReconciliationNeverOpensASecondBreak() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)

        for _ in 0..<10 { rig.coordinator.reconcile() }

        #expect(breaks(rig).count == 1)
    }

    /// A cold launch: the stores come back, the coordinator has no memory of the
    /// link, and the engine is mid-break. Reconciling must adopt the interval
    /// that is already open rather than opening another beside it.
    @Test func restorationAdoptsTheOpenIntervalInsteadOfDuplicatingIt() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)
        let openedID = breaks(rig).first?.id

        let restored = PomodoroWorkdayCoordinator(engine: rig.engine, workday: rig.workday)
        #expect(restored.linkedBreak == nil)
        restored.reconcile()

        #expect(breaks(rig).count == 1)
        #expect(restored.linkedBreak?.breakID == openedID)
        #expect(restored.workdayState.breakSource == .pomodoro(.shortBreak))
    }

    /// A break phase mirrored from another device arrives with no local callback
    /// at all; reconciling is what makes the workday agree with it.
    @Test func aSyncedBreakPhaseOpensTheLinkedInterval() {
        let rig = makeRig()
        rig.workday.clockIn()

        rig.engine.applyRemoteState(
            cyclePosition: 1,
            isRunning: true,
            endDate: rig.clock.now.addingTimeInterval(15),
            pausedAt: nil,
            sessionID: UUID()
        )
        rig.coordinator.reconcile()
        rig.coordinator.reconcile()

        #expect(rig.workday.isOnBreak)
        #expect(breaks(rig).count == 1)
    }

    /// A break the user deletes in History, or that a peer's edit closes, must
    /// not leave the link pointing at an interval that is gone.
    @Test func aVanishedIntervalDropsTheLink() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100)
        #expect(rig.coordinator.linkedBreak != nil)

        rig.workday.endBreak()
        rig.coordinator.reconcile()

        // The phase is still a break, so reconciliation legitimately opens the
        // rest interval again — but as one interval, freshly linked.
        #expect(breaks(rig).count == 2)
        #expect(rig.coordinator.linkedBreak?.breakID == breaks(rig).last?.id)
    }

    /// Two devices run the same countdown off the same deadline, so both reach
    /// the completion and both open a rest. They must be the *same* rest: two
    /// rows would sync into two overlapping breaks and take the time off the
    /// day twice.
    @Test func twoDevicesCompletingTheSameFocusOpenOneSharedInterval() {
        let clockedInAt = Date(timeIntervalSince1970: 1_700_000_000)
        let shared = ClockSession(id: UUID(), clockedInAt: clockedInAt)

        func breakID(onDeviceSeeded seed: Int) -> WorkBreak.ID {
            let rig = makeRig()
            rig.workday.add(shared)
            // Both devices sit at the same point in the cycle, however they got
            // there — a local completion here, a mirrored one there.
            for _ in 0..<seed { rig.engine.goToNextPhase() }
            rig.coordinator.reconcile()
            return rig.workday.currentSession?.activeBreak?.id ?? UUID()
        }

        #expect(breakID(onDeviceSeeded: 1) == breakID(onDeviceSeeded: 1))
        // A different phase is a different rest, and keeps its own identity.
        #expect(breakID(onDeviceSeeded: 1) != breakID(onDeviceSeeded: 3))
    }

    // MARK: Leaving Pomodoro

    /// Being done with the timer is not being done for the day. Ending the cycle
    /// leaves the workday running — and puts the manual Break action back.
    @Test func endingPomodoroKeepsTheWorkdayRunning() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 30)

        rig.coordinator.endPomodoro()

        #expect(rig.workday.isClockedIn)
        #expect(rig.workday.isOnBreak == false)
        #expect(rig.coordinator.hasPomodoroPhase == false)
        #expect(rig.coordinator.pomodoroState == .idle)

        rig.coordinator.startManualBreak()
        #expect(rig.workday.isOnBreak, "Break is valid again once no phase exists")
    }

    /// Ending the cycle mid-rest puts the user back to work. The action is only
    /// ever offered while a phase exists, so the rest it closes is the one the
    /// timer opened — and someone reaching for it is saying they are done being
    /// scheduled, not that they would like to go on resting indefinitely.
    ///
    /// The rest itself is kept, closed at the moment they came back: it happened.
    @Test func endingPomodoroDuringABreakComesBackToWork() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100) // linked break opens
        let opened = breaks(rig).first?.id
        rig.clock.jump(by: 30)

        rig.coordinator.endPomodoro()

        #expect(rig.workday.isClockedIn)
        #expect(rig.workday.isOnBreak == false)
        #expect(rig.coordinator.workdayState.isWorking)
        #expect(rig.coordinator.hasPomodoroPhase == false)
        // The rest is closed, not erased.
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.id == opened)
        #expect(breaks(rig).first?.endedAt != nil)
        #expect(rig.workday.currentSession?.breakDuration(asOf: rig.clock.now) == 30)

        // And Break is available again, because no phase is scheduling one.
        rig.coordinator.startManualBreak()
        #expect(rig.workday.isOnBreak)
    }

    // MARK: Clock out

    @Test func clockingOutStopsThePhaseAndClosesTheBreak() {
        let rig = makeRig()
        rig.engine.start()
        finish(rig, after: 100) // now on a linked break

        rig.coordinator.clockOut()

        #expect(rig.workday.isClockedIn == false)
        #expect(rig.engine.phase == .idle)
        #expect(rig.engine.cyclePosition == 0)
        #expect(rig.coordinator.pomodoroState == .idle)
        #expect(rig.coordinator.linkedBreak == nil)
        #expect(rig.store.all().first?.breaks.allSatisfy { $0.endedAt != nil } == true)
    }

    @Test func clockingOutWhileClockedOutLeavesNoPhaseBehind() {
        let rig = makeRig()
        rig.engine.start()
        rig.coordinator.clockOut()

        // A staged phase left behind would keep every surface describing a
        // Pomodoro on a day that has ended — and keep Break hidden tomorrow.
        #expect(rig.coordinator.hasPomodoroPhase == false)
    }

    // MARK: Restart

    @Test func restartingAPhaseKeepsTheLinkedBreakIntact() {
        let rig = makeRig(autoStartBreaks: true)
        rig.engine.start()
        finish(rig, after: 100)
        rig.clock.advance(by: 5)
        let openedID = breaks(rig).first?.id

        rig.coordinator.perform(.restartPhase)

        #expect(rig.engine.remaining == 20)
        #expect(rig.engine.phase == .running)
        #expect(breaks(rig).count == 1)
        #expect(rig.coordinator.linkedBreak?.breakID == openedID)
    }
}
