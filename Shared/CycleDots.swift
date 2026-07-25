import SwiftUI
import HourglassCore

/// Small dots showing progress through the current focus cycle (how many focus
/// sessions completed toward the next long break).
struct CycleDots: View {
    var completedInCycle: Int
    var total: Int
    var tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, total), id: \.self) { index in
                Circle()
                    .fill(index < completedInCycle ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
