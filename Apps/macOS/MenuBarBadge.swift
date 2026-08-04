import SwiftUI
import HourglassCore

/// The one Hourglass status item: a mark and, when something is running, a value.
///
/// The grammar is deliberately small and never depends on colour alone —
/// **fill** says bounded versus open-ended, **colour** says work versus rest, and
/// the pause mark is its own shape. There is no persistent border and no filled
/// capsule; the item takes the normal menu-bar hover and pressed highlight.
struct MenuBarBadge: View {
    let badge: MenuBarBadgePresentation
    /// Menu-bar glyphs read against the desktop, not against a card, so the ink
    /// follows the bar's own appearance rather than the Orbit sky.
    let isDarkMenuBar: Bool

    // Exactly the tokens the rest of the app paints with — `Color.orbitEmber`
    // and `Color.orbitStone`, resolved by hand for the *menu bar's* appearance
    // rather than the window's. They used to be a separate pair of hexes, tuned
    // in isolation, and the result was a status item in a slightly different
    // orange from the panel that drops down beneath it.
    private var ember: Color { Color(hex: isDarkMenuBar ? 0xF0A33F : 0x8C4608) }
    private var stone: Color { Color(hex: isDarkMenuBar ? 0x9B9588 : 0x665F53) }
    private var dim: Color { (isDarkMenuBar ? Color.white : Color.black).opacity(0.42) }

    var body: some View {
        HStack(spacing: 5) {
            mark
            if let value = badge.value {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDarkMenuBar ? Color.white : Color.black)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var mark: some View {
        switch badge.mark {
        case .solidEmber:
            Circle().fill(ember).frame(width: 8, height: 8)
        case .hollowEmber:
            Circle().stroke(ember, lineWidth: 1.8).frame(width: 8, height: 8)
        case .solidStone:
            Circle().fill(stone).frame(width: 8, height: 8)
        case .hollowStone:
            Circle().stroke(stone, lineWidth: 1.8).frame(width: 8, height: 8)
        case .pause:
            // A shape of its own, so "frozen" is distinguishable from "resting"
            // without seeing the difference between ember and stone.
            HStack(spacing: 2) {
                Capsule().fill(stone).frame(width: 3, height: 10)
                Capsule().fill(stone).frame(width: 3, height: 10)
            }
        case .dim:
            Circle().stroke(dim, lineWidth: 1.8).frame(width: 8, height: 8)
        }
    }
}
