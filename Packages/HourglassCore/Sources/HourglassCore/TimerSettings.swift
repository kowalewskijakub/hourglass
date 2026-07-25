import Foundation

/// How the macOS app presents itself. Ignored on iOS.
public enum MacAppMode: String, Codable, Sendable, CaseIterable {
    case menuBar
    case window
}

/// User-configurable settings for the Pomodoro timer. Persisted as JSON.
public struct TimerSettings: Codable, Sendable, Equatable {
    /// Length of a focus session, in seconds.
    public var focusDuration: TimeInterval
    /// Length of a short break, in seconds.
    public var shortBreakDuration: TimeInterval
    /// Length of a long break, in seconds.
    public var longBreakDuration: TimeInterval
    /// How many focus sessions to complete before a long break.
    public var sessionsUntilLongBreak: Int
    /// Automatically start a break when a focus session finishes.
    public var autoStartBreaks: Bool
    /// Automatically start the next focus session when a break finishes.
    public var autoStartFocus: Bool
    /// Play a sound when a session finishes.
    public var soundEnabled: Bool
    /// Deliver a system notification when a session finishes.
    public var notificationsEnabled: Bool
    /// macOS: present as a menu-bar app or a floating window.
    public var macAppMode: MacAppMode
    /// macOS window mode: keep the window above other windows.
    public var macKeepWindowOnTop: Bool

    public init(
        focusDuration: TimeInterval = 25 * 60,
        shortBreakDuration: TimeInterval = 5 * 60,
        longBreakDuration: TimeInterval = 15 * 60,
        sessionsUntilLongBreak: Int = 4,
        autoStartBreaks: Bool = false,
        autoStartFocus: Bool = false,
        soundEnabled: Bool = true,
        notificationsEnabled: Bool = true,
        macAppMode: MacAppMode = .menuBar,
        macKeepWindowOnTop: Bool = false
    ) {
        self.focusDuration = focusDuration
        self.shortBreakDuration = shortBreakDuration
        self.longBreakDuration = longBreakDuration
        self.sessionsUntilLongBreak = max(1, sessionsUntilLongBreak)
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
        self.soundEnabled = soundEnabled
        self.notificationsEnabled = notificationsEnabled
        self.macAppMode = macAppMode
        self.macKeepWindowOnTop = macKeepWindowOnTop
    }

    /// The default Pomodoro configuration (25 / 5 / 15, long break every 4).
    public static let `default` = TimerSettings()

    /// The configured duration for a given session kind.
    public func duration(for kind: SessionKind) -> TimeInterval {
        switch kind {
        case .focus: return focusDuration
        case .shortBreak: return shortBreakDuration
        case .longBreak: return longBreakDuration
        }
    }

    // Decodes tolerantly so older/partial payloads still load with defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TimerSettings.default
        focusDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .focusDuration) ?? d.focusDuration
        shortBreakDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .shortBreakDuration) ?? d.shortBreakDuration
        longBreakDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .longBreakDuration) ?? d.longBreakDuration
        sessionsUntilLongBreak = try c.decodeIfPresent(Int.self, forKey: .sessionsUntilLongBreak) ?? d.sessionsUntilLongBreak
        autoStartBreaks = try c.decodeIfPresent(Bool.self, forKey: .autoStartBreaks) ?? d.autoStartBreaks
        autoStartFocus = try c.decodeIfPresent(Bool.self, forKey: .autoStartFocus) ?? d.autoStartFocus
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        macAppMode = try c.decodeIfPresent(MacAppMode.self, forKey: .macAppMode) ?? d.macAppMode
        macKeepWindowOnTop = try c.decodeIfPresent(Bool.self, forKey: .macKeepWindowOnTop) ?? d.macKeepWindowOnTop
    }
}
