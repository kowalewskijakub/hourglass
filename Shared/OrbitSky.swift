import SwiftUI
import HourglassCore

/// The sky over the Orbit scene at one moment: which phase of the day it is, the
/// colours that phase paints, and where the sun stands relative to the face the
/// viewer is looking at.
///
/// This is the seam that turned the scene from two states into a day. Day and
/// night are the only parts of a day a scene *cannot* make anything of;
/// everything worth looking at — the blue hour, the rose of a sunrise, the long
/// gold of an evening — happens in between, and all of it is a smooth function of
/// one number: how high the sun is.
///
/// Kept as a value so the scene stays a pure function of its inputs. The same
/// instant and coordinate always draw the same sky, which is what makes a dawn
/// something you can render on demand rather than wait until morning to see. The
/// instant is taken down to the minute: a sky that changes materially over half
/// an hour has nothing to say about the second, and pinning it there keeps the
/// value equal to itself between ticks so SwiftUI has nothing to redo.
struct OrbitSky: Equatable {
    /// The named stretch of the day. Drives nothing on its own — the colours
    /// below are continuous — but it is what makes the sky describable.
    let phase: SolarPhase
    /// The sun's elevation at the viewer, in degrees.
    let altitude: Double
    /// The sun's declination, carried so the scene can sweep a terminator.
    let declination: Double
    /// Degrees turned past the viewer's solar noon, 15° to the hour.
    let hourAngle: Double
    /// Where the viewer stands. The scene centres the globe on this meridian and
    /// this parallel, so the face below is the part of the world they are in.
    let latitude: Double
    let longitude: Double
    /// False for the two fixed skies. Always day and Always night are settings,
    /// not moments, so nothing about them may sweep or drift with the clock.
    let followsTheSun: Bool

    private let tint: Tint

    /// Above this elevation the sky is light enough to carry dark ink, so the
    /// chrome swaps.
    ///
    /// Above the horizon rather than at it, and the exact figure is measured
    /// rather than chosen: it is where the two inks' contrast against the sky
    /// crosses over. A sunrise sky passes through a mid slate that neither ink
    /// is comfortable on, so the most legible thing the scene can do is switch at
    /// the crossing — never below 4:1, against 3.1:1 for a flip at the horizon.
    static let inkFlipAltitude: Double = 2

    /// Where the two fixed skies stand the sun: a high noon and a deep night.
    private static let fixedDayAltitude: Double = 45
    private static let fixedNightAltitude: Double = -30

