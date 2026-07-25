import Foundation
import HourglassCore

// A dependency-free smoke test for HourglassCore that runs with only the
// Command Line Tools (`swift run hourglass-selfcheck`). The exhaustive suite
// lives in Tests/ and runs under full Xcode. Top-level code in main.swift is
// @MainActor-isolated, so we can touch the @MainActor engine directly.

// MARK: - Tiny assertion harness

var failures = 0
var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ FAILED: \(message)")
    }
}

@MainActor
func section(_ title: String) { print("\n▸ \(title)") }

// MARK: - A manual clock (mirrors the test double)

@MainActor
final class ManualClock: PomodoroClock {
    private var current: Date
    private var handler: (@MainActor () -> Void)?
    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = now }
    var now: Date { current }
    func schedule(every interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }
    func cancel() { handler = nil }
    var isScheduled: Bool { handler != nil }
    func advance(by s: TimeInterval) { current = current.addingTimeInterval(s); handler?() }
    func jump(by s: TimeInterval) { current = current.addingTimeInterval(s) }
    func fireTick() { handler?() }
}

@MainActor
func makeEngine(
    _ settings: TimerSettings = TimerSettings(focusDuration: 100, shortBreakDuration: 20, longBreakDuration: 40, sessionsUntilLongBreak: 4)
) -> (PomodoroEngine, InMemoryHistoryStore, ManualClock) {
    let history = InMemoryHistoryStore()
    let clock = ManualClock()
    let engine = PomodoroEngine(
        settingsStore: InMemorySettingsStore(settings: settings),
        history: history,
        clock: clock,
        tickInterval: 1
    )
    return (engine, history, clock)
}

// MARK: - Engine

section("PomodoroEngine")
do {
    let (engine, _, _) = makeEngine()
    check(engine.kind == .focus && engine.phase == .idle && engine.remaining == 100,
          "starts idle at focus duration")
}
do {
    let (engine, _, clock) = makeEngine()
    engine.start()
    clock.advance(by: 30)
    check(engine.phase == .running && engine.remaining == 70, "counts down against the clock")
    check(abs(engine.progress - 0.3) < 0.0001, "progress reflects elapsed fraction")
}
do {
    let (engine, history, clock) = makeEngine()
    engine.start()
    clock.advance(by: 100)
    check(engine.kind == .shortBreak && engine.cyclePosition == 1, "focus -> short break, position advances")
    check(history.all().count == 1 && history.all().first?.completed == true, "completed focus recorded")
}
do {
    let (engine, _, clock) = makeEngine()
    for i in 1...4 {
        engine.start(); clock.advance(by: 100)              // complete focus
        if i < 4 { engine.start(); clock.advance(by: 20) }  // complete short break
    }
    check(engine.kind == .longBreak && engine.cyclePosition == 7, "long break after 4 focus sessions")
}
do {
    // Free bidirectional navigation through the cycle.
    let (engine, _, _) = makeEngine()
    engine.goToNextPhase(); engine.goToNextPhase()  // -> Focus 2
    check(engine.kind == .focus && engine.cyclePosition == 2, "forward scrub to focus 2")
    engine.goToPreviousPhase()                      // -> Break 1
    check(engine.kind == .shortBreak && engine.cyclePosition == 1, "backward scrub to break 1")
    engine.goToPreviousPhase(); engine.goToPreviousPhase()
    check(engine.cyclePosition == 0, "previous clamps at the first focus")
}
do {
    let (engine, _, clock) = makeEngine()
    engine.start(); clock.advance(by: 40)
    engine.pause()
    clock.jump(by: 30) // time passes while paused
    check(engine.phase == .paused && engine.remaining == 60, "pause freezes remaining")
    engine.resume(); clock.advance(by: 10)
    check(engine.remaining == 50, "resume continues from where it left off")
}
do {
    let (engine, _, clock) = makeEngine()
    engine.start()
    clock.jump(by: 60); clock.fireTick() // suspended, then a wake tick
    check(engine.remaining == 40, "remaining tracks wall clock across suspension")
}
do {
    let (engine, history, clock) = makeEngine()
    engine.start()
    clock.jump(by: 500)
    engine.refresh()
    check(engine.kind == .shortBreak && history.all().first?.completed == true,
          "refresh completes a session that elapsed while backgrounded")
}
do {
    let (engine, history, clock) = makeEngine()
    engine.start(); clock.advance(by: 10)
    engine.goToNextPhase()
    check(engine.kind == .shortBreak && engine.cyclePosition == 1, "next phase goes to short break")
    check(history.all().isEmpty, "short abandon (<3min) records nothing (no 'skipped')")
}
do {
    let history = InMemoryHistoryStore()
    let clock = ManualClock()
    let engine = PomodoroEngine(
        settingsStore: InMemorySettingsStore(settings: TimerSettings(focusDuration: 600)),
        history: history, clock: clock, tickInterval: 1
    )
    engine.start(); clock.advance(by: 200) // focused 3m20s
    engine.goToNextPhase()
    check(history.all().count == 1 && history.all().first?.completed == true, "abandoned focus >=3min is recorded")
    check(Int(history.all().first?.plannedDuration ?? 0) == 200, "records the REAL focused time")
}

