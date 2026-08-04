import SwiftUI
import HourglassCore

/// The shared vocabulary of the three *information* screens — Stats, History and
/// Settings.
///
/// These follow the system appearance rather than the sky (see
/// `OrbitInformationSurface`), and they are built from one card, one row and one
/// chip so that switching between them reads as moving around one app rather
/// than as three screens that happen to ship together. Settings in particular
/// used to be a stock grouped `Form`, which on the Mac is a different visual
/// language from the cards next door.

// MARK: - Card

/// A titled panel on the information surface: heavy micro-caps title, optional
/// accessory on the trailing edge of the title row, hairline border, and a
/// footnote underneath for the explanation a control cannot carry itself.
struct OrbitCard<Content: View>: View {
    var title: LocalizedStringKey?
    var footnote: LocalizedStringKey?
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OrbitPalette { .system(colorScheme) }

    init(
        _ title: LocalizedStringKey? = nil,
        footnote: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.accessory = nil
        self.content = content
    }

    init(
        _ title: LocalizedStringKey?,
        accessory: some View,
        footnote: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.accessory = AnyView(accessory)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(palette.inkSecondary)
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content()
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.isNight ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - Row

/// One setting inside a card: what it is, optionally why, and the control that
/// changes it on the trailing edge.
///
/// Controls are given a consistent width so a column of steppers, toggles and
/// pickers lines up instead of each ending wherever its own label happens to.
struct OrbitFieldRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @ViewBuilder var control: () -> Control

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OrbitPalette { .system(colorScheme) }

    init(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
                .labelsHidden()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The hairline between rows inside a card.
struct OrbitRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(OrbitPalette.system(colorScheme).hairline)
            .frame(height: 1)
    }
}

// MARK: - Chip

/// The small pill used for a filter, a range or a mode — an icon, a word, and a
/// tint that says whether it is on. History's filter row is built from these,
/// and they are what keeps that row from reading as a strip of system buttons.
struct OrbitChip: View {
    let symbol: String
    let title: LocalizedStringKey
    var tint: Color
    var isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(isOn ? tint : palette.inkSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(Capsule().fill(isOn ? tint.opacity(0.15) : Color.clear))
        .overlay(Capsule().stroke(isOn ? tint.opacity(0.5) : palette.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// A chip that acts: same shape as `OrbitChip`, but it reads as pressable
/// because it carries the ember the rest of the app uses for "do this".
struct OrbitChipButton: View {
    let symbol: String
    let title: LocalizedStringKey
    var tint: Color = .orbitEmber
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OrbitChip(symbol: symbol, title: title, tint: tint, isOn: isOn)
        }
        .buttonStyle(.plain)
    }
}
