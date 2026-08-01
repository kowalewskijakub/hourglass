import SwiftUI
import HourglassCore

/// The primary controls: either the cycle transport for a Pomodoro phase, or one
/// labelled pill for the single next action.
///
/// The two arrows move freely through the cycle. Each names the phase it lands
/// on — in its tooltip and its VoiceOver label — so the pair is never a bare
/// previous/next chevron with nothing to say. Restart is deliberately not here;
/// it lives in the workday rail's single action slot.
struct OrbitControlsView: View {
    let controls: OrbitControlsPresentation
    var surface: OrbitSurface = .phone
    let perform: (OrbitAction) -> Void

    @Environment(\.orbitPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: surface == .phone ? 14 : 9) {
            switch controls {
            case .transport(let transport):
                circular(transport.previous, prominent: false)
                circular(transport.playPause, prominent: true)
                circular(transport.next, prominent: false)

            case .primary(let action):
                labelled(action)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: controls)
    }

    // MARK: Shapes

    private var smallSize: CGFloat { surface == .phone ? 48 : 34 }
    private var mainSize: CGFloat { surface == .phone ? 70 : 50 }

    private func circular(_ action: LabeledAction, prominent: Bool) -> some View {
        let size = prominent ? mainSize : smallSize
        return Button { perform(action.action) } label: {
            Image(systemName: action.icon.symbolName)
                .font(.system(size: prominent ? 20 : 17, weight: .semibold))
                .foregroundStyle(prominent ? OrbitPalette.onFill : palette.inkSecondary)
                // Play and pause swap in place rather than cross-dissolving.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background {
                    if prominent {
                        Circle()
                            .fill(OrbitPalette.fill(action.tone))
                            .shadow(color: OrbitPalette.fill(action.tone).opacity(0.42),
                                    radius: 16, y: 0)
                    }
                }
                .modifier(ChromeIfNeeded(prominent: prominent))
                // The drawn circle can be smaller than the target the guidelines
                // ask for; the hit area is not.
                .frame(minWidth: minimumTarget, minHeight: minimumTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action.accessibilityLabel))
        .help(action.accessibilityLabel)
    }

    private func labelled(_ action: LabeledAction) -> some View {
        Button { perform(action.action) } label: {
            HStack(spacing: 9) {
                Image(systemName: action.icon.symbolName)
                    .font(.system(size: surface == .phone ? 15 : 13, weight: .bold))
                Text(action.title)
                    .font(surface == .phone ? OrbitType.actionTitle : OrbitType.panelActionTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // One action colour in both skies, so Clock in is the same button at
            // nine in the morning and at nine at night.
            .foregroundStyle(OrbitPalette.onFill)
            .padding(.horizontal, surface == .phone ? 25 : 15)
            .frame(minHeight: surface == .phone ? 56 : 42)
            .background {
                Capsule()
                    .fill(OrbitPalette.fill(action.tone))
                    .shadow(color: OrbitPalette.fill(action.tone).opacity(0.35), radius: 18)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action.accessibilityLabel))
    }

    private var minimumTarget: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    /// Glass chrome only on the secondary controls; the prominent one is a solid
    /// ember or stone disc.
    private struct ChromeIfNeeded: ViewModifier {
        let prominent: Bool

        func body(content: Content) -> some View {
            if prominent {
                content
            } else {
                content.orbitGlass(in: Circle())
            }
        }
    }
}

/// The workday rail's inline action, and the macOS footer's. One slot whose
/// meaning changes with state — Break, Restart, or Back to work — drawn the same
/// way in both places so it reads as one control.
struct OrbitInlineActionButton: View {
    let action: LabeledAction
    var surface: OrbitSurface = .phone
    let perform: (OrbitAction) -> Void

    @Environment(\.orbitPalette) private var palette

    private var tint: Color { palette.color(action.tone) }

    var body: some View {
        Button { perform(action.action) } label: {
            Label(action.title, systemImage: action.icon.symbolName)
                .font(.system(size: surface == .phone ? 11.5 : 11, weight: .heavy))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                // 44 pt of target on the phone even though the capsule is drawn
                // smaller, which a 38 pt pill alone would fail.
                .frame(minWidth: surface == .phone ? 44 : 28,
                       minHeight: surface == .phone ? 44 : 34)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(tint.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.vertical, surface == .phone ? 3 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action.accessibilityLabel))
        .help(action.accessibilityLabel)
    }
}
