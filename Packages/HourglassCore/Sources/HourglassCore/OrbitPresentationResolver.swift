import Foundation

/// Which surface is asking. The two differ only in how much context they have
/// room for: the phone shows at most one contextual pill, the Mac panel two.
public enum OrbitSurface: String, Equatable, Sendable {
    case phone
    case panel
}

/// Everything the resolver needs, gathered once by the app model.
///
/// Deliberately a plain value: the resolver takes no clock, no store and no
/// engine, so every state in the matrix can be built in a test in three lines
/// and the answer is the same one the app will draw.
public struct OrbitSnapshot: Equatable, Sendable {
    public var now: Date
    public var workday: WorkdayState
    public var pomodoro: PomodoroState
    /// When the current clocked-in stretch began (independent of any break).
    public var clockedInAt: Date?
    public var netWorkedToday: TimeInterval
    /// Time since the last break ended, or nil when there has not been one yet.
    public var timeSinceLastBreak: TimeInterval?
    /// When the running phase was paused, for the "Since 14:32" pill.
    public var pausedAt: Date?
    public var focusesCompletedInCycle: Int
    public var sessionsUntilLongBreak: Int
    /// The phases either side of this one, so each arrow can name where it
    /// lands instead of being a bare chevron.
    public var nextPhaseKind: SessionKind
    public var previousPhaseKind: SessionKind
    /// The configured focus length, for "Next · Focus 25m".
    public var nextFocusDuration: TimeInterval
    /// Yesterday's net worked time, for the clocked-out pill. Nil when unknown
    /// or zero, in which case the pill is omitted rather than reading "0m".
    public var yesterdayWorked: TimeInterval?
    public var surface: OrbitSurface
    public var locale: Locale
    public var calendar: Calendar

    public init(
        now: Date,
        workday: WorkdayState,
        pomodoro: PomodoroState,
        clockedInAt: Date? = nil,
        netWorkedToday: TimeInterval = 0,
        timeSinceLastBreak: TimeInterval? = nil,
        pausedAt: Date? = nil,
        focusesCompletedInCycle: Int = 0,
        sessionsUntilLongBreak: Int = 4,
        nextPhaseKind: SessionKind = .shortBreak,
        previousPhaseKind: SessionKind = .focus,
        nextFocusDuration: TimeInterval = 25 * 60,
        yesterdayWorked: TimeInterval? = nil,
        surface: OrbitSurface = .phone,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) {
        self.now = now
        self.workday = workday
        self.pomodoro = pomodoro
        self.clockedInAt = clockedInAt
        self.netWorkedToday = netWorkedToday
        self.timeSinceLastBreak = timeSinceLastBreak
        self.pausedAt = pausedAt
        self.focusesCompletedInCycle = focusesCompletedInCycle
        self.sessionsUntilLongBreak = sessionsUntilLongBreak
        self.nextPhaseKind = nextPhaseKind
        self.previousPhaseKind = previousPhaseKind
        self.nextFocusDuration = nextFocusDuration
        self.yesterdayWorked = yesterdayWorked
        self.surface = surface
        self.locale = locale
        self.calendar = calendar
    }
}

/// The one place the two state axes become one screen.
///
/// Pure and deterministic: same snapshot in, same presentation out. Views own no
/// part of this decision, which is what keeps the state label, the numeral, the
/// pill, the rail and the controls from contradicting one another.
public enum OrbitPresentationResolver {

    /// The presentation states the whole matrix collapses to. Derived, never
    /// stored — the source of truth stays the two axes.
    public enum State: Equatable, Sendable {
        case clockedOut
        /// Clocked in, working, no Pomodoro phase at all.
        case working
        case focusRunning
        case focusPaused
        /// A focus phase selected but not started (auto-start off).
        case focusStaged
        case pomodoroBreakRunning(SessionKind)
        case pomodoroBreakPaused(SessionKind)
        /// A break phase staged at full duration; the linked work break has
        /// already begun, so work time is not accumulating.
        case pomodoroBreakStaged(SessionKind)
        /// The break countdown reached zero and the user has not come back yet.
        case breakComplete(SessionKind)
        case manualBreak
    }

    // MARK: State

