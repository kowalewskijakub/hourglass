import SwiftUI
import HourglassCore

/// The Orbit visual system: semantic colours, type scale, and the one mapping
/// from a semantic icon to an SF Symbol.
///
/// The palette is carried in the environment rather than read from
/// `ColorScheme`, because the two are deliberately different things here: the
/// Orbit scene follows the *sky* (which may be the local sunset), while Stats,
/// History, Settings and every sheet follow the system appearance. A sunset must
/// never flip the information UI.

// MARK: - Palette

struct OrbitPalette: Equatable, Sendable {
    /// True for the night palette. Used for the few places that need to know
    /// which way round the contrast runs (star field, planet gradient).
    let isNight: Bool

    let sky: Color
    /// The second sky stop, so the day scene can carry a gradient.
    let skyEdge: Color
    let card: Color
    /// Active work, primary work controls, active arcs.
    let ember: Color
    /// The now satellite and highlights.
    let dawn: Color
    /// Planet rim only — never an interactive accent.
    let atmosphere: Color
    /// Break, paused, inactive rest.
    let stone: Color
    let ink: Color
    let inkSecondary: Color
    let hairline: Color
    /// Foreground for a filled ember/stone control.
    let onAccent: Color

    static let night = OrbitPalette(
        isNight: true,
        sky: Color(hex: 0x070A10),
        skyEdge: Color(hex: 0x0B111B),
        card: Color(hex: 0x0E1420),
        ember: Color(hex: 0xF0A33F),
        dawn: Color(hex: 0xFFD9A0),
        atmosphere: Color(hex: 0x7FB4E8),
        stone: Color(hex: 0x9B9588),
        ink: Color(hex: 0xEDF1F8),
        inkSecondary: Color(hex: 0xEDF1F8).opacity(0.60),
        hairline: Color(hex: 0xEDF1F8).opacity(0.12),
        onAccent: Color(hex: 0x211303)
    )

    static let day = OrbitPalette(
        isNight: false,
        sky: Color(hex: 0xDFE9F2),
        skyEdge: Color(hex: 0xCDDFEE),
        card: .white,
        ember: Color(hex: 0x8C4608),
        dawn: Color(hex: 0x783B06),
        atmosphere: Color(hex: 0x8CC8FF),
        stone: Color(hex: 0x665F53),
        ink: Color(hex: 0x16202E),
        inkSecondary: Color(hex: 0x16202E).opacity(0.63),
        hairline: Color(hex: 0x16202E).opacity(0.13),
        onAccent: .white
    )

    /// The palette for a surface that follows the system, not the sky.
    static func system(_ scheme: ColorScheme) -> OrbitPalette {
        scheme == .dark ? .night : .day
    }

    /// The colour a resolved tone paints *text and arcs* with — the day and
    /// night values differ because each has to hold contrast against its own sky.
    func color(_ tone: OrbitTone) -> Color {
        switch tone {
        case .ember: return ember
        case .stone: return stone
        case .dim: return inkSecondary
        }
    }

    /// The colour a *filled* control paints with, which deliberately does not
    /// change with the sky.
    ///
    /// The day ember token is a dark brown chosen to stay legible as text on a
    /// pale sky; used as a button fill it turns the same button into a different
    /// object at sunrise. Clock in should be the one recognisable colour all day,
    /// so filled controls keep the brand ember and stone and take dark ink.
    static func fill(_ tone: OrbitTone) -> Color {
        switch tone {
        case .ember: return Color(hex: 0xF0A33F)
        case .stone: return Color(hex: 0x9B9588)
        case .dim: return Color(hex: 0x9B9588)
        }
    }

    /// Ink on top of `fill(_:)`. Dark in both skies, because the fill is.
    static let onFill = Color(hex: 0x211303)
}

private struct OrbitPaletteKey: EnvironmentKey {
    static let defaultValue = OrbitPalette.night
}

