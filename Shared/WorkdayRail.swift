import SwiftUI
import HourglassCore

/// The persistent workday status surface beneath the contextual pill.
///
/// A status surface with exactly one action in it — Break while simply working,
/// Restart while a focus phase is in play, Back to work while a Pomodoro break
/// is running. Which one appears is the resolver's decision, not the view's, and
/// the slot is empty rather than disabled when none of them applies.
struct WorkdayRail: View {
    let rail: WorkdayRailPresentation
    let perform: (OrbitAction) -> Void

    @Environment(\.orbitPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(palette.color(rail.tone))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(rail.primary)
                    .font(OrbitType.railPrimary)
                    .foregroundStyle(palette.ink)
                Text(rail.secondary)
                    .font(OrbitType.railSecondary)
                    .foregroundStyle(palette.inkSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rail.accessibilityLabel)

            if let action = rail.inlineAction {
                OrbitInlineActionButton(action: action, surface: .phone, perform: perform)
            }
        }
        .padding(7)
        .frame(minHeight: railHeight)
        .orbitGlass(in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    /// 48 pt minimum, growing vertically for its two status lines at larger text
    /// sizes. The action target stays 44 pt regardless.
    private var railHeight: CGFloat {
        typeSize.isAccessibilitySize ? 68 : 50
    }
}
