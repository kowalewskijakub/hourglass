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
    let workdayStore: FileWorkdayStore
    let engine: PomodoroEngine
    let workday: WorkdayTracker

    @ObservationIgnored private let calendar: Calendar = .current

    init() {
        let settings = UserDefaultsSettingsStore()
        let history = FileHistoryStore()
        let workdays = FileWorkdayStore()
        self.settingsStore = settings
        self.historyStore = history
        self.workdayStore = workdays
        self.engine = PomodoroEngine(settingsStore: settings, history: history, clock: SystemClock())
        self.workday = WorkdayTracker(store: workdays)
        installEngineHooks()
    }

    // MARK: - Engine callbacks
    //
    // AppModel owns the engine's callback slots (there is one of each) so shared
    // behaviour like auto clock-in always runs; platform layers attach their own
    // behaviour to these forwarding hooks instead of the engine directly.

    var onSessionStarted: (@MainActor (_ kind: SessionKind, _ secondsRemaining: TimeInterval) -> Void)?
    var onSessionInterrupted: (@MainActor (_ ended: Bool) -> Void)?
    var onSessionCompleted: (@MainActor (FocusSession) -> Void)?

    /// Cross-device sync, attached by the app at launch (nil until then).
    @ObservationIgnored weak var sync: SyncService?

    /// Fires whenever the workday changes — locally or from another device — so
    /// hosts can refresh things like the Live Activity.
    var onWorkdayChanged: (@MainActor () -> Void)?

    private func installEngineHooks() {
        // Any clock-in/out, break or manual edit mirrors to the other devices.
        workday.onSessionChanged = { [weak self] session in
            guard let self else { return }
            sync?.pushClockSession(session)
            onWorkdayChanged?()
        }
        workday.onSessionDeleted = { [weak self] id in
            guard let self else { return }
            sync?.deleteClockSession(id: id)
            onWorkdayChanged?()
        }

        engine.onSessionStarted = { [weak self] kind, secondsRemaining in
            guard let self else { return }
            // Starting a focus session implies you're working: clock in.
            if kind == .focus { workday.clockIn() }
            // Starting any timer means you're back at it, so close a running
            // coffee break — leaving it open would keep charging break time
            // against the session you're actually working through. No-op when
            // there isn't one.
            workday.endBreak()
            sync?.pushLiveState()
            onSessionStarted?(kind, secondsRemaining)
        }
        engine.onSessionInterrupted = { [weak self] ended in
            guard let self else { return }
            sync?.pushLiveState()
            onSessionInterrupted?(ended)
        }
        engine.onSessionCompleted = { [weak self] session in
            guard let self else { return }
            sync?.pushSession(session)
            sync?.pushLiveState()
            onSessionCompleted?(session)
        }
    }

    /// Bindable settings that persist on every change (and sync to other devices).
    var settings: TimerSettings {
        get { settingsStore.settings }
        set {
            guard newValue != settingsStore.settings else { return }
            settingsStore.settings = newValue
            sync?.pushSettings()
        }
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

    // MARK: - Workday statistics

    func clockInsToday(now: Date = Date()) -> Int {
        calculator.clockInCount(in: workday.sessions(), on: now)
    }

    func netWorkedToday(now: Date = Date()) -> TimeInterval {
        calculator.netWorkedTime(in: workday.sessions(), on: now, asOf: now)
    }

    func breakTimeToday(now: Date = Date()) -> TimeInterval {
        calculator.breakTime(in: workday.sessions(), on: now, asOf: now)
    }

    // MARK: - Log (unified, editable timeline)

    /// Every recorded item — Pomodoro sessions, clock-in/out stretches and
    /// non-Pomodoro breaks — newest first.
    var logItems: [LogItem] {
        var items: [LogItem] = historyStore.all()
            .filter { $0.completed }
            .map { .session($0) }

        for clockSession in workday.sessions() {
            items.append(.clock(clockSession))
            for workBreak in clockSession.breaks {
                items.append(.workBreak(sessionID: clockSession.id, entry: workBreak))
            }
        }
        return items.sorted { $0.startedAt > $1.startedAt }
    }

    /// Log items grouped into days, newest day first.
    var logDays: [LogDay] {
        let groups = Dictionary(grouping: logItems) { calendar.startOfDay(for: $0.startedAt) }
        return groups
            .map { LogDay(date: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.date > $1.date }
    }

    /// The log as workdays with the focus sessions and breaks that happened
    /// inside them nested underneath, newest day first. Anything recorded while
    /// clocked out is collected in a trailing "unassigned" group.
    var logWorkdays: [LogWorkday] {
        let sessions = historyStore.all().filter(\.completed)
        var claimed = Set<FocusSession.ID>()

        let workdays: [LogWorkday] = workday.sessions()
            .sorted { $0.clockedInAt > $1.clockedInAt }
            .map { clockSession in
                let end = clockSession.clockedOutAt ?? Date.distantFuture
                let inside = sessions.filter { session in
                    session.startedAt >= clockSession.clockedInAt && session.startedAt <= end
                }
                inside.forEach { claimed.insert($0.id) }

                var children: [LogItem] = inside.map { .session($0) }
                children += clockSession.breaks.map {
                    .workBreak(sessionID: clockSession.id, entry: $0)
                }
                return LogWorkday(
                    clockSession: clockSession,
                    children: children.sorted { $0.startedAt > $1.startedAt }
                )
            }

        let orphans = sessions
            .filter { !claimed.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
            .map { LogItem.session($0) }

        return workdays + (orphans.isEmpty ? [] : [LogWorkday(clockSession: nil, children: orphans)])
    }

    /// The whole log as CSV, for export.
    func exportCSV() -> String {
        var lines = ["type,start,end,duration_minutes"]
        let formatter = ISO8601DateFormatter()
        for item in logItems.sorted(by: { $0.startedAt < $1.startedAt }) {
            let minutes = String(format: "%.1f", item.duration / 60)
            let start = formatter.string(from: item.startedAt)
            let end = formatter.string(from: item.startedAt.addingTimeInterval(item.duration))
            lines.append("\(item.exportKind),\(start),\(end),\(minutes)")
        }
        return lines.joined(separator: "\n")
    }

    func addSession(_ session: FocusSession) { historyStore.add(session) }
    func updateSession(_ session: FocusSession) { historyStore.update(session) }
    func deleteSession(id: FocusSession.ID) { historyStore.delete(id: id) }
    func clearHistory() {
        historyStore.clear()
        workdayStore.clear()
    }

    // MARK: Editing clock sessions / breaks from the log

    /// Applies only the fields the workday editor owns, merged onto the freshly
    /// stored record — so break edits made while the sheet was open aren't
    /// clobbered by the sheet's stale copy.
    func updateClockSession(_ session: ClockSession) {
        guard var stored = workday.sessions().first(where: { $0.id == session.id }) else {
            workday.update(session)
            return
        }
        stored.clockedInAt = session.clockedInAt
        stored.clockedOutAt = session.clockedOutAt
        workday.update(stored)
    }
    func deleteClockSession(id: ClockSession.ID) { workday.delete(id: id) }

    func updateBreak(sessionID: ClockSession.ID, entry: WorkBreak) {
        guard var session = workday.sessions().first(where: { $0.id == sessionID }),
              let index = session.breaks.firstIndex(where: { $0.id == entry.id }) else { return }
        session.breaks[index] = entry
        workday.update(session)
    }

    func deleteBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID) {
        guard var session = workday.sessions().first(where: { $0.id == sessionID }) else { return }
        session.breaks.removeAll { $0.id == entryID }
        workday.update(session)
    }
}

/// One day's worth of log items.
struct LogDay: Identifiable {
    let date: Date
    let items: [LogItem]
    var id: Date { date }
}

/// A workday and everything recorded inside it. `clockSession` is nil for the
/// trailing group of items recorded while clocked out.
struct LogWorkday: Identifiable {
    let clockSession: ClockSession?
    let children: [LogItem]
    var id: UUID { clockSession?.id ?? UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")! }
}

/// A single row in the unified log — a Pomodoro session, a clocked-in stretch,
/// or a non-Pomodoro break.
enum LogItem: Identifiable {
    case session(FocusSession)
    case clock(ClockSession)
    case workBreak(sessionID: ClockSession.ID, entry: WorkBreak)

    var id: UUID {
        switch self {
        case .session(let s): return s.id
        case .clock(let c): return c.id
        case .workBreak(_, let b): return b.id
        }
    }

    var startedAt: Date {
        switch self {
        case .session(let s): return s.startedAt
        case .clock(let c): return c.clockedInAt
        case .workBreak(_, let b): return b.startedAt
        }
    }

    var duration: TimeInterval {
        switch self {
        case .session(let s): return s.plannedDuration
        case .clock(let c): return c.grossDuration()
        case .workBreak(_, let b): return b.duration()
        }
    }

    /// Stable label used in the CSV export.
    var exportKind: String {
        switch self {
        case .session(let s): return s.kind.rawValue
        case .clock: return "workday"
        case .workBreak: return "break"
        }
    }
}