extension EnvironmentValues {
    var orbitPalette: OrbitPalette {
        get { self[OrbitPaletteKey.self] }
        set { self[OrbitPaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Type scale

/// The Orbit type scale. Every numeral is monospaced-digit so a countdown does
/// not shuffle sideways as it ticks; sizes scale with Dynamic Type through
/// `ScaledMetric` at the call sites that can afford to grow.
enum OrbitType {
    static func numeral(_ kind: NumeralKind, surface: OrbitSurface) -> Font {
        let size: CGFloat
        switch (kind, surface) {
        case (.countdown, .phone), (.frozenCountdown, .phone):
            size = 64
        case (.workedToday, .phone):
            size = 48
        case (.breakElapsed, .phone):
            size = 56
        case (.wallClock, .phone):
            size = 55
        case (.countdown, .panel), (.frozenCountdown, .panel):
            size = 42
        case (.workedToday, .panel):
            size = 33
        case (.breakElapsed, .panel), (.wallClock, .panel):
            size = 38
        }
        return .system(size: size, weight: .semibold).monospacedDigit()
    }

    static func stateLabel(_ surface: OrbitSurface) -> Font {
        .system(size: surface == .phone ? 11 : 10, weight: .bold)
    }

    /// The tracking the state label carries (+0.18em on the phone).
    static func stateLabelTracking(_ surface: OrbitSurface) -> CGFloat {
        surface == .phone ? 2.0 : 1.6
    }

    static func pill(_ surface: OrbitSurface) -> Font {
        .system(size: surface == .phone ? 11.5 : 10.5, weight: .semibold)
    }

    static let railPrimary = Font.system(size: 12, weight: .semibold)
    static let railSecondary = Font.system(size: 10.5)
    static let actionTitle = Font.system(size: 14, weight: .bold)
    static let panelActionTitle = Font.system(size: 12, weight: .bold)
}

// MARK: - Icons

extension OrbitIcon {
    /// SF Symbols only in the app; the HTML reference uses vector stand-ins.
    var symbolName: String {
        switch self {
        case .focus: return "target"
        case .cup: return "cup.and.saucer"
        case .clock: return "clock"
        case .pause: return "pause.fill"
        case .play: return "play.fill"
        case .restart: return "arrow.counterclockwise"
        // Chevrons rather than skip-to-end marks: these move freely in both
        // directions, and every one of them names its destination out loud.
        case .previous: return "chevron.left"
        case .next: return "chevron.right"
        case .clockIn: return "arrow.up.to.line"
        case .clockOut: return "rectangle.portrait.and.arrow.right"
        // Distinct from clock out: one stops the timer, the other ends the day.
        case .endPomodoro: return "stop.circle"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        case .overflow: return "ellipsis"
        case .details: return "list.bullet"
        case .history: return "clock.arrow.circlepath"
        // Distinct from `play`: on the staged-break panel this sits beside
        // "Start break timer", and two play triangles side by side say nothing
        // about which one leaves the break.
        case .backToWork: return "arrow.uturn.backward"
        }
    }
}

// MARK: - Surfaces

/// The glass used by HUD chrome over the scene, with an opaque fallback when
/// Reduce Transparency is on — the borders and hierarchy survive either way.
struct OrbitGlass<S: Shape>: ViewModifier {
    let shape: S
    var strokeOpacity: Double = 1

    @Environment(\.orbitPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(palette.card)
                } else {
                    shape.fill(palette.card.opacity(palette.isNight ? 0.76 : 0.75))
                        .background(shape.fill(.ultraThinMaterial))
                }
            }
            .overlay(shape.stroke(palette.hairline.opacity(strokeOpacity), lineWidth: 1))
            .clipShape(shape)
    }
}

/// The surface every *information* screen sits on — Stats, History, Settings.
///
/// One flat page in one colour, with cards and hairlines doing the separating.
/// The grouped-list grey each of these used by default made three screens that
/// were plainly not from the same app as the panel next to them.
struct OrbitInformationSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = OrbitPalette.system(colorScheme)
        content
            .scrollContentBackground(.hidden)
            .background(palette.card.ignoresSafeArea())
    }
}

extension View {
    /// Glass chrome over the Orbit scene.
    func orbitGlass(in shape: some Shape = Capsule(), strokeOpacity: Double = 1) -> some View {
        modifier(OrbitGlass(shape: shape, strokeOpacity: strokeOpacity))
    }

    /// The shared page surface for Stats, History and Settings.
    func orbitInformationSurface() -> some View {
        modifier(OrbitInformationSurface())
    }

    /// Marks decorative scene layers so VoiceOver never asks the user to explore
    /// a planet.
    func orbitDecoration() -> some View {
        accessibilityHidden(true)
    }
}
