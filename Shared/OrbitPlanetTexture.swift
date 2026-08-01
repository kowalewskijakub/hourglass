import SwiftUI

/// Optional photographic imagery for the Orbit planet.
///
/// The v1 handoff makes real Earth textures a phase-2 item, so nothing is
/// bundled and the scene draws its procedural planet. This is the seam that
/// changes that: drop the two images into the app's asset catalog under the
/// names below and every Orbit surface starts using them, with no other change.
///
/// **What to supply**
/// - `OrbitEarthDay` — an equirectangular (plate carrée) colour map of the
///   Earth, 2:1 aspect, longitude −180…180 left to right.
/// - `OrbitEarthNight` — the same projection at the same size, city lights on
///   black. Optional: without it the night side simply darkens.
///
/// NASA's Blue Marble and Black Marble are the usual sources and are public
/// domain, but licensing is a decision for whoever ships the app, which is why
/// nothing is fetched or vendored automatically.
enum OrbitPlanetTexture {
    static let dayAssetName = "OrbitEarthDay"
    static let nightAssetName = "OrbitEarthNight"

    /// True when the day map is bundled; the scene switches to imagery only
    /// then, so a missing asset degrades to the procedural planet rather than a
    /// hole where the world should be.
    static var isAvailable: Bool { day != nil }

    static let day: Image? = image(named: dayAssetName)
    static let night: Image? = image(named: nightAssetName)

    private static func image(named name: String) -> Image? {
        #if os(macOS)
        guard let found = NSImage(named: name), found.size.width > 0 else { return nil }
        return Image(nsImage: found)
        #else
        guard let found = UIImage(named: name), found.size.width > 0 else { return nil }
        return Image(uiImage: found)
        #endif
    }
}

/// Where the sun is, expressed the two ways the scene needs it.
///
/// Kept as a value so the scene stays a pure function of its inputs: the same
/// instant and coordinate always draw the same planet, which is what makes the
/// day/night crossfade reproducible in a snapshot.
struct SunPosition: Equatable {
    /// 0 at local midnight, 0.5 at local noon, wrapping at 1. Drives which
    /// longitude faces the viewer, so the visible face turns across the day.
    let dayFraction: Double
    /// How lit the visible face is, 0 fully dark to 1 fully lit. The terminator
    /// sweeps rather than snapping, so dawn and dusk are actually drawn.
    let illumination: Double

    init(at instant: Date, isDaylight: Bool, calendar: Calendar = .current) {
        let startOfDay = calendar.startOfDay(for: instant)
        let seconds = instant.timeIntervalSince(startOfDay)
        dayFraction = (seconds / 86_400).truncatingRemainder(dividingBy: 1)

        // A cosine centred on noon, so the face brightens and darkens smoothly
        // through the day instead of flipping at the boundary. `isDaylight`
        // picks the band — which is what keeps the polar cases and the fixed
        // Always night / Always day skies truthful — and the curve shapes it
        // within that band. The two bands are kept well apart: a night sky over
        // a planet at a third of full brightness reads as an overcast noon.
        let fromNoon = abs(dayFraction - 0.5) * 2 // 0 at noon, 1 at midnight
        let curve = (cos(fromNoon * .pi) + 1) / 2 // 1 at noon, 0 at midnight
        illumination = isDaylight ? 0.70 + 0.30 * curve : 0.06 + 0.16 * curve
    }
}
