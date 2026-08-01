import Foundation

/// Every user-visible string the Orbit surfaces show, in one table.
///
/// Each entry is a localizable key with an English default, so translators get a
/// catalog rather than a diff against the views, and nothing is assembled by
/// concatenating fragments — a language that puts the number after the noun, or
/// reads right to left, still gets a natural sentence. The resolver formats the
/// numbers first (locale-aware) and hands them in as whole placeholders.
enum Copy {

    // MARK: State labels
    //
    // Written in sentence case and uppercased by the views, because uppercasing
    // is language-specific and belongs to the presentation layer, not the data.

    static func clockedOut(_ locale: Locale) -> String {
        t("orbit.state.clockedOut", "Clocked out", locale, "State label: no workday is running")
    }

    static func clockedIn(_ locale: Locale) -> String {
        t("orbit.state.clockedIn", "Clocked in", locale, "State label: working, no Pomodoro phase")
    }

    static func focus(_ locale: Locale) -> String {
        t("orbit.state.focus", "Focus", locale, "State label: a focus phase")
    }

    static func focusPaused(_ locale: Locale) -> String {
        t("orbit.state.focusPaused", "Focus paused", locale, "State label: focus phase frozen")
    }

    static func breakPhase(_ kind: SessionKind, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.state.longBreak", "Long break", locale, "State label: long Pomodoro break")
            : t("orbit.state.shortBreak", "Short break", locale, "State label: short Pomodoro break")
    }

    static func breakPhasePaused(_ kind: SessionKind, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.state.longBreakPaused", "Long break paused", locale, "State label")
            : t("orbit.state.shortBreakPaused", "Short break paused", locale, "State label")
    }

    static func breakComplete(_ locale: Locale) -> String {
        t("orbit.state.breakComplete", "Break complete", locale,
          "State label: the break countdown finished and the user has not returned yet")
    }

    static func restingLabel(_ locale: Locale) -> String {
        t("orbit.state.break", "Break", locale, "State label: the workday is resting")
    }

    // MARK: Numerals (spoken)

    static func currentTime(_ time: String, _ locale: Locale) -> String {
        t("orbit.numeral.currentTime", "Current time \(time)", locale, "VoiceOver: wall clock")
    }

    static func workedToday(_ duration: String, _ locale: Locale) -> String {
        t("orbit.numeral.worked", "\(duration) worked today", locale, "VoiceOver: net worked time")
    }

    static func remaining(_ duration: String, _ locale: Locale) -> String {
        t("orbit.numeral.remaining", "\(duration) remaining", locale, "VoiceOver: countdown")
    }

    static func breakElapsed(_ duration: String, _ locale: Locale) -> String {
        t("orbit.numeral.breakElapsed", "\(duration) elapsed", locale, "VoiceOver: break running time")
    }

    static func cycle(_ current: Int, _ total: Int, _ locale: Locale) -> String {
        t("orbit.cycle", "cycle \(current) of \(total)", locale, "VoiceOver: position in the focus cycle")
    }

    // MARK: Contextual pills

    static func yesterdayFull(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.yesterday.full", "Yesterday · \(duration)", locale, "Pill: yesterday's worked total")
    }

    static func yesterdayCompact(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.yesterday.compact", "Yesterday \(duration)", locale, "Pill, short form")
    }

    static func yesterdaySpoken(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.yesterday.spoken", "Yesterday, \(duration) worked", locale, "VoiceOver")
    }

    static func endsFull(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.ends.full", "Ends \(time)", locale, "Pill: when the running phase finishes")
    }

    static func endsCompact(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.ends.compact", "Ends \(time)", locale, "Pill, short form")
    }

    static func endsSpoken(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.ends.spoken", "Ends at \(time)", locale, "VoiceOver")
    }

    static func sinceFull(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.since.full", "Since \(time)", locale, "Pill: when the current state began")
    }

    static func sinceCompact(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.since.compact", "Since \(time)", locale, "Pill, short form")
    }

    static func pausedSinceSpoken(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.pausedSince.spoken", "Paused since \(time)", locale, "VoiceOver")
    }

    static func clockedInSpoken(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.clockedIn.spoken", "Clocked in at \(time)", locale, "VoiceOver")
    }