    init(
        at instant: Date,
        coordinate: SolarClock.Coordinate?,
        mode: SkyMode,
        calendar: Calendar = .current
    ) {
        let minute = Date(
            timeIntervalSinceReferenceDate:
                (instant.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        )
        let place = coordinate ?? SolarClock.fallbackCoordinate(for: calendar.timeZone, at: minute)
        let position = SolarClock.position(at: minute, coordinate: place)

        latitude = place.latitude
        longitude = place.longitude
        declination = position.declination

        switch mode {
        case .followSun:
            altitude = position.altitude
            hourAngle = position.hourAngle
            followsTheSun = true
        case .alwaysDay:
            altitude = Self.fixedDayAltitude
            hourAngle = 0
            followsTheSun = false
        case .alwaysNight:
            altitude = Self.fixedNightAltitude
            hourAngle = 180
            followsTheSun = false
        }

        phase = SolarPhase(altitude: altitude, hourAngle: hourAngle)
        tint = Tint(altitude: altitude, rising: hourAngle <= 0)
    }

    // MARK: What the sky looks like

    /// Top of the sky, the horizon, and the band between them. Three stops rather
    /// than two because the whole difference between a sunset and a blue evening
    /// lives in the middle of the gradient, not at either end of it.
    var gradient: Gradient {
        Gradient(stops: [
            .init(color: tint.zenith.color, location: 0),
            .init(color: tint.middle.color, location: Self.middleStop),
            .init(color: tint.horizon.color, location: 1),
        ])
    }

    /// The sky's colour a given fraction of the way down the scene, so a layer
    /// drawn over it can match what is actually behind it.
    func color(atHeight fraction: Double) -> Color {
        let clamped = min(1, max(0, fraction))
        if clamped <= Self.middleStop {
            return tint.zenith.mixed(with: tint.middle, clamped / Self.middleStop).color
        }
        let remainder = (clamped - Self.middleStop) / (1 - Self.middleStop)
        return tint.middle.mixed(with: tint.horizon, remainder).color
    }

    /// The limb rim. Cooler and thinner at night, warm and wide around a sunrise.
    var atmosphere: Color { tint.atmosphere.color }

    /// The bloom sitting on the horizon where the sun is.
    var glow: Color { tint.glow.color }

    /// How present that bloom is: strongest within a few degrees of the horizon,
    /// gone by deep night, and a low haze while the sun is properly up.
    var glowStrength: Double {
        let closeness = max(0, 1 - abs(altitude - 1) / 14)
        return max(closeness * 0.8, phase.isSunUp ? 0.18 : 0)
    }

    /// How much of the star field shows through, 0 by day to 1 in a true night.
    var starVisibility: Double { tint.stars }

    /// Which way round the chrome's contrast runs. Named for the palette it
    /// picks, not for the sun: a civil dawn is night as far as ink is concerned.
    var isNight: Bool { altitude < Self.inkFlipAltitude }

    /// The palette the surfaces over this sky take.
    var palette: OrbitPalette { isNight ? .night : .day }

    // MARK: Where the light falls

    /// The longitude the sun is directly overhead — the other end of the hour
    /// angle. The globe needs it as a place on the sphere rather than an offset
    /// from the viewer, because the terminator it lights is drawn in the
    /// planet's own frame, not the viewer's.
    var subsolarLongitude: Double { longitude - hourAngle }

    /// The unit vector pointing at the sun, in the globe's own frame: x east
    /// through 0°, y to the north pole, z out through the prime meridian.
    var sunDirection: (x: Double, y: Double, z: Double) {
        let declination = self.declination * .pi / 180
        let longitude = subsolarLongitude * .pi / 180
        return (cos(declination) * sin(longitude),
                sin(declination),
                cos(declination) * cos(longitude))
    }

    /// How lit the face is when the sky is fixed rather than followed. Only the
    /// two settings use it; a followed sky lights every point on its own.
    var fixedIllumination: Double { phase.isSunUp ? 1 : 0.02 }

    // MARK: Interpolation

    private static let middleStop: Double = 0.58

    /// A colour as components, so two of them can be mixed. `Color` cannot be
    /// read back apart on both platforms, and every gradient here is a blend
    /// between two anchors rather than a token picked from a list.
    private struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        func mixed(with other: RGB, _ amount: Double) -> RGB {
            let t = min(1, max(0, amount))
            var mixed = self
            mixed.red += (other.red - red) * t
            mixed.green += (other.green - green) * t
            mixed.blue += (other.blue - blue) * t
            return mixed
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    }

    /// Everything the sky's colour depends on, resolved once from the sun's
    /// height and which way it is going.
    private struct Tint: Equatable {
        let zenith: RGB
        let middle: RGB
        let horizon: RGB
        let atmosphere: RGB
        let glow: RGB
        let stars: Double

        init(altitude: Double, rising: Bool) {
            let anchors = Anchor.table
            // Find the pair the sun sits between and blend across it, so the sky
            // moves continuously and no phase boundary is ever a visible step.
            var lower = anchors[0]
            var upper = anchors[anchors.count - 1]
            for (index, anchor) in anchors.enumerated() where anchor.altitude <= altitude {
                lower = anchor
                upper = anchors[min(index + 1, anchors.count - 1)]
            }
            let span = upper.altitude - lower.altitude
            let t = span > 0 ? min(1, max(0, (altitude - lower.altitude) / span)) : 0

            // Dawn and dusk stand at the same height and are not the same colour:
            // a morning runs rose and a little cold, an evening runs amber. The
            // bias fades out within ten degrees of the horizon either way.
            let twilight = max(0, 1 - abs(altitude) / 10) * 0.28
            let bias = RGB(rising ? 0xC0798F : 0xE08A46)

            zenith = lower.zenith.mixed(with: upper.zenith, t)
            middle = lower.middle.mixed(with: upper.middle, t)
                .mixed(with: bias, twilight * 0.4)
            horizon = lower.horizon.mixed(with: upper.horizon, t).mixed(with: bias, twilight)
            atmosphere = lower.atmosphere.mixed(with: upper.atmosphere, t)
            glow = lower.glow.mixed(with: upper.glow, t).mixed(with: bias, twilight)
            stars = lower.stars + (upper.stars - lower.stars) * t
        }
    }

    /// One rung of the sky, keyed to the sun's elevation.
    ///
    /// The rungs are the conventional twilight angles — −18°, −12°, −6°, the
    /// horizon — plus the two that matter to the eye rather than the almanac: the
    /// low gold around 3°, and the height at which a sky stops changing at all.
    private struct Anchor {
        let altitude: Double
        let zenith: RGB
        let middle: RGB
        let horizon: RGB
        let atmosphere: RGB
        let glow: RGB
        let stars: Double

        init(
            _ altitude: Double,
            zenith: UInt32,
            middle: UInt32,
            horizon: UInt32,
            atmosphere: UInt32,
            glow: UInt32,
            stars: Double
        ) {
            self.altitude = altitude
            self.zenith = RGB(zenith)
            self.middle = RGB(middle)
            self.horizon = RGB(horizon)
            self.atmosphere = RGB(atmosphere)
            self.glow = RGB(glow)
            self.stars = stars
        }

        /// Ordered by altitude; the blend above walks it.
        static let table: [Anchor] = [
            // Deep night — the existing night sky tokens, near enough.
            Anchor(-90, zenith: 0x05070D, middle: 0x080C14, horizon: 0x0D1422,
                   atmosphere: 0x3E6C9E, glow: 0x2A3E62, stars: 1),
            // Astronomical twilight: the first grey in the east.
            Anchor(-18, zenith: 0x06080F, middle: 0x0A0F1C, horizon: 0x121C30,
                   atmosphere: 0x4A79AC, glow: 0x3B4C74, stars: 1),
            // Nautical: the horizon separates from the sea.
            Anchor(-12, zenith: 0x0A1019, middle: 0x131D30, horizon: 0x27334F,
                   atmosphere: 0x5A8ABF, glow: 0x5D5682, stars: 0.82),
            // Civil, the blue hour — the sky's most saturated minutes.
            Anchor(-6, zenith: 0x142440, middle: 0x2E3A5E, horizon: 0x5E4F74,
                   atmosphere: 0x7FB4E8, glow: 0x9E6E88, stars: 0.4),
            // The horizon itself, allowing for refraction.
            Anchor(SolarPhase.horizonAltitude, zenith: 0x2E4C78, middle: 0x606A94,
                   horizon: 0xB4778C, atmosphere: 0x9CC8F2, glow: 0xDB9074, stars: 0.1),
            // Low gold: the sun clear of the horizon and still on the ground.
            Anchor(3, zenith: 0x507DAE, middle: 0x8FA0C2, horizon: 0xE3AC7E,
                   atmosphere: 0xB4D8F7, glow: 0xF3AB6C, stars: 0),
            // The end of the golden hour.
            Anchor(9, zenith: 0x81ACD4, middle: 0xB6CAE0, horizon: 0xF1D1A6,
                   atmosphere: 0xC7E1F8, glow: 0xF7C68B, stars: 0),
            // Full morning, the haze still warm at the horizon.
            Anchor(16, zenith: 0xA8CAE6, middle: 0xCADEEC, horizon: 0xE5EFF4,
                   atmosphere: 0x9FD0FF, glow: 0xECDBBA, stars: 0),
            // The middle of the day: the palette the app was designed in.
            Anchor(35, zenith: 0xC9DFEF, middle: 0xDAE8F3, horizon: 0xE9F2F8,
                   atmosphere: 0x8CC8FF, glow: 0xE7EFF5, stars: 0),
            Anchor(90, zenith: 0xD9E8F3, middle: 0xE4EEF6, horizon: 0xF0F6FB,
                   atmosphere: 0x8CC8FF, glow: 0xF0F6FB, stars: 0),
        ]
    }
}
