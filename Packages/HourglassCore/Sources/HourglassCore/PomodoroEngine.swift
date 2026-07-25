import Foundation
import Observation

/// The Pomodoro state machine. Observable so SwiftUI views update as it ticks.
///
/// Time is driven entirely by an injected ``PomodoroClock``. Remaining time is
/// always computed as `endDate - now`, never accumulated, so the countdown stays
/// accurate across pauses, missed ticks, and app suspension/backgrounding.
///
/// The session sequence is modelled as a **cycle position** — a 0-based index
/// into the repeating pattern `Focus, Break, Focus, Break, …, LongBreak`. The
/// user can scrub freely forward/backward through it with ``goToNextPhase()`` /
/// ``goToPreviousPhase()``; completing a session simply advances the position.
@MainActor
@Observable
public final class PomodoroEngine {

    public enum Phase: Sendable, Equatable {
        case idle       // stopped at the start of the current phase
        case running
        case paused
    }

    // MARK: Observable state

    /// Position in the repeating Pomodoro cycle (0 = first focus).
    public private(set) var cyclePosition: Int = 0
    public private(set) var phase: Phase = .idle
    /// Seconds remaining in the current session.
    public private(set) var remaining: TimeInterval

    // MARK: Dependencies

    private let settingsStore: any SettingsStoring
    private let history: any HistoryStoring
    private let clock: any PomodoroClock
    private let tickInterval: TimeInterval

    /// Called on the main actor whenever a session runs to completion.
    public var onSessionCompleted: (@MainActor (FocusSession) -> Void)?

    /// Called when a run begins or resumes, with the session kind and the number
    /// of seconds remaining. iOS uses this to schedule a look-ahead local
    /// notification and start/update a Live Activity.
    public var onSessionStarted: (@MainActor (_ kind: SessionKind, _ secondsRemaining: TimeInterval) -> Void)?

    /// Called when a running session is stopped before completing. `ended` is
    /// `false` for a pause (the session is frozen and can resume) and `true` when
    /// the session is abandoned (reset or scrubbed away). iOS uses this to cancel
    /// a pending notification and to pause vs. end the Live Activity.
    public var onSessionInterrupted: (@MainActor (_ ended: Bool) -> Void)?

    // MARK: Internal timekeeping

    private var endDate: Date?
    private var currentSessionStart: Date?

    public init(
        settingsStore: any SettingsStoring,
        history: any HistoryStoring,
        clock: any PomodoroClock = SystemClock(),
        tickInterval: TimeInterval = 0.25
    ) {
        self.settingsStore = settingsStore
        self.history = history
        self.clock = clock
        self.tickInterval = tickInterval
        self.remaining = settingsStore.settings.duration(for: .focus)
    }

    // MARK: Derived values

    public var settings: TimerSettings { settingsStore.settings }

    /// The kind of the current session, derived from the cycle position.
    public var kind: SessionKind {
        Self.kind(at: cyclePosition, sessionsUntilLongBreak: settings.sessionsUntilLongBreak)
    }

    /// Planned length of the current session kind.
    public var plannedDuration: TimeInterval { settings.duration(for: kind) }

