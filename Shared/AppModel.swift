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
    let workday: WorkdayTracker
    /// One stamp order for the whole device: every `updatedAt` the engine, the
    /// tracker, the log editors or the sync layer issue comes from here, so
    /// last-writer-wins compares one consistent sequence — and never falls
    /// behind a stamp already seen from the server (see `HybridStampClock`).
    @ObservationIgnored let stamps: HybridStampClock

    @ObservationIgnored private let calendar: Calendar = .current

    init() {
        let settings = UserDefaultsSettingsStore()
        let history = FileHistoryStore()
        let workdays = FileWorkdayStore()
        let stamps = HybridStampClock(defaults: .standard, key: "hourglass.stampClock")
        self.settingsStore = settings
        self.historyStore = history
        self.stamps = stamps
        self.engine = PomodoroEngine(settingsStore: settings, history: history, clock: SystemClock(), stamps: stamps)
        self.workday = WorkdayTracker(store: workdays, stamps: stamps)
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
        workday.onBreakDeleted = { [weak self] sessionID, entryID in
            guard let self else { return }
            sync?.deleteBreak(sessionID: sessionID, entryID: entryID)
            onWorkdayChanged?()
        }

        engine.onSessionStarted = { [weak self] kind, secondsRemaining in
            guard let self else { return }
            workday.sessionStarted(kind: kind)
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
            // Both devices run the countdown, so both arrive here, and both
            // push — under the session id the live state carried, so the
            // copies upsert into one row instead of landing twice. (The old
            // owner-only rule broke under auto-start and lost the record
            // entirely when the owner happened to be offline.)
            sync?.pushSession(session)
            // A completion noticed long after the fact — the app slept past
            // the deadline — mirrors with its stamp anchored at the actual
            // end, so it cannot bury what other devices have done since.
            let lateBy = session.endedAt.map { Date().timeIntervalSince($0) } ?? 0
            if lateBy > 60, let ended = session.endedAt {
                sync?.pushLiveState(asOf: ended)
            } else {
                sync?.pushLiveState()
            }
            onSessionCompleted?(session)
        }
    }

    /// Adopts timer state arriving from another device, then mirrors the side
    /// effects a local action would have had onto the host hooks: schedule the
    /// completion alert, keep the Live Activity truthful. Without this a
    /// mirrored Pomodoro was invisible and silent the moment the app
    /// backgrounded — nothing had scheduled its alert.
    func applyRemoteTimer(
        cyclePosition: Int,
        isRunning: Bool,
        endDate: Date?,
        pausedAt: Date?,
        sessionID: UUID?
    ) {
        let adoption = engine.applyRemoteState(
            cyclePosition: cyclePosition,
            isRunning: isRunning,
            endDate: endDate,
            pausedAt: pausedAt,
            sessionID: sessionID
        )
        switch adoption {
        case .startedRunning(let kind, let remaining):
            onSessionStarted?(kind, remaining)
        case .paused:
            onSessionInterrupted?(false)
        case .stopped:
            onSessionInterrupted?(true)
        case .unchanged:
            break
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

    /// Worked vs focused minutes per day, for the stacked bar chart.
    func dailyWorkStats(lastDays days: Int = 7, now: Date = Date()) -> [StatisticsCalculator.DailyWorkStat] {
        calculator.dailyWorkStats(
            clockSessions: workday.sessions(),
            focusSessions: sessions,
            lastDays: days,
            endingOn: now
        )
    }

    /// First clock-in / last clock-out per day, for the day-shape chart.
    func dailyClockSpans(lastDays days: Int = 7, now: Date = Date()) -> [StatisticsCalculator.DailyClockSpan] {
        calculator.dailyClockSpans(in: workday.sessions(), lastDays: days, endingOn: now)
    }

    // MARK: - Workday statistics

    func netWorkedToday(now: Date = Date()) -> TimeInterval {
        calculator.netWorkedTime(in: workday.sessions(), on: now, asOf: now)
    }

    // MARK: - Log (unified, editable timeline)

    /// The derived log: workdays with what happened inside them, plus the flat
    /// timeline the CSV export walks. Rebuilt on read, so it always reflects the
    /// stores as they are now.
    var log: WorkdayLog {
        WorkdayLog(clockSessions: workday.sessions(), focusSessions: historyStore.all())
    }

    // Editing focus sessions from the log. The store is only half of it: an edit
    // that never reached the sync layer was silently reverted by the next pull,
    // which re-applied the server's untouched copy. Each edit is stamped as it
    // is written, because that stamp is the whole of how the other device — and
    // this one, on its next connect — tells our copy from an older one.

    func addSession(_ session: FocusSession) {
        var session = session
        session.updatedAt = stamps.next()
        historyStore.add(session)
        sync?.pushSession(session)
    }

    func updateSession(_ session: FocusSession) {
        var session = session
        session.updatedAt = stamps.next()
        historyStore.update(session)
        sync?.pushSession(session)
    }

    func deleteSession(id: FocusSession.ID) {
        historyStore.delete(id: id)
        sync?.deleteSession(id: id)
    }

    // MARK: Editing clock sessions / breaks from the log
    //
    // Straight forwards: the tracker owns the stored session, so it is the one
    // that re-reads it and decides what an edit may touch.

    func updateClockSession(id: ClockSession.ID, clockedInAt: Date, clockedOutAt: Date?) {
        workday.updateClockSession(id: id, clockedInAt: clockedInAt, clockedOutAt: clockedOutAt)
    }
    func deleteClockSession(id: ClockSession.ID) { workday.delete(id: id) }

    func updateBreak(sessionID: ClockSession.ID, entry: WorkBreak) {
        workday.updateBreak(sessionID: sessionID, entry: entry)
    }

    func deleteBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID) {
        workday.deleteBreak(sessionID: sessionID, entryID: entryID)
    }
}
