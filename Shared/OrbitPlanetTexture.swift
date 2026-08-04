import SwiftUI

/// Optional photographic imagery for the Orbit planet.
///
/// Both apps bundle NASA imagery under the names below, and this is the seam
/// that makes that a choice rather than a dependency: drop the two images into
/// an app's asset catalog and every Orbit surface uses them; remove them and the
/// scene falls back to its procedural planet, with no other change either way.
/// The globe is only draggable when a map is present — there is nothing to turn
/// on a planet that has no longitude.
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