    public static func state(workday: WorkdayState, pomodoro: PomodoroState) -> State {
        // Clocking out ends everything the face could be describing, so it wins
        // outright — a leftover phase must never keep a closed day on screen.
        guard workday.isClockedIn else { return .clockedOut }

        switch pomodoro {
        case .running(let kind, _):
            return kind.isBreak ? .pomodoroBreakRunning(kind) : .focusRunning
        case .paused(let kind, _):
            return kind.isBreak ? .pomodoroBreakPaused(kind) : .focusPaused
        case .ready(let kind, _):
            return kind.isBreak ? .pomodoroBreakStaged(kind) : .focusStaged
        case .completed(let kind):
            return .breakComplete(kind)
        case .idle:
            return workday.isOnBreak ? .manualBreak : .working
        }
    }

    // MARK: Resolve

    public static func resolve(_ snapshot: OrbitSnapshot) -> OrbitPresentation {
        let state = state(workday: snapshot.workday, pomodoro: snapshot.pomodoro)
        let tone = tone(for: state)
        let numeral = numeral(state, snapshot)
        let rail = workdayRail(state, snapshot)
        let pills = pills(state, snapshot)

        return OrbitPresentation(
            stateLabel: label(for: state, snapshot),
            stateTone: tone,
            numeral: numeral,
            cycleDots: cycleDots(state, snapshot),
            contextPills: pills,
            workdayRail: rail,
            clockOut: clockOut(state, snapshot),
            controls: controls(state, snapshot),
            sceneMode: sceneMode(for: state),
            menuBarBadge: badge(state, snapshot),
            overflowActions: overflow(state, snapshot.locale),
            accessibilitySummary: summary(state, snapshot, numeral: numeral, rail: rail),
            canStartManualBreak: snapshot.workday.isWorking && snapshot.pomodoro.isIdle,
            clockOutNeedsConfirmation: snapshot.pomodoro.exists || snapshot.workday.isOnBreak
        )
    }

    // MARK: Label

    private static func label(for state: State, _ snapshot: OrbitSnapshot) -> String {
        let locale = snapshot.locale
        switch state {
        case .clockedOut:
            return Copy.clockedOut(locale)
        case .working:
            return Copy.clockedIn(locale)
        case .focusRunning, .focusStaged:
            return Copy.focus(locale)
        case .focusPaused:
            return Copy.focusPaused(locale)
        case .pomodoroBreakRunning(let kind), .pomodoroBreakStaged(let kind):
            return Copy.breakPhase(kind, locale)
        case .pomodoroBreakPaused(let kind):
            return Copy.breakPhasePaused(kind, locale)
        case .breakComplete:
            return Copy.breakComplete(locale)
        case .manualBreak:
            return Copy.restingLabel(locale)
        }
    }

    private static func tone(for state: State) -> OrbitTone {
        switch state {
        case .clockedOut: return .dim
        case .working, .focusRunning, .focusStaged: return .ember
        case .focusPaused, .pomodoroBreakRunning, .pomodoroBreakPaused,
             .pomodoroBreakStaged, .breakComplete, .manualBreak:
            return .stone
        }
    }

    // MARK: Numeral

    private static func numeral(_ state: State, _ snapshot: OrbitSnapshot) -> NumeralPresentation {
        let locale = snapshot.locale
        let remaining = snapshot.pomodoro.remaining

        switch state {
        case .clockedOut:
            let text = TimeFormatting.timeOfDay(snapshot.now, locale: locale, timeZone: snapshot.calendar.timeZone)
            return NumeralPresentation(
                text: text,
                kind: .wallClock,
                tone: .dim,
                accessibilityLabel: Copy.currentTime(text, locale)
            )

        case .working:
            return NumeralPresentation(
                text: TimeFormatting.elapsed(snapshot.netWorkedToday),
                kind: .workedToday,
                tone: .ember,
                accessibilityLabel: Copy.workedToday(
                    TimeFormatting.spoken(snapshot.netWorkedToday, locale: locale), locale)
            )

        case .focusRunning, .focusStaged:
            return NumeralPresentation(
                text: TimeFormatting.clock(remaining),
                kind: .countdown,
                tone: .ember,
                accessibilityLabel: Copy.remaining(
                    TimeFormatting.spoken(remaining, locale: locale), locale)
            )

        case .focusPaused, .pomodoroBreakPaused:
            return NumeralPresentation(
                text: TimeFormatting.clock(remaining),
                kind: .frozenCountdown,
                tone: .stone,
                accessibilityLabel: Copy.remaining(
                    TimeFormatting.spoken(remaining, locale: locale), locale)
            )

        case .pomodoroBreakRunning, .pomodoroBreakStaged:
            return NumeralPresentation(
                text: TimeFormatting.clock(remaining),
                kind: .countdown,
                tone: .stone,
                accessibilityLabel: Copy.remaining(
                    TimeFormatting.spoken(remaining, locale: locale), locale)
            )

        case .breakComplete:
            return NumeralPresentation(
                text: TimeFormatting.clock(0),
                kind: .countdown,
                tone: .stone,
                accessibilityLabel: Copy.breakComplete(locale)
            )

        case .manualBreak:
            let elapsed = breakElapsed(snapshot)
            return NumeralPresentation(
                text: TimeFormatting.elapsed(elapsed),
                kind: .breakElapsed,
                tone: .stone,
                accessibilityLabel: Copy.breakElapsed(
                    TimeFormatting.spoken(elapsed, locale: locale), locale)
            )
        }
    }

