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
}