// MARK: - Statistics

section("StatisticsCalculator")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let calc = StatisticsCalculator(calendar: cal)
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    func focus(_ date: Date, completed: Bool = true) -> FocusSession {
        FocusSession(kind: .focus, plannedDuration: 25 * 60, startedAt: date, endedAt: date, completed: completed)
    }
    let sessions = [focus(day(2026, 3, 10)), focus(day(2026, 3, 10)), focus(day(2026, 3, 9)), focus(day(2026, 3, 8)), focus(day(2026, 3, 5))]
    check(calc.totalFocusTime(in: sessions, on: day(2026, 3, 10)) == 50 * 60, "daily total sums completed focus")
    check(calc.currentStreak(in: sessions, asOf: day(2026, 3, 10)) == 3, "streak counts consecutive days")
    let stats = calc.dailyStats(in: sessions, lastDays: 7, endingOn: day(2026, 3, 10))
    check(stats.count == 7 && stats.last?.completedSessions == 2, "daily stats span the range, newest last")
    check(calc.currentStreak(in: [focus(day(2026, 3, 8))], asOf: day(2026, 3, 10)) == 0, "stale streak is zero")
}

// MARK: - Persistence

section("Persistence")
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hg-selfcheck-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = FileHistoryStore(fileURL: url)
    var session = FocusSession(kind: .focus, plannedDuration: 1500, startedAt: Date(), endedAt: Date(), completed: true)
    store.add(session)
    let reloaded = FileHistoryStore(fileURL: url)
    check(reloaded.all().count == 1, "history persists to file and reloads")

    // Full-edit CRUD on the log.
    session.plannedDuration = 600
    reloaded.update(session)
    check(FileHistoryStore(fileURL: url).all().first?.plannedDuration == 600, "history update persists")
    reloaded.delete(id: session.id)
    check(FileHistoryStore(fileURL: url).all().isEmpty, "history delete persists")

    let suite = UserDefaults(suiteName: "hourglass.selfcheck.\(UUID().uuidString)")!
    let s = UserDefaultsSettingsStore(defaults: suite, key: "s")
    var updated = s.settings; updated.focusDuration = 1234; s.settings = updated
    check(UserDefaultsSettingsStore(defaults: suite, key: "s").settings.focusDuration == 1234, "settings persist through UserDefaults")
}

// MARK: - Formatting

section("TimeFormatting")
do {
    check(TimeFormatting.clock(1500) == "25:00", "1500s -> 25:00")
    check(TimeFormatting.clock(0.2) == "00:01", "rounds up partial second")
    check(TimeFormatting.clock(-5) == "00:00", "clamps negatives")
    check(TimeFormatting.humanDuration(90 * 60) == "1h 30m", "human duration reads naturally")
}

// MARK: - Summary

print("\n" + String(repeating: "─", count: 40))
if failures == 0 {
    print("✅ All \(checks) checks passed.")
    exit(0)
} else {
    print("❌ \(failures) of \(checks) checks failed.")
    exit(1)
}
