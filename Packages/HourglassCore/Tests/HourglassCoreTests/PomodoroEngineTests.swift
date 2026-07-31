import Testing
import Foundation
@testable import HourglassCore

@MainActor
@Suite struct PomodoroEngineTests {

    /// Fast test durations: focus 100s, short 20s, long 40s, long break every 4.
    private func makeEngine(
        settings: TimerSettings = TimerSettings(
            focusDuration: 100,
            shortBreakDuration: 20,
            longBreakDuration: 40,
            sessionsUntilLongBreak: 4
        ),
        history: InMemoryHistoryStore = InMemoryHistoryStore(),
        clock: TestClock = TestClock()
    ) -> (engine: PomodoroEngine, history: InMemoryHistoryStore, clock: TestClock) {
        let store = InMemorySettingsStore(settings: settings)
        let engine = PomodoroEngine(settingsStore: store, history: history, clock: clock, tickInterval: 1)
        return (engine, history, clock)
    }

    @Test func startsIdleAtFocusDuration() {
        let (engine, _, _) = makeEngine()
        #expect(engine.kind == .focus)
        #expect(engine.phase == .idle)
        #expect(engine.remaining == 100)
        #expect(engine.progress == 0)
    }

    @Test func runningCountsDownAgainstTheClock() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        #expect(engine.phase == .running)
        #expect(clock.isScheduled)
        clock.advance(by: 30)
        #expect(engine.remaining == 70)
        #expect(abs(engine.progress - 0.3) < 0.0001)
    }

    @Test func completingFocusRecordsSessionAndAdvancesToShortBreak() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        clock.advance(by: 100)

        #expect(engine.kind == .shortBreak)
        #expect(engine.phase == .idle)
        #expect(engine.cyclePosition == 1)
        #expect(engine.remaining == 20)
        #expect(clock.isScheduled == false)

        let sessions = history.all()
        #expect(sessions.count == 1)
        #expect(sessions.first?.kind == .focus)
        #expect(sessions.first?.completed == true)
    }

    @Test func completionCallbackFiresWithFinishedSession() {
        let (engine, _, clock) = makeEngine()
        var completed: [FocusSession] = []
        engine.onSessionCompleted = { completed.append($0) }
        engine.start()
        clock.advance(by: 100)
        #expect(completed.count == 1)
        #expect(completed.first?.kind == .focus)
    }

    @Test func longBreakArrivesAfterConfiguredNumberOfFocusSessions() {
        let (engine, _, clock) = makeEngine() // long break every 4
        for i in 1...4 {
            #expect(engine.kind == .focus)
            engine.start()
            clock.advance(by: 100) // complete focus
            if i < 4 {
                #expect(engine.kind == .shortBreak)
                engine.start()
                clock.advance(by: 20) // complete short break -> back to focus
                #expect(engine.kind == .focus)
            } else {
                #expect(engine.kind == .longBreak)
            }
        }
        #expect(engine.cyclePosition == 7) // Focus1..Break3, Focus4 done -> long break
    }

    @Test func arrowsScrubBidirectionallyThroughTheCycle() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        clock.advance(by: 10)
        engine.goToNextPhase()
        #expect(engine.kind == .shortBreak)
        #expect(engine.cyclePosition == 1)
        #expect(engine.phase == .idle)
        #expect(history.all().isEmpty) // navigation records nothing

        engine.goToNextPhase() // Focus 2
        #expect(engine.kind == .focus && engine.cyclePosition == 2)

        engine.goToPreviousPhase() // back to Break 1
        #expect(engine.kind == .shortBreak && engine.cyclePosition == 1)

        engine.goToPreviousPhase()
        engine.goToPreviousPhase() // clamps at the first focus
        #expect(engine.cyclePosition == 0 && engine.kind == .focus)
    }

    @Test func manuallyScrubbingToTheLongBreakWorks() {
        let (engine, _, _) = makeEngine() // long break every 4 -> position 7
        for _ in 0..<7 { engine.goToNextPhase() }
        #expect(engine.kind == .longBreak)
    }

    private func longFocusEngine() -> (PomodoroEngine, InMemoryHistoryStore, TestClock) {
        let history = InMemoryHistoryStore()
        let clock = TestClock()
        let engine = PomodoroEngine(
            settingsStore: InMemorySettingsStore(settings: TimerSettings(focusDuration: 600)),
            history: history, clock: clock, tickInterval: 1
        )
        return (engine, history, clock)
    }

    @Test func abandoningFocusAfterThreeMinutesLogsRealFocusedTime() {
        let (engine, history, clock) = longFocusEngine()
        engine.start()
        clock.advance(by: 200) // focused 3m20s
        engine.reset()
        #expect(history.all().count == 1)
        #expect(history.all().first?.completed == true) // never "skipped"
        #expect(history.all().first?.plannedDuration == 200) // the REAL focused time
    }

    @Test func abandoningFocusUnderThreeMinutesLogsNothing() {
        let (engine, history, clock) = longFocusEngine()
        engine.start()
        clock.advance(by: 100)
        engine.goToNextPhase()
        #expect(history.all().isEmpty)
    }

    @Test func pauseAndResumePreserveRemaining() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.advance(by: 40)
        #expect(engine.remaining == 60)

        engine.pause()
        #expect(engine.phase == .paused)
        #expect(clock.isScheduled == false)

        clock.jump(by: 30) // time passes while paused; nothing should change
        #expect(engine.remaining == 60)

        engine.resume()
        #expect(engine.phase == .running)
        clock.advance(by: 10)
        #expect(engine.remaining == 50)
    }

    @Test func remainingTracksWallClockAcrossSuspension() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        // App suspended 60s with no ticks, then a single wake-up tick.
        clock.jump(by: 60)
        clock.fireTick()
        #expect(engine.remaining == 40)
    }

    @Test func completesIfSuspendedPastTheEnd() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        clock.jump(by: 500) // far past the 100s focus
        clock.fireTick()
        // Completion is detected and the engine advances to the next session,
        // which is presented ready at its full duration (short break = 20s).
        #expect(engine.kind == .shortBreak)
        #expect(engine.remaining == 20)
        #expect(history.all().count == 1)
        #expect(history.all().first?.completed == true)
    }

    @Test func refreshCompletesWhenElapsedWhileBackgrounded() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        clock.jump(by: 500)
        engine.refresh() // e.g. scenePhase becomes .active
        #expect(engine.kind == .shortBreak)
        #expect(history.all().first?.completed == true)
    }

    @Test func resetReturnsToIdleAtFullDuration() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.advance(by: 50)
        engine.reset()
        #expect(engine.phase == .idle)
        #expect(engine.remaining == 100)
        #expect(clock.isScheduled == false)
    }

    @Test func resetKeepsCyclePositionButRefillsTime() {
        let (engine, _, clock) = makeEngine()
        engine.goToNextPhase() // move to Break 1
        engine.start()
        clock.advance(by: 5)
        engine.reset()
        #expect(engine.cyclePosition == 1) // position preserved
        #expect(engine.kind == .shortBreak)
        #expect(engine.remaining == 20)
    }

    @Test func autoStartBreaksBeginsBreakImmediately() {
        var settings = TimerSettings(focusDuration: 100, shortBreakDuration: 20, longBreakDuration: 40, sessionsUntilLongBreak: 4)
        settings.autoStartBreaks = true
        let (engine, _, clock) = makeEngine(settings: settings)
        engine.start()
        clock.advance(by: 100) // focus completes
        #expect(engine.kind == .shortBreak)
        #expect(engine.phase == .running) // auto-started
        #expect(clock.isScheduled)
    }

    @Test func toggleDrivesTheFullLifecycle() {
        let (engine, _, clock) = makeEngine()
        engine.toggle() // idle -> running
        #expect(engine.phase == .running)
        clock.advance(by: 10)
        engine.toggle() // running -> paused
        #expect(engine.phase == .paused)
        engine.toggle() // paused -> running
        #expect(engine.phase == .running)
    }

    // MARK: Mirrored state from another device

    /// The regression: a peer pausing used to arrive as "not running, no end
    /// date" and wipe this device's session. The frozen remaining now survives.
    @Test func pausedRemoteStateIsAdoptedAsPausedWithItsFrozenRemaining() {
        let (engine, _, clock) = makeEngine()
        var started = 0, interrupted = 0, completed = 0
        engine.onSessionStarted = { _, _ in started += 1 }
        engine.onSessionInterrupted = { _ in interrupted += 1 }
        engine.onSessionCompleted = { _ in completed += 1 }

        // The peer froze 5s ago with 42s left; remaining is recoverable as
        // endDate - pausedAt, independent of when this device hears about it.
        let pausedAt = clock.now.addingTimeInterval(-5)
        engine.applyRemoteState(
            cyclePosition: 0,
            isRunning: false,
            endDate: pausedAt.addingTimeInterval(42),
            pausedAt: pausedAt
        )

        #expect(engine.phase == .paused)
        #expect(engine.remaining == 42) // NOT reset to the 100s planned duration
        #expect(clock.isScheduled == false)

        clock.jump(by: 30) // a paused session ignores the wall clock
        #expect(engine.remaining == 42)

        #expect(started == 0 && interrupted == 0 && completed == 0) // mirrors are silent
    }

    @Test func runningRemoteStateIsAdoptedAsRunning() {
        let (engine, _, clock) = makeEngine()
        engine.applyRemoteState(
            cyclePosition: 2,
            isRunning: true,
            endDate: clock.now.addingTimeInterval(55),
            pausedAt: nil
        )
        #expect(engine.cyclePosition == 2)
        #expect(engine.phase == .running)
        #expect(engine.remaining == 55)
        #expect(clock.isScheduled)

        clock.advance(by: 5)
        #expect(engine.remaining == 50)
    }

    @Test func idleRemoteStateResetsTheSession() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.advance(by: 40)
        engine.applyRemoteState(cyclePosition: 0, isRunning: false, endDate: nil, pausedAt: nil)
        #expect(engine.phase == .idle)
        #expect(engine.remaining == 100)
        #expect(clock.isScheduled == false)
    }

    /// A mirror that arrives after its own deadline is stale, not a countdown —
    /// and the session it describes completed out there, so the engine lands
    /// idle at the NEXT phase, not back at the one that already finished.
    @Test func remoteStateWithAnElapsedEndDateLandsIdleAtTheNextPhase() {
        let (engine, _, clock) = makeEngine()
        engine.applyRemoteState(
            cyclePosition: 0,
            isRunning: true,
            endDate: clock.now.addingTimeInterval(-5),
            pausedAt: nil
        )
        #expect(engine.phase == .idle)
        #expect(engine.cyclePosition == 1)
        #expect(engine.remaining == 20) // the short break that follows focus 0
        #expect(clock.isScheduled == false)
    }

    /// The whole point of the wire format: pause here, adopt there, resume there,
    /// and the countdown is the one the user actually left behind.
    @Test func pausingOnOneDeviceRoundTripsThroughAdoptionToTheSameRemaining() {
        let clock = TestClock()
        let store = InMemorySettingsStore(settings: TimerSettings(focusDuration: 100))
        let deviceA = PomodoroEngine(settingsStore: store, history: InMemoryHistoryStore(), clock: clock, tickInterval: 1)
        let deviceB = PomodoroEngine(settingsStore: store, history: InMemoryHistoryStore(), clock: clock, tickInterval: 1)

        deviceA.start()
        clock.advance(by: 40)
        deviceA.pause()
        #expect(deviceA.remaining == 60)

        // Exactly what the sync layer puts on the wire for a paused timer.
        let pausedAt = clock.now
        deviceB.applyRemoteState(
            cyclePosition: deviceA.cyclePosition,
            isRunning: false,
            endDate: pausedAt.addingTimeInterval(deviceA.remaining),
            pausedAt: pausedAt
        )
        #expect(deviceB.phase == .paused)
        #expect(deviceB.remaining == 60)

        deviceB.resume()
        #expect(deviceB.phase == .running)
        #expect(deviceB.remaining == 60)
        clock.advance(by: 10)
        #expect(deviceB.remaining == 50)
    }

    // MARK: Local change instants

    /// Last-writer-wins needs a stamp on every session the engine writes, from
    /// the injected clock so it stays deterministic.
    @Test func completedSessionsAreStampedWithTheChangeInstant() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        clock.advance(by: 100)
        #expect(history.all().first?.updatedAt == clock.now)
    }

    @Test func abandonedFocusIsStampedWithTheChangeInstant() {
        let (engine, history, clock) = longFocusEngine()
        engine.start()
        clock.advance(by: 200)
        engine.reset()
        #expect(history.all().first?.updatedAt == clock.now)
    }

    /// History files predate the stamp, so an absent key must not fail the load.
    @Test func focusSessionJSONWithoutUpdatedAtStillDecodes() throws {
        let json = #"""
        {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","kind":"focus","plannedDuration":1500,
         "startedAt":760000000,"endedAt":760001500,"completed":true}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FocusSession.self, from: json)
        #expect(decoded.updatedAt == nil)
        #expect(decoded.plannedDuration == 1500)
        #expect(decoded.completed)

        // And a stamped session round-trips.
        let stamped = FocusSession(
            kind: .focus, plannedDuration: 1500, startedAt: Date(),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reloaded = try JSONDecoder().decode(
            FocusSession.self, from: try JSONEncoder().encode(stamped)
        )
        #expect(reloaded.updatedAt == stamped.updatedAt)
    }

    // MARK: One session, one record
    //
    // Both devices reconstruct the countdown from the shared `endDate`, so both
    // reach zero — but the Pomodoro happened once. Every witness records it
    // under the id the live state carries, and the stores upsert by id, so the
    // copies collapse into a single row however many devices were watching.

    /// The id a peer's session travels under in these tests.
    private static let sharedSessionID = UUID()

    /// Adopts a peer's running session with `seconds` left to run.
    private func adoptRunning(_ engine: PomodoroEngine, clock: TestClock, seconds: TimeInterval) {
        engine.applyRemoteState(
            cyclePosition: 0,
            isRunning: true,
            endDate: clock.now.addingTimeInterval(seconds),
            pausedAt: nil,
            sessionID: Self.sharedSessionID
        )
    }

    @Test func aMirroredSessionRecordsUnderTheSharedID() {
        let (engine, history, clock) = makeEngine()
        adoptRunning(engine, clock: clock, seconds: 40)
        #expect(engine.isMirroring)

        var completions = 0
        engine.onSessionCompleted = { _ in completions += 1 }
        clock.advance(by: 41)

        #expect(engine.phase == .idle)
        // The mirror records too — under the id the live state carried, so the
        // origin device's copy upserts into the same row rather than a second
        // one. This is what lets a Pomodoro survive the origin being offline
        // at the moment it finishes.
        #expect(history.all().map(\.id) == [Self.sharedSessionID])
        #expect(completions == 1)
    }

    @Test func aLocallyStartedSessionStillRecords() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        #expect(engine.isMirroring == false)
        clock.advance(by: 101)
        #expect(history.all().count == 1)
    }

    /// Starting here claims the session back, so the record comes with it.
    @Test func startingLocallyAfterMirroringTakesOwnership() {
        let (engine, history, clock) = makeEngine()
        adoptRunning(engine, clock: clock, seconds: 40)
        #expect(engine.isMirroring)

        engine.reset()
        engine.start()
        #expect(engine.isMirroring == false)

        clock.advance(by: 101)
        #expect(history.all().count == 1)
    }

    @Test func adoptingAnIdlePeerClearsMirroring() {
        let (engine, _, clock) = makeEngine()
        adoptRunning(engine, clock: clock, seconds: 40)
        engine.applyRemoteState(cyclePosition: 0, isRunning: false, endDate: nil, pausedAt: nil)
        #expect(engine.isMirroring == false)
        #expect(engine.phase == .idle)
    }

    /// Abandoning from the mirror files the stretch under the shared id — the
    /// old owner-only rule silently discarded the focus when the person tapped
    /// reset on the device that didn't start the session. If the origin also
    /// records its own abandon, the shared id collapses the copies to one row.
    @Test func resettingAMirrorRecordsTheAbandonedFocusUnderTheSharedID() {
        let (engine, history, clock) = makeEngine(
            settings: TimerSettings(
                focusDuration: 600,
                shortBreakDuration: 20,
                longBreakDuration: 40,
                sessionsUntilLongBreak: 4
            )
        )
        adoptRunning(engine, clock: clock, seconds: 600)
        clock.jump(by: PomodoroEngine.minLoggedFocus + 20)

        engine.reset()

        #expect(history.all().map(\.id) == [Self.sharedSessionID])
        #expect(engine.isMirroring == false) // torn down, ownership open again
    }

    /// The tie-break that keeps a session from being recorded nowhere: an adopt
    /// never takes ownership away from a session this device started, so two
    /// devices auto-starting the same phase at once both keep their own.
    @Test func adoptingDoesNotDisownASessionStartedHere() {
        let (engine, history, clock) = makeEngine()
        engine.start()
        // The peer's equivalent session arrives a moment later.
        adoptRunning(engine, clock: clock, seconds: 99)

        #expect(engine.isMirroring == false)
        clock.advance(by: 100)
        #expect(history.all().count == 1)
    }

    @Test func adoptingAPausedPeerMirrorsToo() {
        let (engine, _, clock) = makeEngine()
        let pausedAt = clock.now.addingTimeInterval(-5)
        engine.applyRemoteState(
            cyclePosition: 0,
            isRunning: false,
            endDate: pausedAt.addingTimeInterval(42),
            pausedAt: pausedAt
        )
        #expect(engine.phase == .paused)
        #expect(engine.isMirroring)
    }

    // MARK: The state listeners actually see
    //
    // `onSessionInterrupted` drives the sync layer, which snapshots the engine
    // to build the row it mirrors. What matters is therefore not the state after
    // the call returns but the state *at the instant the callback runs* — so
    // these capture inside the closure and assert on what it saw. Announcing
    // mid-teardown published the dying session as though it were still alive,
    // and the peer went on counting it down.

    /// What the interruption callback observed.
    private struct Snapshot {
        var phase: PomodoroEngine.Phase
        var remaining: TimeInterval
        var cyclePosition: Int
        var kind: SessionKind
    }

    private func captureInterruption(
        of engine: PomodoroEngine,
        during body: () -> Void
    ) -> Snapshot? {
        var seen: Snapshot?
        engine.onSessionInterrupted = { ended in
            guard ended else { return } // a pause is not a teardown
            seen = Snapshot(
                phase: engine.phase,
                remaining: engine.remaining,
                cyclePosition: engine.cyclePosition,
                kind: engine.kind
            )
        }
        body()
        engine.onSessionInterrupted = nil
        return seen
    }

    @Test func resetWhileRunningAnnouncesAnAlreadyIdleEngine() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.jump(by: 30)

        let seen = captureInterruption(of: engine) { engine.reset() }

        // Seeing `.running` here is the defect: the mirrored row carried a live
        // end_date and the other device counted it down to a session that never
        // happened.
        #expect(seen?.phase == .idle)
        #expect(seen?.remaining == 100)
    }

    @Test func resetWhilePausedAnnouncesAnAlreadyIdleEngine() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.jump(by: 30)
        engine.pause()

        let seen = captureInterruption(of: engine) { engine.reset() }

        // Seeing `.paused` here is the defect: the row carried a paused_at the
        // peer adopted as a live pause it could never leave.
        #expect(seen?.phase == .idle)
        #expect(seen?.remaining == 100)
    }

    @Test func skippingForwardAnnouncesTheSettledPositionAndKind() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.jump(by: 10)

        let seen = captureInterruption(of: engine) { engine.goToNextPhase() }

        // The position must already have moved, or the peer lands a phase behind.
        #expect(seen?.phase == .idle)
        #expect(seen?.cyclePosition == 1)
        #expect(seen?.kind == .shortBreak)
        #expect(seen?.remaining == 20)
    }

    @Test func skippingBackwardAnnouncesTheSettledPosition() {
        let (engine, _, _) = makeEngine()
        engine.goToNextPhase() // idle scrub, nothing to interrupt
        engine.start()

        let seen = captureInterruption(of: engine) { engine.goToPreviousPhase() }

        #expect(seen?.phase == .idle)
        #expect(seen?.cyclePosition == 0)
        #expect(seen?.kind == .focus)
    }

    /// Scrubbing an idle engine tears nothing down, so it must stay silent.
    @Test func scrubbingWhileIdleAnnouncesNothing() {
        let (engine, _, _) = makeEngine()
        let seen = captureInterruption(of: engine) { engine.goToNextPhase() }
        #expect(seen == nil)
    }

    /// A pause still reports `false` — resumable, not abandoned — and is the one
    /// case that legitimately announces a non-idle phase.
    @Test func pauseStillAnnouncesAResumablePause() {
        let (engine, _, clock) = makeEngine()
        engine.start()
        clock.jump(by: 25)

        var endedFlags: [Bool] = []
        var phaseWhenSeen: PomodoroEngine.Phase?
        engine.onSessionInterrupted = { ended in
            endedFlags.append(ended)
            phaseWhenSeen = engine.phase
        }
        engine.pause()

        #expect(endedFlags == [false])
        #expect(phaseWhenSeen == .paused)
        #expect(engine.remaining == 75)
    }

    /// The teardown still logs a long-enough abandoned focus — the reordering
    /// must not cost us the recording.
    @Test func resetStillRecordsASubstantialAbandonedFocus() {
        // Long enough that the abandoned stretch can clear `minLoggedFocus`,
        // which is measured against the planned duration.
        let (engine, history, clock) = makeEngine(
            settings: TimerSettings(
                focusDuration: 600,
                shortBreakDuration: 20,
                longBreakDuration: 40,
                sessionsUntilLongBreak: 4
            )
        )
        engine.start()
        clock.jump(by: PomodoroEngine.minLoggedFocus + 20)

        let seen = captureInterruption(of: engine) { engine.reset() }

        #expect(seen?.phase == .idle)
        #expect(history.all().count == 1)
        #expect(history.all().first?.plannedDuration == PomodoroEngine.minLoggedFocus + 20)
    }
}
