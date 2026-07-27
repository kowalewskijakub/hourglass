import SwiftUI
import HourglassCore

/// Per-session-kind colour and icon, shared across every UI surface.
extension SessionKind {
    var tint: Color {
        switch self {
        case .focus: return .indigo
        case .shortBreak: return .green
        case .longBreak: return .teal
        }
    }

    var symbolName: String {
        switch self {
        case .focus: return "apple.intelligence"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }
}

#if os(iOS)
import ActivityKit

/// How a Live Activity state reads on screen. The Lock Screen and the Dynamic
/// Island each render a subset of these, so keeping the one table stops the two
/// presentations describing the same state differently. Guarded because
/// `TimerActivityAttributes` is iOS-only and this file also builds for macOS.
extension TimerActivityAttributes.ContentState {
    var title: String {
        switch mode {
        case .timer: return kind.displayName
        case .clockedIn: return "Clocked in"
        case .onBreak: return "On break"
        }
    }

    /// Shown wherever there is no progress bar to explain what the clock is
    /// counting.
    var subtitle: String {
        switch mode {
        case .timer: return kind.displayName
        case .clockedIn: return "Working — no timer running"
        case .onBreak: return "Break in progress"
        }
    }

    var symbolName: String {
        switch mode {
        case .timer: return kind.symbolName
        case .clockedIn: return "clock.badge.checkmark"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }

    var tint: Color {
        switch mode {
        case .timer: return kind.tint
        case .clockedIn: return .green
        case .onBreak: return .orange
        }
    }
}
#endif
