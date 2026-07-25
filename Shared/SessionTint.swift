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