    private static func breakElapsed(_ snapshot: OrbitSnapshot) -> TimeInterval {
        guard case .onBreak(let startedAt, _) = snapshot.workday else { return 0 }
        return max(0, snapshot.now.timeIntervalSince(startedAt))
    }

    // MARK: Cycle dots

    /// Dots belong to the focus cycle. A break already says what it is, and the
    /// dots would only repeat the position the break itself implies.
    private static func cycleDots(_ state: State, _ snapshot: OrbitSnapshot) -> CycleDotsPresentation? {
        switch state {
        case .focusRunning, .focusPaused, .focusStaged:
            let total = max(1, snapshot.sessionsUntilLongBreak)
            let completed = min(total, max(0, snapshot.focusesCompletedInCycle))
            return CycleDotsPresentation(
                completed: completed,
                total: total,
                accessibilityLabel: Copy.cycle(completed + 1, total, snapshot.locale)
            )
        default:
            return nil
        }
    }

    // MARK: Contextual pills

    private static func pills(_ state: State, _ snapshot: OrbitSnapshot) -> [ContextPillPresentation] {
        let all = candidatePills(state, snapshot)
        // One line, and only as many as the surface has room for: one on the
        // phone, two in the panel.
        return Array(all.prefix(snapshot.surface == .phone ? 1 : 2))
    }

