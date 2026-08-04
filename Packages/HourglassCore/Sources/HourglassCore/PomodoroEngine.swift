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
    /// Seconds this phase has run **past** its planned end, once it has.
    ///
    /// A phase no longer advances itself when the clock runs out: it announces
    /// the finish (the notification, the History record) and keeps counting, so
    /// the user is never told a focus is over while they are still in the middle
    /// of something. ``advance()`` is what moves on, and only the user calls it.
    public private(set) var overrun: TimeInterval = 0
    /// When the current session was frozen, so the UI can say *when* the pause
    /// began rather than only that it did. Nil unless `phase == .paused`.
    public private(set) var pausedAt: Date?

    // MARK: Dependencies

    private let settingsStore: any SettingsStoring
    private let history: any HistoryStoring
    private let clock: any PomodoroClock
    private let stamps: any UpdateStamping
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
    /// The deadline this phase was given, kept after the finish has been
    /// announced so the overrun can go on being measured against it — and so the
    /// sync layer has something truthful to put on the wire. `endDate` is
    /// cleared by the recording; this is not.
    public private(set) var plannedEnd: Date?
    /// One announcement per phase, however many ticks arrive after zero.
    private var didAnnounceFinish = false
    private var currentSessionStart: Date?

    /// The identity of the session currently on the clock, minted at `start()`
    /// and shared across devices through the live state.
    ///
    /// Both devices run their own countdown off the shared `endDate`, so both
    /// reach zero — but the session happened once. Instead of electing an owner
    /// (which auto-start kept breaking, recording every session twice), every
    /// device records the completion **under the same id**: the stores upsert by
    /// id, so however many devices witness the finish, history holds one row.
    public private(set) var currentSessionID: UUID?

    /// True while the current session is a reconstruction of another device's
    /// timer rather than one started here. Purely informational now that
    /// records are deduplicated by ``currentSessionID``.
    public private(set) var isMirroring = false

    public init(
        settingsStore: any SettingsStoring,
        history: any HistoryStoring,
        clock: any PomodoroClock = SystemClock(),
        stamps: (any UpdateStamping)? = nil,
        tickInterval: TimeInterval = 0.25
    ) {
        self.settingsStore = settingsStore
        self.history = history
        self.clock = clock
        // Defaults to the injected clock, so stamps stay deterministic under
        // test clocks; the app swaps in the shared hybrid clock for sync.
        self.stamps = stamps ?? WallClockStamps(wallClock: { clock.now })
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

    /// True once the phase has passed its planned end and is counting on.
    public var isOverrunning: Bool { phase == .running && didAnnounceFinish }

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
        currentSessionID = UUID() // a fresh identity, shared via the live state
        isMirroring = false // started here
        pausedAt = nil
        plannedEnd = endDate
        overrun = 0
        didAnnounceFinish = false
        phase = .running
        scheduleTicks()
        onSessionStarted?(kind, remaining)
    }

    public func pause() {
        guard phase == .running else { return }
        recomputeRemaining()
        clock.cancel()
        pausedAt = clock.now
        phase = .paused
        onSessionInterrupted?(false) // paused, can resume
    }

    public func resume() {
        guard phase == .paused else { return }
        endDate = clock.now.addingTimeInterval(remaining)
        plannedEnd = endDate
        pausedAt = nil
        phase = .running
        scheduleTicks()
        onSessionStarted?(kind, remaining)
    }

    /// Stop and return to the start of the current session kind (position unchanged).
    public func reset() {
        let abandoned = stopTimekeeping()
        phase = .idle
        remaining = plannedDuration
        if abandoned { onSessionInterrupted?(true) }
    }

    /// Stop the Pomodoro entirely and return to the start of the cycle.
    ///
    /// Distinct from ``reset()``, which keeps the position: this is how a
    /// caller says "no phase exists any more". Clocking out uses it, because a
    /// staged phase left behind would keep every surface describing a Pomodoro
    /// the user has finished with — and would keep the manual Break action
    /// hidden on a day that no longer has a timer in it.
    public func endCycle() {
        let abandoned = stopTimekeeping()
        cyclePosition = 0
        phase = .idle
        pausedAt = nil
        remaining = plannedDuration
        if abandoned { onSessionInterrupted?(true) }
    }

    /// Move on from a phase that has run out — the user's "Continue".
    ///
    /// This is the only thing that ends a finished phase. The record was already
    /// written when the clock reached zero, so all that is left is to take the
    /// position forward and set the next phase up; whether it starts by itself
    /// is still the auto-start settings' business.
    public func advance() {
        guard phase != .idle else { return }
        clock.cancel()
        endDate = nil
        plannedEnd = nil
        overrun = 0
        didAnnounceFinish = false
        currentSessionStart = nil
        currentSessionID = nil
        pausedAt = nil
        isMirroring = false
        cyclePosition += 1
        phase = .idle
        remaining = plannedDuration

        // Announced, because this moved the position. Every other intent that
        // does reports it, and the sync layer mirrors the engine from these
        // callbacks — without one, Continue was invisible to the other device,
        // which sat on the finished phase and pushed it straight back.
        onSessionInterrupted?(true)

        let autoStart = kind.isBreak ? settings.autoStartBreaks : settings.autoStartFocus
        if autoStart { start() }
    }

    /// Scrub forward to the next phase in the cycle.
    public func goToNextPhase() { move(to: cyclePosition + 1) }

    /// Scrub backward to the previous phase (clamped at the first focus).
    public func goToPreviousPhase() { move(to: cyclePosition - 1) }

    /// What adopting a remote state amounted to, so the host can mirror the
    /// side effects a local action would have had (notifications, Live
    /// Activity). Without this a mirrored Pomodoro was invisible the moment the
    /// app backgrounded: nothing had scheduled its completion alert.
    public enum RemoteAdoption: Equatable, Sendable {
        /// A session began (or its deadline moved): schedule the look-ahead alert.
        case startedRunning(kind: SessionKind, remaining: TimeInterval)
        /// The running session froze: cancel pending alerts, keep the activity.
        case paused
        /// The session ended or was abandoned elsewhere: tear everything down.
        case stopped
        /// Nothing user-visible changed.
        case unchanged
    }

    /// Adopt timer state mirrored from another device.
    ///
    /// The countdown is reconstructed locally from `endDate`, so the two devices
    /// agree without streaming ticks. A paused peer sends the instant it froze at
    /// plus an `endDate` measured from it, so the frozen remaining survives the
    /// trip instead of the session resetting under the other device's feet.
    ///
    /// Engine callbacks are intentionally *not* fired — this is a mirror of a
    /// decision made elsewhere, not a new local action — but the returned
    /// ``RemoteAdoption`` tells the host what changed so it can keep alerts and
    /// Live Activities truthful.
    @discardableResult
    public func applyRemoteState(
        cyclePosition: Int,
        isRunning: Bool,
        endDate: Date?,
        pausedAt: Date?,
        sessionID: UUID? = nil
    ) -> RemoteAdoption {
        let wasActive = phase != .idle
        let previousPhase = phase
        let previousEndDate = self.endDate
        clock.cancel()
        self.cyclePosition = max(0, cyclePosition)

        // Whether this device already holds a session it started itself. Kept
        // for the ownership flag; record identity now travels as `sessionID`,
        // so two devices that auto-start the same phase converge on one id
        // (the later write's) instead of each recording their own copy.
        let ownsCurrentSession = phase != .idle && !isMirroring

        if isRunning, let endDate {
            let remaining = max(0, endDate.timeIntervalSince(clock.now))
            self.endDate = remaining > 0 ? endDate : nil
            self.plannedEnd = endDate
            self.remaining = remaining
            self.pausedAt = nil
            if let sessionID { currentSessionID = sessionID }
            isMirroring = !ownsCurrentSession
            phase = .running

            // A row whose deadline has already passed is a phase in **overrun**
            // over there, not one that finished and moved on. Landing at the
            // next position was right while the engine advanced itself; now
            // nothing advances but the user, so adopting the advance here would
            // skip a phase they never continued past. The record arrives on its
            // own row from whichever device witnessed the finish.
            if remaining <= 0 {
                didAnnounceFinish = true
                overrun = max(0, clock.now.timeIntervalSince(endDate))
                // The phase behind this row has already finished, and whichever
                // device witnessed it wrote the record. Leaving an anchor here
                // would let a later teardown on *this* device log a second,
                // phantom session of the full planned length — the abandon path
                // measures `plannedDuration - remaining`, and remaining is nil.
                currentSessionStart = nil
            } else {
                didAnnounceFinish = false
                overrun = 0
                if currentSessionStart == nil { currentSessionStart = clock.now }
            }
            scheduleTicks()
            let deadlineMoved = previousEndDate.map { abs($0.timeIntervalSince(endDate)) > 1 } ?? true
            return (previousPhase != .running || deadlineMoved)
                ? .startedRunning(kind: kind, remaining: remaining)
                : .unchanged
        } else if let endDate, let pausedAt {
            // Frozen time is the only truth while paused — there is no deadline
            // to count against, so drop the peer's and keep `remaining` intact.
            self.endDate = nil
            remaining = max(0, endDate.timeIntervalSince(pausedAt))
            // Back-date the anchor by the elapsed time — the same collapse hosts
            // make from `remaining` — so a later abandon logs a real stretch of
            // focus rather than one that appears to have started just now.
            if currentSessionStart == nil {
                currentSessionStart = clock.now.addingTimeInterval(-max(0, plannedDuration - remaining))
            }
            if let sessionID { currentSessionID = sessionID }
            isMirroring = !ownsCurrentSession
            // The peer's freeze instant, so "paused since" reads the same on
            // both devices rather than restarting at this device's clock.
            self.pausedAt = pausedAt
            self.plannedEnd = nil
            overrun = 0
            didAnnounceFinish = false
            phase = .paused
            return previousPhase == .paused ? .unchanged : .paused
        } else {
            self.endDate = nil
            self.plannedEnd = nil
            overrun = 0
            didAnnounceFinish = false
            currentSessionStart = nil
            currentSessionID = nil
            self.pausedAt = nil
            phase = .idle
            remaining = plannedDuration
            isMirroring = false
            return wasActive ? .stopped : .unchanged
        }
    }

    /// Recompute against the wall clock — call when returning to the foreground.
    public func refresh() {
        guard phase == .running else { return }
        recomputeRemaining()
        if remaining <= 0 { passZero() }
    }

    // MARK: Machinery

    private func move(to position: Int) {
        let abandoned = stopTimekeeping()
        cyclePosition = max(0, position)
        phase = .idle
        remaining = plannedDuration
        if abandoned { onSessionInterrupted?(true) }
    }

    /// A focus that ran at least this long, then was abandoned, is logged as real
    /// focused time (shorter abandons are treated as skips and not recorded).
    public static let minLoggedFocus: TimeInterval = 3 * 60

    /// Tear down the running/paused session and report whether one was abandoned.
    ///
    /// It deliberately does *not* fire `onSessionInterrupted` itself: listeners
    /// snapshot the engine (phase, remaining, cyclePosition) and mirror that
    /// snapshot to other devices, so announcing here — mid-teardown, before the
    /// caller has settled the phase and position — publishes the dying session
    /// as though it were still live. Each caller announces once it is done.
    /// The result is intentionally *not* discardable: a caller that ignores it
    /// silently drops the interruption.
    private func stopTimekeeping() -> Bool {
        // An active session is one that's running OR paused; both must signal
        // abandonment so hosts (e.g. the iOS Live Activity) tear down. Only a
        // fresh idle phase should stay silent.
        let wasActive = phase != .idle
        clock.cancel()
        // Runs before the caller clears the phase — it reads `.running` to know
        // whether `remaining` still needs catching up to the wall clock.
        if wasActive { recordAbandonedFocusIfSubstantial() }
        endDate = nil
        plannedEnd = nil
        overrun = 0
        didAnnounceFinish = false
        currentSessionStart = nil
        currentSessionID = nil
        pausedAt = nil
        isMirroring = false // torn down; the next start decides ownership afresh
        return wasActive
    }

    /// If the user actually focused for a meaningful stretch before abandoning,
    /// record the *real* focused time (never a "skipped" marker).
    ///
    /// Recorded under the shared session id, so an abandon tapped on the mirror
    /// no longer discards the stretch (the old owner-only rule did exactly
    /// that), and both devices abandoning at once still yields a single row.
    private func recordAbandonedFocusIfSubstantial() {
        guard kind == .focus, let start = currentSessionStart else { return }
        if phase == .running { recomputeRemaining() }
        let focused = plannedDuration - remaining
        guard focused >= Self.minLoggedFocus else { return }
        history.upsert(
            FocusSession(
                id: currentSessionID ?? UUID(),
                kind: .focus,
                plannedDuration: focused,
                startedAt: start,
                endedAt: clock.now,
                completed: true,
                updatedAt: stamps.next()
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
        if remaining <= 0 { passZero() }
    }

    /// At and beyond the deadline: announce the finish exactly once, then keep
    /// counting upward until the user continues.
    private func passZero() {
        if !didAnnounceFinish { announceFinish() }
        guard let plannedEnd else { return }
        overrun = max(0, clock.now.timeIntervalSince(plannedEnd))
    }

    private func recomputeRemaining() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSince(clock.now))
    }

    /// The clock ran out: write the record and tell the host, but stay on this
    /// phase. Nothing advances until ``advance()``.
    ///
    /// The position deliberately does *not* move here any more. It used to, and
    /// the ordering mattered a great deal — listeners mirror the engine to other
    /// devices, so announcing before advancing published the dying phase as the
    /// live one. Now nothing moves at all, and the peers that adopt this state
    /// land in the same overrun this device is in.
    private func announceFinish() {
        didAnnounceFinish = true
        remaining = 0
        // Keeps ticking: the countdown is over but the count is not.
        let finished = finishCurrentSession(completed: true)
        if let finished { onSessionCompleted?(finished) }
    }

    @discardableResult
    private func finishCurrentSession(completed: Bool) -> FocusSession? {
        guard let start = currentSessionStart else { return nil }
        // A completion can be observed late — the app was suspended past the
        // deadline. The session still ended when its clock ran out, not when
        // we happened to notice; recording "now" would misstate the day by
        // hours and outrank the peer that recorded it correctly at the time.
        let ended = min(clock.now, endDate ?? clock.now)
        let session = FocusSession(
            id: currentSessionID ?? UUID(),
            kind: kind,
            plannedDuration: plannedDuration,
            startedAt: start,
            endedAt: ended,
            completed: completed,
            updatedAt: stamps.next()
        )
        // Every device that witnesses the finish records it — under the shared
        // session id, so the stores and the server upsert the copies into one
        // row. This is what lets a Pomodoro survive the starting device being
        // offline at the moment it completes.
        history.upsert(session)
        // The anchor goes, so nothing can log this stretch twice. The *id*
        // stays: the phase is still on screen and still being mirrored, and the
        // peers need it to recognise the record as the one they already have.
        // `advance()` and `stopTimekeeping()` clear it when the phase really ends.
        currentSessionStart = nil
        endDate = nil
        return session
    }
}