    static func breakSinceSpoken(_ time: String, _ locale: Locale) -> String {
        t("orbit.pill.breakSince.spoken", "Break started at \(time)", locale, "VoiceOver")
    }

    static func nextFocusFull(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.nextFocus.full", "Next · Focus \(duration)", locale, "Pill: the phase after this break")
    }

    static func nextFocusCompact(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.nextFocus.compact", "Next Focus \(duration)", locale, "Pill, short form")
    }

    static func nextFocusSpoken(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.nextFocus.spoken", "Next phase, focus, \(duration)", locale, "VoiceOver")
    }

    static func linkedBreakSpoken(_ locale: Locale) -> String {
        t("orbit.pill.linkedBreak.spoken", "Counted as a workday break", locale,
          "VoiceOver: a Pomodoro break is also a workday break")
    }

    static func noBreakYet(_ locale: Locale) -> String {
        t("orbit.pill.noBreakYet", "No break yet", locale, "Pill: the user has not rested today")
    }

    static func lastBreakFull(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.lastBreak.full", "Last break · \(duration) ago", locale, "Pill: rest recency")
    }

    static func lastBreakCompact(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.lastBreak.compact", "Break \(duration) ago", locale, "Pill, short form")
    }

    static func lastBreakSpoken(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.lastBreak.spoken", "Last break \(duration) ago", locale, "VoiceOver")
    }

    static func workdayTotal(_ duration: String, _ locale: Locale) -> String {
        t("orbit.pill.workdayTotal", "Workday \(duration)", locale, "Pill: worked so far today")
    }

    // MARK: Workday rail

    static func workedRail(_ duration: String, _ locale: Locale) -> String {
        t("orbit.rail.worked", "\(duration) worked", locale, "Workday rail, primary line")
    }

    static func clockedInAt(_ time: String, _ locale: Locale) -> String {
        t("orbit.rail.clockedIn", "Clocked in \(time)", locale, "Workday rail, secondary line")
    }

    static func restingRail(_ duration: String, _ locale: Locale) -> String {
        t("orbit.rail.break", "Break · \(duration)", locale, "Workday rail, primary line")
    }

    static func startedAutomatically(_ locale: Locale) -> String {
        t("orbit.rail.startedAutomatically", "Started automatically", locale,
          "Workday rail: the break began with the Pomodoro phase")
    }

    static func startedAt(_ time: String, _ locale: Locale) -> String {
        t("orbit.rail.startedAt", "Started \(time)", locale, "Workday rail, secondary line")
    }

    static func railSpoken(_ duration: String, _ time: String, _ locale: Locale) -> String {
        t("orbit.rail.spoken", "Workday: \(duration) worked, clocked in at \(time).", locale, "VoiceOver")
    }

    static func breakRailSpoken(_ duration: String, _ locale: Locale) -> String {
        t("orbit.rail.breakSpoken", "Break, \(duration) so far.", locale, "VoiceOver")
    }

    // MARK: Actions

    static func clockInAction(_ locale: Locale) -> String {
        t("orbit.action.clockIn", "Clock in", locale, "Button")
    }

    static func clockOutAction(_ locale: Locale) -> String {
        t("orbit.action.clockOut", "Clock out", locale, "Destructive button")
    }

    static func startFocus(_ locale: Locale) -> String {
        t("orbit.action.startFocus", "Start focus", locale, "Button")
    }

    /// Each arrow names where it lands, so the pair is never a bare chevron.
    static func previousPhase(_ kind: SessionKind, _ locale: Locale) -> String {
        switch kind {
        case .focus:
            return t("orbit.action.previousFocus", "Back to focus", locale, "Button")
        case .shortBreak:
            return t("orbit.action.previousShortBreak", "Back to short break", locale, "Button")
        case .longBreak:
            return t("orbit.action.previousLongBreak", "Back to long break", locale, "Button")
        }
    }

    static func nextPhase(_ kind: SessionKind, _ locale: Locale) -> String {
        switch kind {
        case .focus:
            return t("orbit.action.nextFocus", "Forward to focus", locale, "Button")
        case .shortBreak:
            return t("orbit.action.nextShortBreak", "Forward to short break", locale, "Button")
        case .longBreak:
            return t("orbit.action.nextLongBreak", "Forward to long break", locale, "Button")
        }
    }

