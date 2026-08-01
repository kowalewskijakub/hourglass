import SwiftUI
import HourglassCore

/// One line, one icon, one fact the rest of the face is not already showing.
///
/// The copy is chosen for the space available: the full wording when it fits,
/// the approved compact wording when it does not. Whichever is drawn, the full
/// meaning is what VoiceOver reads — nothing is lost by shortening. At
/// accessibility text sizes the pill gets the whole width, and if even the
/// compact copy cannot fit meaningfully it is dropped from the face rather than
/// truncated into nonsense; the fact still lives in VoiceOver and in Workday
/// details.
struct ContextPill: View {
    let pill: ContextPillPresentation
    var surface: OrbitSurface = .phone

    @Environment(\.orbitPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private var tint: Color { palette.color(pill.tone) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsule(pill.full)
            capsule(pill.compact)
            // Neither wording fits — at an accessibility text size on a narrow
            // phone, say. Rather than truncate the copy into something that
            // reads as noise, the visual pill drops to its icon and the whole
            // fact survives in the accessibility label below.
            capsule(nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pill.accessibilityLabel)
    }

    private func capsule(_ copy: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pill.icon.symbolName)
                .font(.system(size: surface == .phone ? 12 : 11, weight: .semibold))
            if let copy {
                Text(copy)
                    .font(OrbitType.pill(surface))
                    .lineLimit(1)
                    // A last small adjustment only — never a squeeze that turns
                    // the copy into a grey smudge.
                    .minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .frame(height: pillHeight)
        .orbitGlass(in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
    }

    /// Grows with Dynamic Type so the one line stays legible rather than clipped.
    private var pillHeight: CGFloat {
        let base: CGFloat = surface == .phone ? 31 : 28
        return typeSize.isAccessibilitySize ? base * 1.45 : base
    }
}

/// The pill row. Enforces the per-surface maximum in the view as well as the
/// resolver, so no future call site can slip a third pill onto the phone.
struct ContextPillRow: View {
    let pills: [ContextPillPresentation]
    var surface: OrbitSurface = .phone

    private var limit: Int { surface == .phone ? 1 : 2 }

    var body: some View {
        HStack(spacing: surface == .phone ? 6 : 7) {
            ForEach(pills.prefix(limit)) { pill in
                ContextPill(pill: pill, surface: surface)
            }
        }
    }
}
