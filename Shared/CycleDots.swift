import SwiftUI
import HourglassCore

/// Progress through the current focus cycle: how many focus sessions are behind
/// you, and how many stand between here and the long break.
///
/// A done dot is a filled disc in the cycle's tint; one still to come is a ring.
/// Two reasons it is a ring rather than a paler disc. The dots sit on the Orbit
/// scene, which follows the *sky* — `Color.secondary` follows the system instead,
/// so a Mac in dark mode drew near-white dots at quarter opacity onto a pale
/// daytime sky and they simply were not there. And filled-versus-hollow survives
/// being read by someone who cannot tell the two colours apart, which
/// light-tint-versus-dark-tint does not.
struct CycleDots: View {
    var completedInCycle: Int
    var total: Int
    var tint: Color

    @Environment(\.orbitPalette) private var palette

    private let diameter: CGFloat = 7

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, total), id: \.self) { index in
                if index < completedInCycle {
                    Circle()
                        .fill(tint)
                        .frame(width: diameter, height: diameter)
                } else {
                    Circle()
                        .strokeBorder(palette.inkSecondary.opacity(0.75), lineWidth: 1.3)
                        .frame(width: diameter, height: diameter)
                }
            }
        }
    }
}