    static func startPhase(_ kind: SessionKind, _ locale: Locale) -> String {
        switch kind {
        case .focus:
            return t("orbit.action.startThisFocus", "Start focus", locale, "Button")
        case .shortBreak:
            return t("orbit.action.startShortBreak", "Start short break", locale, "Button")
        case .longBreak:
            return t("orbit.action.startLongBreak", "Start long break", locale, "Button")
        }
    }

    static func restartShort(_ locale: Locale) -> String {
        t("orbit.action.restartShort", "Restart", locale, "Inline button on the workday rail")
    }

    static func endPomodoro(_ locale: Locale) -> String {
        t("orbit.action.endPomodoro", "End Pomodoro", locale,
          "Menu item: leave the timer without ending the working day")
    }

    static func startBreakTimer(_ locale: Locale) -> String {
        t("orbit.action.startBreakTimer", "Start break timer", locale,
          "Button: begin the countdown of a break that is already staged")
    }

    static func backToWork(_ locale: Locale) -> String {
        t("orbit.action.backToWork", "Back to work", locale, "Button: end the current work break")
    }

    static func pauseFocus(_ locale: Locale) -> String {
        t("orbit.action.pauseFocus", "Pause focus", locale, "Button")
    }

    static func resumeFocus(_ locale: Locale) -> String {
        t("orbit.action.resumeFocus", "Resume focus", locale, "Button")
    }

    static func pauseBreak(_ kind: SessionKind, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.action.pauseLongBreak", "Pause long break", locale, "Button")
            : t("orbit.action.pauseShortBreak", "Pause short break", locale, "Button")
    }

    static func resumeBreak(_ kind: SessionKind, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.action.resumeLongBreak", "Resume long break", locale, "Button")
            : t("orbit.action.resumeShortBreak", "Resume short break", locale, "Button")
    }

    static func restart(_ kind: SessionKind, _ locale: Locale) -> String {
        switch kind {
        case .focus:
            return t("orbit.action.restartFocus", "Restart current focus", locale, "Button")
        case .shortBreak:
            return t("orbit.action.restartShortBreak", "Restart current short break", locale, "Button")
        case .longBreak:
            return t("orbit.action.restartLongBreak", "Restart current long break", locale, "Button")
        }
    }

    /// Skip must name its destination — the UI never exposes a bare "next".
    static func skipTo(_ kind: SessionKind, _ locale: Locale) -> String {
        switch kind {
        case .focus:
            return t("orbit.action.skipToFocus", "Skip to focus", locale, "Button")
        case .shortBreak:
            return t("orbit.action.skipToShortBreak", "Skip to short break", locale, "Button")
        case .longBreak:
            return t("orbit.action.skipToLongBreak", "Skip to long break", locale, "Button")
        }
    }

    static func startBreak(_ locale: Locale) -> String {
        t("orbit.action.startBreak", "Break", locale, "Button: start a manual work break")
    }

    static func restartPhase(_ locale: Locale) -> String {
        t("orbit.action.restartPhase", "Restart current phase", locale, "Menu item")
    }

    static func history(_ locale: Locale) -> String {
        t("orbit.action.history", "History", locale, "Menu item")
    }

    static func settings(_ locale: Locale) -> String {
        t("orbit.action.settings", "Settings", locale, "Menu item")
    }

    // MARK: Menu-bar badge (VoiceOver)

    static func badgeClockedOut(_ locale: Locale) -> String {
        t("orbit.badge.clockedOut", "Hourglass, clocked out.", locale, "Status item VoiceOver label")
    }

