import Foundation

/// The three kinds of session in a Pomodoro cycle.
public enum SessionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case focus
    case shortBreak
    case longBreak

    /// Whether this session is a break (as opposed to focused work).
    public var isBreak: Bool { self != .focus }

    /// Human-readable name for display in the UI.
    public var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
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
