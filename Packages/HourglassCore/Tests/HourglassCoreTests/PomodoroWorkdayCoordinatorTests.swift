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

    // MARK: One linked interval

    @Test func aCompletedFocusOpensExactlyOneWorkBreak() {
        let rig = makeRig()
        rig.engine.start()
        #expect(rig.workday.isClockedIn)

        rig.clock.advance(by: 100) // focus completes

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
        rig.clock.advance(by: 100)

        // The break auto-started; the interval opened at completion is the one
        // still running, not a second one opened by the timer starting.
        #expect(rig.engine.phase == .running)
        #expect(breaks(rig).count == 1)
        #expect(rig.workday.isOnBreak)
    }

    @Test func aStagedBreakHasAlreadyStoppedWorkTimeAccumulating() {
        let rig = makeRig(autoStartBreaks: false)
        rig.engine.start()
        rig.clock.advance(by: 100)

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
        rig.clock.advance(by: 100)
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
        rig.clock.advance(by: 100)
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
        rig.clock.advance(by: 100)
        rig.clock.jump(by: 8)

        rig.coordinator.perform(.nextPhase) // break -> focus, still staged
        #expect(rig.workday.isOnBreak, "a staged focus must not resume work on its own")

        rig.coordinator.perform(.startFocus)

        #expect(rig.workday.isOnBreak == false)
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.endedAt != nil)
    }

    @Test func aFinishedBreakWaitsWithTheWorkdayStillResting() {
        let rig = makeRig(autoStartBreaks: true, autoStartFocus: false)
        rig.engine.start()
        rig.clock.advance(by: 100) // focus completes, break auto-starts
        rig.clock.advance(by: 20)  // break completes

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
        rig.clock.advance(by: 100)
        rig.clock.advance(by: 20)

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

    @Test func pausingFocusDoesNotPauseTheWorkday() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 30)

        rig.coordinator.perform(.pause)

        #expect(rig.workday.isOnBreak == false)
        #expect(rig.workday.isClockedIn)
        #expect(rig.coordinator.workdayState.isWorking)
        #expect(rig.engine.pausedAt == rig.clock.now)
    }

    // MARK: Idempotency and restoration

    @Test func repeatedReconciliationNeverOpensASecondBreak() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 100)

        for _ in 0..<10 { rig.coordinator.reconcile() }

        #expect(breaks(rig).count == 1)
    }

    /// A cold launch: the stores come back, the coordinator has no memory of the
    /// link, and the engine is mid-break. Reconciling must adopt the interval
    /// that is already open rather than opening another beside it.
    @Test func restorationAdoptsTheOpenIntervalInsteadOfDuplicatingIt() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 100)
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
        rig.clock.advance(by: 100)
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

    /// Ending the cycle mid-rest does not drag the user back to work: they are
    /// still resting, it is just no longer a scheduled break.
    @Test func endingPomodoroDuringABreakLeavesTheRestRunningAsManual() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 100) // linked break opens
        let opened = breaks(rig).first?.id

        rig.coordinator.endPomodoro()

        #expect(rig.workday.isOnBreak)
        #expect(breaks(rig).count == 1)
        #expect(breaks(rig).first?.id == opened)
        #expect(rig.coordinator.workdayState.breakSource == .manual)
    }

    // MARK: Clock out

    @Test func clockingOutStopsThePhaseAndClosesTheBreak() {
        let rig = makeRig()
        rig.engine.start()
        rig.clock.advance(by: 100) // now on a linked break

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
        rig.clock.advance(by: 100)
        rig.clock.advance(by: 5)
        let openedID = breaks(rig).first?.id

        rig.coordinator.perform(.restartPhase)

        #expect(rig.engine.remaining == 20)
        #expect(rig.engine.phase == .running)
        #expect(breaks(rig).count == 1)
        #expect(rig.coordinator.linkedBreak?.breakID == openedID)
    }
}
