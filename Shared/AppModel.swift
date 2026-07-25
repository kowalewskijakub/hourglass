import Foundation
import Observation
import HourglassCore

/// The app-wide, cross-platform source of truth. Owns the persisted stores and
/// the Pomodoro engine, and exposes the statistics the UI needs. Platform layers
/// (menu bar on macOS, tabs on iOS) wire their own notification/sound behaviour
/// onto `engine`'s callbacks.
@MainActor
@Observable
final class AppModel {
    let settingsStore: UserDefaultsSettingsStore
    let historyStore: FileHistoryStore
    let engine: PomodoroEngine

    @ObservationIgnored private let calendar: Calendar = .current

    init() {
        let settings = UserDefaultsSettingsStore()
        let history = FileHistoryStore()
        self.settingsStore = settings
        self.historyStore = history
        self.engine = PomodoroEngine(settingsStore: settings, history: history, clock: SystemClock())
    }

    /// Bindable settings that persist on every change.
    var settings: TimerSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    // MARK: - Statistics (recomputed live as history changes)

    private var calculator: StatisticsCalculator { StatisticsCalculator(calendar: calendar) }
    private var sessions: [FocusSession] { historyStore.all() }

    func focusMinutesToday(now: Date = Date()) -> Int {
        Int(calculator.totalFocusTime(in: sessions, on: now) / 60)
    }

    func completedToday(now: Date = Date()) -> Int {
        calculator.completedCount(in: sessions, on: now)
    }

    func currentStreak(now: Date = Date()) -> Int {
        calculator.currentStreak(in: sessions, asOf: now)
    }

    func totalCompleted() -> Int {
        calculator.totalCompletedAllTime(in: sessions)
    }

    func dailyStats(lastDays days: Int = 7, now: Date = Date()) -> [DailyStat] {
        calculator.dailyStats(in: sessions, lastDays: days, endingOn: now)
    }

    // MARK: - History log (full edit)

    /// Recorded sessions, newest first. Only real (completed) sessions — skips are
    /// never registered.
    var logEntries: [FocusSession] {
        historyStore.all()
            .filter { $0.completed }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func addSession(_ session: FocusSession) { historyStore.add(session) }
    func updateSession(_ session: FocusSession) { historyStore.update(session) }
    func deleteSession(id: FocusSession.ID) { historyStore.delete(id: id) }
    func clearHistory() { historyStore.clear() }
}
