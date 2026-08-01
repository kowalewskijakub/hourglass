import SwiftUI
import HourglassCore

/// A colour that resolves against the system appearance, for the surfaces that
/// follow it (History, Stats, editors) rather than the Orbit sky.
extension Color {
    static func orbitDynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #endif
    }

    /// Active work: focus sessions, the current arc, primary work controls.
    static let orbitEmber = Color.orbitDynamic(light: 0x8C4608, dark: 0xF0A33F)
    /// Rest, pause and inactivity — including *every* work break, whether a
    /// Pomodoro phase opened it or the user did.
    static let orbitStone = Color.orbitDynamic(light: 0x665F53, dark: 0x9B9588)
    /// Highlights and the now marker.
    static let orbitDawn = Color.orbitDynamic(light: 0x783B06, dark: 0xFFD9A0)
}

/// Two colours, not five. A break is a break: collapsing short and long onto one
/// stone is what lets History, the totals and the Orbit trace agree that the
/// user was resting, without asking anyone to learn a palette.
extension SessionKind {
    var tint: Color {
        self == .focus ? .orbitEmber : .orbitStone
    }

    var symbolName: String {
        self == .focus ? OrbitIcon.focus.symbolName : OrbitIcon.cup.symbolName
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
        case .onBreak: return "Work break"
        }
    }

    /// Shown wherever there is no progress bar to explain what the clock is
    /// counting.
    var subtitle: String {
        switch mode {
        case .timer: return kind.displayName
        case .clockedIn: return "Working — no timer running"
        case .onBreak: return "Excluded from work total"
        }
    }

    var symbolName: String {
        switch mode {
        case .timer: return kind.symbolName
        case .clockedIn: return OrbitIcon.clock.symbolName
        case .onBreak: return OrbitIcon.cup.symbolName
        }
    }

    /// Ember for active work, stone for a break or a pause — the same two
    /// colours every other surface uses.
    var tint: Color {
        switch mode {
        case .timer: return isRunning ? kind.tint : .orbitStone
        case .clockedIn: return .orbitEmber
        case .onBreak: return .orbitStone
        }
    }

    /// The compact mark, reusing the menu-bar grammar: fill says bounded versus
    /// open-ended, colour says work versus rest.
    var compactMark: MenuBarMark {
        switch mode {
        case .timer:
            if !isRunning { return .pause }
            return kind.isBreak ? .solidStone : .solidEmber
        case .clockedIn:
            return .hollowEmber
        case .onBreak:
            return .hollowStone
        }
    }
}
#endif