    private static func candidatePills(
        _ state: State,
        _ snapshot: OrbitSnapshot
    ) -> [ContextPillPresentation] {
        let locale = snapshot.locale
        let phone = snapshot.surface == .phone

        switch state {
        case .clockedOut:
            guard let yesterday = snapshot.yesterdayWorked, yesterday > 0 else { return [] }
            let value = TimeFormatting.compact(yesterday, locale: locale)
            return [
                ContextPillPresentation(
                    id: "yesterday",
                    icon: .clock,
                    full: Copy.yesterdayFull(value, locale),
                    compact: Copy.yesterdayCompact(value, locale),
                    accessibilityLabel: Copy.yesterdaySpoken(
                        TimeFormatting.spoken(yesterday, locale: locale), locale),
                    tone: .stone
                )
            ]

        case .working, .focusStaged:
            // The phone leads with rest recency; the panel leads with when the
            // day began, because it has room for both.
            let lastBreak = lastBreakPill(snapshot)
            let since = clockedInSincePill(snapshot)
            return phone ? [lastBreak] : [since, lastBreak].compactMap { $0 }

        case .focusRunning:
            let endsAt = snapshot.now.addingTimeInterval(snapshot.pomodoro.remaining)
            let time = TimeFormatting.timeOfDay(endsAt, locale: locale, timeZone: snapshot.calendar.timeZone)
            let ends = ContextPillPresentation(
                id: "ends",
                icon: .focus,
                full: Copy.endsFull(time, locale),
                compact: Copy.endsCompact(time, locale),
                accessibilityLabel: Copy.endsSpoken(time, locale),
                tone: .ember
            )
            return phone ? [ends] : [ends, workdayTotalPill(snapshot)]

        case .focusPaused:
            let time = TimeFormatting.timeOfDay(snapshot.pausedAt ?? snapshot.now, locale: locale, timeZone: snapshot.calendar.timeZone)
            let since = ContextPillPresentation(
                id: "pausedSince",
                icon: .pause,
                full: Copy.sinceFull(time, locale),
                compact: Copy.sinceCompact(time, locale),
                accessibilityLabel: Copy.pausedSinceSpoken(time, locale),
                tone: .stone
            )
            return phone ? [since] : [since, workdayTotalPill(snapshot)]

        case .pomodoroBreakRunning, .pomodoroBreakStaged, .pomodoroBreakPaused, .breakComplete:
            let duration = TimeFormatting.compact(snapshot.nextFocusDuration, locale: locale)
            let next = ContextPillPresentation(
                id: "nextFocus",
                icon: .focus,
                full: Copy.nextFocusFull(duration, locale),
                compact: Copy.nextFocusCompact(duration, locale),
                accessibilityLabel: Copy.nextFocusSpoken(duration, locale),
                tone: .stone
            )
            // "Work break" is additive on the panel — the label there says
            // "Short break", so this is the *workday* accounting, not a repeat.
            let linked = ContextPillPresentation(
                id: "linkedWorkBreak",
                icon: .cup,
                full: Copy.restingLabel(locale),
                compact: Copy.restingLabel(locale),
                accessibilityLabel: Copy.linkedBreakSpoken(locale),
                tone: .stone
            )
            return phone ? [next] : [linked, next]

        case .manualBreak:
            // The numeral counts the rest and the rail says when it began, so
            // the one fact still missing is how the day itself is going.
            let total = workdayTotalPill(snapshot)
            guard !phone, case .onBreak(let startedAt, _) = snapshot.workday else { return [total] }
            let time = TimeFormatting.timeOfDay(startedAt, locale: locale, timeZone: snapshot.calendar.timeZone)
            let since = ContextPillPresentation(
                id: "breakSince",
                icon: .clock,
                full: Copy.sinceFull(time, locale),
                compact: Copy.sinceCompact(time, locale),
                accessibilityLabel: Copy.breakSinceSpoken(time, locale),
                tone: .stone
            )
            return [since, total]
        }
    }

    private static func lastBreakPill(_ snapshot: OrbitSnapshot) -> ContextPillPresentation {
        let locale = snapshot.locale
        guard let since = snapshot.timeSinceLastBreak else {
            return ContextPillPresentation(
                id: "noBreakYet",
                icon: .cup,
                full: Copy.noBreakYet(locale),
                compact: Copy.noBreakYet(locale),
                accessibilityLabel: Copy.noBreakYet(locale),
                tone: .stone
            )
        }
        let value = TimeFormatting.compact(since, locale: locale)
        return ContextPillPresentation(
            id: "lastBreak",
            icon: .cup,
            full: Copy.lastBreakFull(value, locale),
            compact: Copy.lastBreakCompact(value, locale),
            accessibilityLabel: Copy.lastBreakSpoken(
                TimeFormatting.spoken(since, locale: locale), locale),
            tone: .stone
        )
    }

    private static func clockedInSincePill(_ snapshot: OrbitSnapshot) -> ContextPillPresentation? {
        guard let clockedInAt = snapshot.clockedInAt else { return nil }
        let time = TimeFormatting.timeOfDay(clockedInAt, locale: snapshot.locale, timeZone: snapshot.calendar.timeZone)
        return ContextPillPresentation(
            id: "clockedInSince",
            icon: .clock,
            full: Copy.sinceFull(time, snapshot.locale),
            compact: Copy.sinceCompact(time, snapshot.locale),
            accessibilityLabel: Copy.clockedInSpoken(time, snapshot.locale),
            tone: .ember
        )
    }

    private static func workdayTotalPill(_ snapshot: OrbitSnapshot) -> ContextPillPresentation {
        let value = TimeFormatting.compact(snapshot.netWorkedToday, locale: snapshot.locale)
        return ContextPillPresentation(
            id: "workdayTotal",
            icon: .clock,
            full: Copy.workdayTotal(value, snapshot.locale),
            compact: Copy.workdayTotal(value, snapshot.locale),
            accessibilityLabel: Copy.workedToday(
                TimeFormatting.spoken(snapshot.netWorkedToday, locale: snapshot.locale),
                snapshot.locale),
            tone: .stone
        )
    }

    // MARK: Workday rail