    /// Fraction elapsed, 0...1 (useful for progress rings).
    public var progress: Double {
        let planned = plannedDuration
        guard planned > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / planned))
    }

    public var isRunning: Bool { phase == .running }

    /// mm:ss string for the remaining time.
    public var formattedRemaining: String { TimeFormatting.clock(remaining) }

    /// How many focus sessions have been passed within the current cycle (for the
    /// progress dots). 0 while on the first focus, `N` on the long break.
    public var focusesCompletedInCycle: Int {
        (positionInCycle + 1) / 2
    }

    private var positionInCycle: Int {
        let period = 2 * max(1, settings.sessionsUntilLongBreak)
        return ((cyclePosition % period) + period) % period
    }

    /// Pure mapping from a cycle position to its session kind.
    public static func kind(at position: Int, sessionsUntilLongBreak: Int) -> SessionKind {
        let n = max(1, sessionsUntilLongBreak)
        let period = 2 * n
        let p = ((position % period) + period) % period
        if p % 2 == 0 { return .focus }
        return (p == period - 1) ? .longBreak : .shortBreak
    }

    // MARK: Intent

    /// Start/pause/resume depending on current phase (the primary button action).
    public func toggle() {
        switch phase {
        case .running: pause()
        case .paused: resume()
        case .idle: start()
        }
    }

    /// Begin the current session from full duration.
    public func start() {
        guard phase != .running else { return }
        remaining = plannedDuration
        let now = clock.now
        endDate = now.addingTimeInterval(remaining)
        currentSessionStart = now
        phase = .running
        scheduleTicks()
        onSessionStarted?(kind, remaining)
    }

    public func pause() {
        guard phase == .running else { return }
        recomputeRemaining()
        clock.cancel()
        phase = .paused
        onSessionInterrupted?(false) // paused, can resume
    }

    public func resume() {
        guard phase == .paused else { return }
        endDate = clock.now.addingTimeInterval(remaining)
        phase = .running
        scheduleTicks()
        onSessionStarted?(kind, remaining)
    }

    /// Stop and return to the start of the current session kind (position unchanged).
    public func reset() {
        stopTimekeeping()
        phase = .idle
        remaining = plannedDuration
    }

    /// Scrub forward to the next phase in the cycle.
    public func goToNextPhase() { move(to: cyclePosition + 1) }

    /// Scrub backward to the previous phase (clamped at the first focus).
    public func goToPreviousPhase() { move(to: cyclePosition - 1) }

    /// Adopt timer state mirrored from another device.
    ///
    /// The countdown is reconstructed locally from `endDate`, so the two devices
    /// agree without streaming ticks. Callbacks are intentionally *not* fired —
    /// this is a mirror of a decision made elsewhere, not a new local action.
    public func applyRemoteState(cyclePosition: Int, isRunning: Bool, endDate: Date?) {
        clock.cancel()
        self.cyclePosition = max(0, cyclePosition)

        if isRunning, let endDate {
            let remaining = max(0, endDate.timeIntervalSince(clock.now))
            guard remaining > 0 else {
                self.endDate = nil
                phase = .idle
                self.remaining = plannedDuration
                return
            }
            self.endDate = endDate
            self.remaining = remaining
            if currentSessionStart == nil { currentSessionStart = clock.now }
            phase = .running
            scheduleTicks()
        } else {
            self.endDate = nil
            currentSessionStart = nil
            phase = .idle
            remaining = plannedDuration
        }
    }

    /// Recompute against the wall clock — call when returning to the foreground.
    public func refresh() {
        guard phase == .running else { return }
        recomputeRemaining()
        if remaining <= 0 { complete() }
    }

    // MARK: Machinery

    private func move(to position: Int) {
        stopTimekeeping()
        cyclePosition = max(0, position)
        phase = .idle
        remaining = plannedDuration
    }

    /// A focus that ran at least this long, then was abandoned, is logged as real
    /// focused time (shorter abandons are treated as skips and not recorded).
    public static let minLoggedFocus: TimeInterval = 3 * 60

    private func stopTimekeeping() {
        // An active session is one that's running OR paused; both must signal
        // abandonment so hosts (e.g. the iOS Live Activity) tear down. Only a
        // fresh idle phase should stay silent.
        let wasActive = phase != .idle
        clock.cancel()
        if wasActive {
            recordAbandonedFocusIfSubstantial()
            onSessionInterrupted?(true) // abandoned (reset / scrubbed)
        }
        endDate = nil
        currentSessionStart = nil
    }

    /// If the user actually focused for a meaningful stretch before abandoning,
    /// record the *real* focused time (never a "skipped" marker).
    private func recordAbandonedFocusIfSubstantial() {
        guard kind == .focus, let start = currentSessionStart else { return }
        if phase == .running { recomputeRemaining() }
        let focused = plannedDuration - remaining
        guard focused >= Self.minLoggedFocus else { return }
        history.add(
            FocusSession(
                kind: .focus,
                plannedDuration: focused,
                startedAt: start,
                endedAt: clock.now,
                completed: true
            )
        )
    }

    private func scheduleTicks() {
        clock.schedule(every: tickInterval) { [weak self] in
            self?.tick()
        }
    }

    private func tick() {
        guard phase == .running else { return }
        recomputeRemaining()
        if remaining <= 0 { complete() }
    }

    private func recomputeRemaining() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSince(clock.now))
    }

    private func complete() {
        clock.cancel()
        remaining = 0
        let finished = finishCurrentSession(completed: true)
        if let finished { onSessionCompleted?(finished) }

        // Advance to the next phase in the cycle.
        cyclePosition += 1
        phase = .idle
        remaining = plannedDuration

        let autoStart = kind.isBreak ? settings.autoStartBreaks : settings.autoStartFocus
        if autoStart { start() }
    }

    @discardableResult
    private func finishCurrentSession(completed: Bool) -> FocusSession? {
        guard let start = currentSessionStart else { return nil }
        let session = FocusSession(
            kind: kind,
            plannedDuration: plannedDuration,
            startedAt: start,
            endedAt: clock.now,
            completed: completed
        )
        history.add(session)
        currentSessionStart = nil
        endDate = nil
        return session
    }
}
