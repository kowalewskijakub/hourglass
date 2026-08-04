import Foundation
import Observation
import CoreLocation
import HourglassCore

/// Decides whether the Orbit scene shows a night or a day sky.
///
/// Location is *optional* by construction: nothing here is on the path of the
/// timer, the workday, or any control. Permission is asked for only when the
/// user has actually chosen "Follow the sun", only at approximate accuracy, and
/// a denial simply leaves the stable 06:00 / 18:00 fallback in place. The coarse
/// coordinate is cached locally and deliberately never synced — where the user
/// is has nothing to do with what the other device should render.
@MainActor
@Observable
final class DaylightProvider {
    private(set) var coordinate: SolarClock.Coordinate?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var hasRequested = false

    private static let key = "hourglass.coarseLocation"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.coordinate = Self.cached(from: defaults)

        let delegate = Delegate { [weak self] coordinate in
            self?.adopt(coordinate)
        }
        self.delegate = delegate
        manager.delegate = delegate
        // Approximate is all a sunrise needs, and all we ever ask for.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.distanceFilter = 25_000 // a sunrise does not move street to street
    }

    /// The sky the scene paints at `instant`: its phase, its colours, and where
    /// the sun stands over the face on screen.
    ///
    /// One value rather than a day/night flag, because the scene draws a whole
    /// day now. The chrome still gets its two-way answer, from `sky.isNight`.
    func sky(at instant: Date, mode: SkyMode, calendar: Calendar = .current) -> OrbitSky {
        OrbitSky(at: instant, coordinate: coordinate, mode: mode, calendar: calendar)
    }

    /// Ask for location, but only if following the sun would actually use it.
    ///
    /// Called after the Orbit face has appeared, so the purpose string arrives
    /// alongside a scene that visibly follows the light rather than as a prompt
    /// on a cold launch with nothing to explain it.
    func requestIfNeeded(for mode: SkyMode) {
        guard mode == .followSun, !hasRequested else { return }
        hasRequested = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            return // the fallback day already applies; never nag
        default:
            manager.requestLocation()
        }
    }

    private func adopt(_ coordinate: SolarClock.Coordinate) {
        self.coordinate = coordinate
        if let data = try? JSONEncoder().encode(coordinate) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func cached(from defaults: UserDefaults) -> SolarClock.Coordinate? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SolarClock.Coordinate.self, from: data)
    }

    /// CoreLocation still wants an `NSObject` delegate, so it lives here rather
    /// than making the whole provider one.
    private final class Delegate: NSObject, CLLocationManagerDelegate {
        private let onUpdate: @Sendable @MainActor (SolarClock.Coordinate) -> Void

        init(onUpdate: @escaping @Sendable @MainActor (SolarClock.Coordinate) -> Void) {
            self.onUpdate = onUpdate
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                break
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let last = locations.last else { return }
            let coordinate = SolarClock.Coordinate(
                latitude: last.coordinate.latitude,
                longitude: last.coordinate.longitude
            )
            // Lifted out of the task so it carries the closure, not the delegate.
            let deliver = onUpdate
            Task { @MainActor in deliver(coordinate) }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            // Nothing to do: the fallback sky is already correct, and the scene
            // must never surface a location error over the workday.
        }
    }
}