    private static func workdayRail(
        _ state: State,
        _ snapshot: OrbitSnapshot
    ) -> WorkdayRailPresentation? {
        let locale = snapshot.locale
        guard state != .clockedOut else { return nil }

        switch snapshot.workday {
        case .clockedOut:
            return nil

        case .working(let startedAt):
            let worked = TimeFormatting.compact(snapshot.netWorkedToday, locale: locale)
            let time = TimeFormatting.timeOfDay(startedAt, locale: locale, timeZone: snapshot.calendar.timeZone)
            return WorkdayRailPresentation(
                primary: Copy.workedRail(worked, locale),
                secondary: Copy.clockedInAt(time, locale),
                tone: .ember,
                inlineAction: inlineAction(state, snapshot),
                accessibilityLabel: Copy.railSpoken(
                    TimeFormatting.spoken(snapshot.netWorkedToday, locale: locale), time, locale)
            )

        case .onBreak(let startedAt, let source):
            let elapsed = max(0, snapshot.now.timeIntervalSince(startedAt))
            let value = TimeFormatting.rest(elapsed, locale: locale)
            let secondary = source.isPomodoro
                ? Copy.startedAutomatically(locale)
                : Copy.startedAt(TimeFormatting.timeOfDay(startedAt, locale: locale, timeZone: snapshot.calendar.timeZone), locale)
            return WorkdayRailPresentation(
                primary: Copy.restingRail(value, locale),
                secondary: secondary,
                tone: .stone,
                inlineAction: inlineAction(state, snapshot),
                accessibilityLabel: Copy.breakRailSpoken(
                    TimeFormatting.spoken(elapsed, locale: locale), locale)
            )
        }
    }

    /// The rail's single action slot.
    ///
    /// One slot, three answers, each the thing the user is most likely to reach
    /// for in that state: Break while simply working, Restart while a focus
    /// phase is in play (it does not belong among the arrows, which move), and
    /// Back to work while a Pomodoro break is running — because leaving a break
    /// means ending the linked rest, which no arrow does on its own.
    private static func inlineAction(
        _ state: State,
        _ snapshot: OrbitSnapshot
    ) -> LabeledAction? {
        let locale = snapshot.locale
        switch state {
        case .working:
            return LabeledAction(
                action: .startBreak,
                title: Copy.startBreak(locale),
                icon: .cup,
                tone: .ember,
                accessibilityLabel: Copy.startBreak(locale)
            )
        case .focusRunning, .focusPaused, .focusStaged:
            return LabeledAction(
                action: .restartPhase,
                title: Copy.restartShort(locale),
                icon: .restart,
                tone: .ember,
                accessibilityLabel: Copy.restart(.focus, locale)
            )
        case .pomodoroBreakRunning, .pomodoroBreakPaused, .pomodoroBreakStaged, .breakComplete:
            return LabeledAction(
                action: .backToWork,
                title: Copy.backToWork(locale),
                icon: .backToWork,
                tone: .stone,
                accessibilityLabel: Copy.backToWork(locale)
            )
        case .clockedOut, .manualBreak:
            return nil
        }
    }

    // MARK: Controls

