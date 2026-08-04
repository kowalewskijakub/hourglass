import Foundation

/// Everything the Orbit surfaces draw, resolved once from the two state axes.
///
/// Views render this and nothing else. They must not re-derive a label, a badge
/// mark, Break eligibility or what a number means — that is the whole point of
/// having one resolver: the phone, the panel, the menu-bar item and the Live
/// Activity cannot drift into telling the user three different things.

// MARK: - Vocabulary

/// The two working colours. Ember is work; stone is rest, pause and inactivity.
/// Atmosphere blue is a scene colour only and never an interactive accent.
public enum OrbitTone: String, Equatable, Sendable {
    case ember
    case stone
    /// Inactive: clocked out, nothing recording.
    case dim
}

/// A semantic icon. Mapped to SF Symbols on the UI side so the core stays free
/// of platform symbol names.
public enum OrbitIcon: String, Equatable, Sendable {
    case focus
    case cup
    case clock
    case pause
    case play
    case restart
    case previous
    case next
    /// Moving on from a finished phase. A tick rather than an arrow: by the
    /// time this button appears the phase is already over, so the gesture is
    /// acknowledging it rather than skipping anything — and a tick cannot be
    /// mistaken for the transport chevrons it replaces on screen.
    case continueOn
    case clockIn
    case clockOut
    case endPomodoro
    case stats
    case settings
    case overflow
    case details
    case history
    case backToWork
}

/// What the big number means. Views use it to pick a type size and to phrase
/// the accessible reading; nothing else may reinterpret it.
public enum NumeralKind: String, Equatable, Sendable {
    /// Time remaining in a bounded phase.
    case countdown
    /// Time remaining in a bounded phase that is not advancing.
    case frozenCountdown
    /// Net worked time today.
    case workedToday
    /// How long the current open-ended break has run.
    case breakElapsed
    /// How far a finished phase has run past its planned end.
    case overrun
    /// The current wall-clock time.
    case wallClock
}

public struct NumeralPresentation: Equatable, Sendable {
    public let text: String
    public let kind: NumeralKind
    public let tone: OrbitTone
    /// The spoken form, which says what the number *means* — "24 minutes 53
    /// seconds remaining", not "twenty-four fifty-three".
    public let accessibilityLabel: String
}

public struct CycleDotsPresentation: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    /// The colour the done dots take. It follows the phase the user is *in*
    /// rather than the cycle in the abstract — ember while working, stone while
    /// resting — so the row beside the state label does not go on insisting the
    /// screen is about work in the middle of a break.
    public let tone: OrbitTone
    public let accessibilityLabel: String
}

/// One line, one icon, one fact that is *not* already on screen.
///
/// `compact` is the shorter wording used when the full copy will not fit on one
/// line; `accessibilityLabel` always carries the full meaning, so nothing is
/// lost when the compact form is shown.
public struct ContextPillPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let icon: OrbitIcon
    public let full: String
    public let compact: String
    public let accessibilityLabel: String
    public let tone: OrbitTone

    public init(
        id: String,
        icon: OrbitIcon,
        full: String,
        compact: String,
        accessibilityLabel: String,
        tone: OrbitTone
    ) {
        self.id = id
        self.icon = icon
        self.full = full
        self.compact = compact
        self.accessibilityLabel = accessibilityLabel
        self.tone = tone
    }
}

/// The persistent workday status surface.
///
/// It carries exactly one inline action, and which one depends on what the user
/// would actually want next: Break while simply working, Restart while a focus
/// phase is in play, Back to work while a Pomodoro break is running. One slot,
/// so the rail never becomes a second-level menu.
public struct WorkdayRailPresentation: Equatable, Sendable {
    public let primary: String
    public let secondary: String
    public let tone: OrbitTone
    /// Nil when the state has nothing worth offering here.
    public let inlineAction: LabeledAction?
    public let accessibilityLabel: String
}

/// Clocking out: the label, and what the confirmation must say it will stop.
public struct ClockOutPresentation: Equatable, Sendable {
    /// Hidden when there is no open workday to end.
    public let isAvailable: Bool
    public let title: String
    public let confirmationTitle: String
    /// Names exactly what stopping now will end.
    public let confirmationMessage: String
    /// True when the action must confirm before it runs.
    public let needsConfirmation: Bool
}

/// Everything a control can ask the app to do. Deliberately named after the
/// user's intent rather than the engine call, so one action can mean "end the
/// linked work break *and* start the next focus" without the view knowing.
public enum OrbitAction: String, Equatable, Sendable {
    case clockIn
    case startFocus
    case startBreak
    case startPhase
    case backToWork
    case restartPhase
    case pause
    case resume
    /// Leave the timer without ending the working day. Also reachable from the
    /// overflow menu; it is an action in its own right because the Mac footer
    /// offers it directly, beside Restart.
    case endPomodoro
    /// Move on from a phase that has run past its end. Nothing else does: a
    /// finished phase keeps counting until the user says they are done with it.
    case continuePhase
    /// Move back through the cycle. Never exposed as a bare chevron: the
    /// control names the phase it is going to.
    case previousPhase
    case nextPhase
}

public struct LabeledAction: Equatable, Sendable {
    public let action: OrbitAction
    /// The visible label. Empty for icon-only controls, which still carry a
    /// full `accessibilityLabel`.
    public let title: String
    public let icon: OrbitIcon
    public let tone: OrbitTone
    public let accessibilityLabel: String

