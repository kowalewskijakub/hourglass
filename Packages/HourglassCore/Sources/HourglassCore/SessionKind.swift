import Foundation

/// The three kinds of session in a Pomodoro cycle.
public enum SessionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case focus
    case shortBreak
    case longBreak

    /// Whether this session is a break (as opposed to focused work).
    public var isBreak: Bool { self != .focus }

    /// What this phase is called wherever it is simply *named* — the state
    /// label, a History row, a Live Activity.
    ///
    /// Both break lengths answer to "Focus break": short versus long is a fact
    /// about the schedule rather than about what the user is doing, and the
    /// countdown already says how much is left.
    public var phaseName: String {
        self == .focus ? "Focus" : "Focus break"
    }

    /// The same names, with the two lengths told apart — for the two places that
    /// have to distinguish them because the user is *choosing* one: the duration
    /// settings, and the type picker in the History editor.
    public var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Focus break (short)"
        case .longBreak: return "Focus break (long)"
        }
    }

    /// A short, one-word label (useful in tight menu-bar contexts).
    public var shortName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Break"
        }
    }
}