    /// A Pomodoro phase of any kind gets the same three controls, so moving
    /// through the cycle works the same way wherever the user is in it. States
    /// with no phase get the one labelled action that state is about.
    private static func controls(
        _ state: State,
        _ snapshot: OrbitSnapshot
    ) -> OrbitControlsPresentation {
        let locale = snapshot.locale

        switch state {
        case .clockedOut:
            return .primary(LabeledAction(
                action: .clockIn,
                title: Copy.clockInAction(locale),
                icon: .clockIn,
                tone: .ember,
                accessibilityLabel: Copy.clockInAction(locale)
            ))

        case .working:
            return .primary(LabeledAction(
                action: .startFocus,
                title: Copy.startFocus(locale),
                icon: .focus,
                tone: .ember,
                accessibilityLabel: Copy.startFocus(locale)
            ))

        case .manualBreak:
            return .primary(LabeledAction(
                action: .backToWork,
                title: Copy.backToWork(locale),
                icon: .backToWork,
                tone: .stone,
                accessibilityLabel: Copy.backToWork(locale)
            ))

        case .focusRunning:
            return transport(centre: LabeledAction(
                action: .pause, icon: .pause, tone: .ember,
                accessibilityLabel: Copy.pauseFocus(locale)), snapshot)

        case .focusPaused:
            return transport(centre: LabeledAction(
                action: .resume, icon: .play, tone: .ember,
                accessibilityLabel: Copy.resumeFocus(locale)), snapshot)

        case .focusStaged:
            return transport(centre: LabeledAction(
                action: .startPhase, icon: .play, tone: .ember,
                accessibilityLabel: Copy.startPhase(.focus, locale)), snapshot)

        case .pomodoroBreakRunning(let kind):
            return transport(centre: LabeledAction(
                action: .pause, icon: .pause, tone: .stone,
                accessibilityLabel: Copy.pauseBreak(kind, locale)), snapshot)

        case .pomodoroBreakPaused(let kind):
            return transport(centre: LabeledAction(
                action: .resume, icon: .play, tone: .stone,
                accessibilityLabel: Copy.resumeBreak(kind, locale)), snapshot)

        case .pomodoroBreakStaged(let kind):
            return transport(centre: LabeledAction(
                action: .startPhase, icon: .play, tone: .stone,
                accessibilityLabel: Copy.startPhase(kind, locale)), snapshot)

        case .breakComplete:
            // The engine has already staged the next focus; starting it is what
            // ends the linked rest.
            return transport(centre: LabeledAction(
                action: .startPhase, icon: .play, tone: .stone,
                accessibilityLabel: Copy.startPhase(.focus, locale)), snapshot)
        }
    }

    private static func transport(
        centre: LabeledAction,
        _ snapshot: OrbitSnapshot
    ) -> OrbitControlsPresentation {
        .transport(TransportPresentation(
            previous: LabeledAction(
                action: .previousPhase,
                icon: .previous,
                tone: .stone,
                accessibilityLabel: Copy.previousPhase(snapshot.previousPhaseKind, snapshot.locale)
            ),
            playPause: centre,
            next: LabeledAction(
                action: .nextPhase,
                icon: .next,
                tone: .stone,
                accessibilityLabel: Copy.nextPhase(snapshot.nextPhaseKind, snapshot.locale)
            )
        ))
    }

    // MARK: Scene

    private static func sceneMode(for state: State) -> OrbitSceneMode {
        switch state {
        case .clockedOut: return .inactive
        case .working, .focusRunning, .focusStaged: return .recording
        case .focusPaused: return .paused
        case .pomodoroBreakRunning, .pomodoroBreakPaused, .pomodoroBreakStaged,
             .breakComplete, .manualBreak:
            return .resting
        }
    }

    // MARK: Menu bar badge

    private static func badge(_ state: State, _ snapshot: OrbitSnapshot) -> MenuBarBadgePresentation {
        let locale = snapshot.locale
        let remaining = snapshot.pomodoro.remaining
        let spokenRemaining = TimeFormatting.spoken(remaining, locale: locale)

        switch state {
        case .clockedOut:
            return MenuBarBadgePresentation(
                mark: .dim,
                value: nil,
                cadence: .none,
                accessibilityLabel: Copy.badgeClockedOut(locale)
            )

        case .working:
            return MenuBarBadgePresentation(
                mark: .hollowEmber,
                value: TimeFormatting.hoursMinutes(snapshot.netWorkedToday),
                cadence: .minute,
                accessibilityLabel: Copy.badgeWorking(
                    TimeFormatting.spoken(snapshot.netWorkedToday, locale: locale), locale)
            )

        case .focusRunning:
            return MenuBarBadgePresentation(
                mark: .solidEmber,
                value: TimeFormatting.clock(remaining),
                cadence: .second,
                accessibilityLabel: Copy.badgeFocus(spokenRemaining, locale)
            )

        // A bounded phase that exists but is not advancing — paused or staged —
        // shares one mark and never ticks.
        case .focusPaused:
            return MenuBarBadgePresentation(
                mark: .pause,
                value: TimeFormatting.clock(remaining),
                cadence: .none,
                accessibilityLabel: Copy.badgeFocusPaused(spokenRemaining, locale)
            )

        case .focusStaged:
            return MenuBarBadgePresentation(
                mark: .pause,
                value: TimeFormatting.clock(remaining),
                cadence: .none,
                accessibilityLabel: Copy.badgeFocusReady(spokenRemaining, locale)
            )

        case .pomodoroBreakRunning:
            return MenuBarBadgePresentation(
                mark: .solidStone,
                value: TimeFormatting.clock(remaining),
                cadence: .second,
                accessibilityLabel: Copy.badgeBreakRemaining(spokenRemaining, locale)
            )

        case .pomodoroBreakPaused(let kind):
            return MenuBarBadgePresentation(
                mark: .pause,
                value: TimeFormatting.clock(remaining),
                cadence: .none,
                accessibilityLabel: Copy.badgeBreakPaused(kind, spokenRemaining, locale)
            )

        case .pomodoroBreakStaged(let kind):
            return MenuBarBadgePresentation(
                mark: .pause,
                value: TimeFormatting.clock(remaining),
                cadence: .none,
                accessibilityLabel: Copy.badgeBreakReady(kind, spokenRemaining, locale)
            )

        // The countdown is over; what is still running is the open-ended work
        // break, so the badge switches to the open-ended grammar.
        case .breakComplete, .manualBreak:
            let elapsed = breakElapsed(snapshot)
            return MenuBarBadgePresentation(
                mark: .hollowStone,
                value: elapsed >= 3600
                    ? TimeFormatting.hoursMinutes(elapsed)
                    : TimeFormatting.elapsed(elapsed),
                cadence: .second,
                accessibilityLabel: Copy.badgeBreakElapsed(
                    TimeFormatting.spoken(elapsed, locale: locale), locale)
            )
        }
    }