    public init(
        action: OrbitAction,
        title: String = "",
        icon: OrbitIcon,
        tone: OrbitTone,
        accessibilityLabel: String
    ) {
        self.action = action
        self.title = title
        self.icon = icon
        self.tone = tone
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Free movement through the cycle: back · start/pause/resume · forward.
///
/// Each arrow names the phase it lands on, in its label and its tooltip, so the
/// pair is never the unexplained previous/next chevrons the design brief warns
/// about. Restart is not here — it sits in the rail's single action slot, where
/// it does not compete with the phase the user is actually in.
public struct TransportPresentation: Equatable, Sendable {
    public let previous: LabeledAction
    public let playPause: LabeledAction
    public let next: LabeledAction
}

/// Where a surface with more than one place to put controls should draw the
/// single labelled action.
///
/// Only the Mac panel has the choice — it has both a control well over the scene
/// and a footer. The phone has one control area and ignores this.
public enum OrbitPrimaryPlacement: String, Equatable, Sendable {
    /// Over the scene, as the one thing on an otherwise empty screen.
    case hero
    /// In the footer, alongside the other controls of a day already under way.
    case footer
}

public enum OrbitControlsPresentation: Equatable, Sendable {
    /// A Pomodoro phase of any kind: three circular transport controls.
    case transport(TransportPresentation)
    /// One labelled pill — the single next action.
    case primary(LabeledAction)

    /// Flattened, in focus order, for keyboard and VoiceOver traversal.
    public var allActions: [LabeledAction] {
        switch self {
        case .transport(let transport):
            return [transport.previous, transport.playPause, transport.next]
        case .primary(let action):
            return [action]
        }
    }
}

/// How the Orbit scene reads. The workday trace and the phase emphasis are
/// separate: a paused focus does not pause the workday, so the trace stays
/// ember while the phase itself cools.
public enum OrbitSceneMode: String, Equatable, Sendable {
    /// Work is being recorded; the satellite pulses.
    case recording
    /// Work is being recorded but the bounded phase is frozen; no pulse.
    case paused
    /// No work is accumulating — a break of either source.
    case resting
    /// Clocked out.
    case inactive

    public var isRecording: Bool { self == .recording }
}

// MARK: - Menu bar

/// Fill says bounded vs open-ended; colour says work vs rest; the pause mark is
/// its own shape so state never depends on colour alone.
public enum MenuBarMark: String, Equatable, Sendable {
    case solidEmber
    case hollowEmber
    case solidStone
    case hollowStone
    case pause
    case dim
}

/// How often the status item needs redrawing in this state. A frozen phase must
/// not tick, and a clocked-out item must not schedule anything at all.
public enum MenuBarCadence: String, Equatable, Sendable {
    case second
    case minute
    case none
}

public struct MenuBarBadgePresentation: Equatable, Sendable {
    public let mark: MenuBarMark
    /// Nil when there is nothing running to report.
    public let value: String?
    public let cadence: MenuBarCadence
    public let accessibilityLabel: String
}

// MARK: - Overflow

public enum OrbitOverflowAction: String, Equatable, Sendable, Identifiable, CaseIterable {
    case restartPhase
    /// Leave Pomodoro without ending the working day — the workday is the
    /// spine, and finishing with the timer is not the same as going home.
    case endPomodoro
    case history
    case settings
    case clockOut

    public var id: String { rawValue }

    /// Clock out is destructive and always sits below a separator.
    public var isDestructive: Bool { self == .clockOut }
}

/// One overflow entry, already titled, so a menu never re-derives copy.
public struct OverflowItem: Equatable, Sendable, Identifiable {
    public let action: OrbitOverflowAction
    public let title: String
    public let icon: OrbitIcon

    public var id: String { action.rawValue }
    public var isDestructive: Bool { action.isDestructive }
}

// MARK: - The resolved presentation

public struct OrbitPresentation: Equatable, Sendable {
    public let stateLabel: String
    public let stateTone: OrbitTone
    public let numeral: NumeralPresentation
    public let cycleDots: CycleDotsPresentation?
    public let contextPills: [ContextPillPresentation]
    public let workdayRail: WorkdayRailPresentation?
    public let clockOut: ClockOutPresentation
    /// Leaving the timer, promoted out of the overflow menu on the surface that
    /// has a footer to put it in. Nil when there is no Pomodoro to leave, and
    /// nil on the phone — there it stays in the overflow, which is the only
    /// menu that surface has.
    public let endPomodoro: LabeledAction?
    public let controls: OrbitControlsPresentation
    /// Where a `.primary` action belongs on a surface that has a choice. Once
    /// the day is under way its actions gather in the footer; only the action
    /// that *starts* the day keeps the empty screen to itself.
    public let primaryPlacement: OrbitPrimaryPlacement
    public let sceneMode: OrbitSceneMode
    public let menuBarBadge: MenuBarBadgePresentation
    public let overflowActions: [OverflowItem]
    public let accessibilitySummary: String
    /// The one rule the manual Break action obeys: clocked in, working, and no
    /// Pomodoro phase of any kind. Hidden — not disabled — everywhere else.
    public let canStartManualBreak: Bool
    /// True when stopping now would abandon a phase or an open break, so clock
    /// out must say what it is about to end.
    public let clockOutNeedsConfirmation: Bool
}