    static func badgeWorking(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.working", "Hourglass, clocked in, \(duration) worked today.", locale,
          "Status item VoiceOver label")
    }

    static func badgeFocus(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.focus", "Hourglass, focus, \(duration) remaining.", locale,
          "Status item VoiceOver label")
    }

    static func badgeFocusPaused(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.focusPaused", "Hourglass, focus paused, \(duration) remaining.", locale,
          "Status item VoiceOver label")
    }

    static func badgeFocusReady(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.focusReady", "Hourglass, focus ready to start, \(duration).", locale,
          "Status item VoiceOver label")
    }

    static func badgeBreakRemaining(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.break", "Hourglass, break, \(duration) remaining.", locale,
          "Status item VoiceOver label")
    }

    static func badgeBreakPaused(_ kind: SessionKind, _ duration: String, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.badge.longBreakPaused", "Hourglass, long break paused, \(duration) remaining.",
                locale, "Status item VoiceOver label")
            : t("orbit.badge.shortBreakPaused", "Hourglass, short break paused, \(duration) remaining.",
                locale, "Status item VoiceOver label")
    }

    static func badgeBreakReady(_ kind: SessionKind, _ duration: String, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.badge.longBreakReady", "Hourglass, long break ready to start, \(duration).",
                locale, "Status item VoiceOver label")
            : t("orbit.badge.shortBreakReady", "Hourglass, short break ready to start, \(duration).",
                locale, "Status item VoiceOver label")
    }

    static func badgeBreakElapsed(_ duration: String, _ locale: Locale) -> String {
        t("orbit.badge.breakElapsed", "Hourglass, break, \(duration) elapsed.", locale,
          "Status item VoiceOver label")
    }

    // MARK: Workday details

    static func detailWorkedToday(_ locale: Locale) -> String {
        t("orbit.detail.workedToday", "Worked today", locale, "Workday details row")
    }

    static func detailClockedIn(_ locale: Locale) -> String {
        t("orbit.detail.clockedIn", "Clocked in", locale, "Workday details row")
    }

    static func detailBreakSource(_ locale: Locale) -> String {
        t("orbit.detail.breakSource", "Break source", locale, "Workday details row")
    }

    static func detailBreakElapsed(_ locale: Locale) -> String {
        t("orbit.detail.breakElapsed", "Break elapsed", locale, "Workday details row")
    }

    static func detailYesterday(_ locale: Locale) -> String {
        t("orbit.detail.yesterday", "Yesterday", locale, "Workday details row")
    }

    static func detailLastBreak(_ locale: Locale) -> String {
        t("orbit.detail.lastBreak", "Last break", locale, "Workday details row")
    }

    static func sourcePomodoro(_ kind: SessionKind, _ locale: Locale) -> String {
        kind == .longBreak
            ? t("orbit.source.pomodoroLong", "Pomodoro long break", locale, "Break source")
            : t("orbit.source.pomodoroShort", "Pomodoro short break", locale, "Break source")
    }

    static func sourceManual(_ locale: Locale) -> String {
        t("orbit.source.manual", "Manual break", locale, "Break source")
    }

    static func ago(_ duration: String, _ locale: Locale) -> String {
        t("orbit.detail.ago", "\(duration) ago", locale, "Relative time")
    }

    static func notStarted(_ locale: Locale) -> String {
        t("orbit.detail.notStarted", "Not started", locale, "Workday details: the day has not begun")
    }

    // MARK: Clock-out confirmation

    static func clockOutTitle(_ locale: Locale) -> String {
        t("orbit.clockOut.title", "Clock out?", locale, "Confirmation dialog title")
    }

    static func clockOutMessage(phase: String?, endsBreak: Bool, _ locale: Locale) -> String {
        switch (phase, endsBreak) {
        case (.some(let phase), true):
            return t("orbit.clockOut.phaseAndBreak",
                     "This stops \(phase) and ends the current work break.", locale,
                     "Confirmation: what clocking out will stop")
        case (.some(let phase), false):
            return t("orbit.clockOut.phase", "This stops \(phase).", locale,
                     "Confirmation: what clocking out will stop")
        case (.none, true):
            return t("orbit.clockOut.break", "This ends the current work break.", locale,
                     "Confirmation: what clocking out will stop")
        case (.none, false):
            return t("orbit.clockOut.plain", "This ends today's workday.", locale,
                     "Confirmation: what clocking out will stop")
        }
    }

    // MARK: Assembly

    /// Joins independent clauses for a spoken summary. Kept as a localizable
    /// separator so a language that does not use a comma can change it.
    static func joinClauses(_ parts: [String], _ locale: Locale) -> String {
        let separator = t("orbit.summary.separator", ", ", locale,
                          "Separator between clauses in a VoiceOver summary")
        return parts.filter { !$0.isEmpty }.joined(separator: separator) + "."
    }

    // MARK: Lookup

    private static func t(
        _ key: StaticString,
        _ value: String.LocalizationValue,
        _ locale: Locale,
        _ comment: StaticString
    ) -> String {
        String(localized: key, defaultValue: value, bundle: .module, locale: locale, comment: comment)
    }
}