    // MARK: Clocking out

    private static func clockOut(_ state: State, _ snapshot: OrbitSnapshot) -> ClockOutPresentation {
        let locale = snapshot.locale
        return ClockOutPresentation(
            isAvailable: snapshot.workday.isClockedIn,
            title: Copy.clockOutAction(locale),
            confirmationTitle: Copy.clockOutTitle(locale),
            confirmationMessage: Copy.clockOutMessage(
                phase: runningPhaseName(state, snapshot),
                endsBreak: snapshot.workday.isOnBreak,
                locale
            ),
            needsConfirmation: snapshot.pomodoro.exists || snapshot.workday.isOnBreak
        )
    }

    /// The phase clocking out would stop, named so the confirmation can say it.
    private static func runningPhaseName(_ state: State, _ snapshot: OrbitSnapshot) -> String? {
        guard snapshot.pomodoro.exists, let kind = snapshot.pomodoro.kind else { return nil }
        return kind == .focus ? Copy.focus(snapshot.locale) : Copy.breakPhase(kind, snapshot.locale)
    }

    // MARK: Overflow

    private static func overflow(_ state: State, _ locale: Locale) -> [OverflowItem] {
        let history = OverflowItem(action: .history, title: Copy.history(locale), icon: .history)
        let settings = OverflowItem(action: .settings, title: Copy.settings(locale), icon: .settings)
        guard state != .clockedOut else { return [history, settings] }

        var items: [OverflowItem] = []
        switch state {
        case .pomodoroBreakRunning, .pomodoroBreakPaused, .pomodoroBreakStaged, .breakComplete:
            // Restart is on the rail only while a focus phase is in play; during
            // a break the rail is carrying Back to work instead.
            items.append(OverflowItem(action: .restartPhase,
                                      title: Copy.restartPhase(locale), icon: .restart))
        default:
            break
        }
        // Finishing with the timer is not the same as finishing the day, so
        // there is a way out of Pomodoro that leaves the workday running.
        if state != .working && state != .manualBreak {
            items.append(OverflowItem(action: .endPomodoro,
                                      title: Copy.endPomodoro(locale), icon: .endPomodoro))
        }
        items += [history, settings,
                  OverflowItem(action: .clockOut, title: Copy.clockOutAction(locale), icon: .clockOut)]
        return items
    }

    // MARK: Accessibility summary

    private static func summary(
        _ state: State,
        _ snapshot: OrbitSnapshot,
        numeral: NumeralPresentation,
        rail: WorkdayRailPresentation?
    ) -> String {
        let locale = snapshot.locale
        var parts = [label(for: state, snapshot), numeral.accessibilityLabel]
        if let dots = cycleDots(state, snapshot) { parts.append(dots.accessibilityLabel) }
        var sentence = Copy.joinClauses(parts, locale)
        if let rail { sentence += " " + rail.accessibilityLabel }
        return sentence
    }
}
