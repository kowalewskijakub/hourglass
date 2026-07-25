import SwiftUI
import HourglassCore

/// The Flow-style menu-bar badge: the remaining `mm:ss` inside a rounded
/// rectangle with a neutral border and a small colour dot indicating the session
/// kind. No filled background. Rendered to an `NSImage` each tick.
struct MenuBarBadge: View {
    let time: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(time)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.primary.opacity(0.35), lineWidth: 1)
        )
    }
}
