import Foundation

/// Sunrise and sunset for a coarse coordinate, as a pure function of date and
/// place — no location services, no network, no clock reads of its own.
///
/// The Orbit scene is the only surface that follows daylight, and it must keep
/// working when location is denied or unavailable, so every entry point has a
/// defined answer: a real solar calculation when a coordinate is known, and a
/// fixed 06:00 / 18:00 local day otherwise. Above the polar circles the sun can
/// fail to cross the horizon at all; those days report `.polarDay` / `.polarNight`
/// rather than inventing a rise time.
public enum SolarClock {

    /// A coarse (approximate-accuracy) location. Never synced — see the sky
    /// settings — and only ever used to place the day/night boundary.
    public struct Coordinate: Sendable, Equatable, Codable, Hashable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// What the sun does on one local day.
    public enum SunEvents: Sendable, Equatable {
        /// The ordinary case: the sun rises and sets.
        case rises(sunrise: Date, sunset: Date)
        /// Midnight sun — the sun never sets on this day.
        case polarDay
        /// Polar night — the sun never rises on this day.
        case polarNight
    }

    /// The hour the fallback "day" begins when no coordinate is available.
    public static let fallbackSunriseHour = 6
    /// The hour the fallback "day" ends when no coordinate is available.
    public static let fallbackSunsetHour = 18

    // MARK: Events

    /// Sunrise and sunset for the local day containing `date`.
    ///
    /// Implements the standard NOAA sunrise equation. Accurate to roughly a
    /// minute, which is far finer than an ambient scene needs.
    public static func events(
        on date: Date,
        at coordinate: Coordinate,
        calendar: Calendar = .current
    ) -> SunEvents {
        // Anchor on local noon: the day the user is living in, not the UTC one.
        let noon = calendar.startOfDay(for: date).addingTimeInterval(12 * 3600)
        let julian = julianDay(noon)

        // Days since the J2000 epoch, corrected for longitude so the whole
        // calculation runs in the mean solar time of the place itself.
        let n = (julian - 2451545.0 + 0.0008 - coordinate.longitude / 360).rounded()
        let meanSolarNoon = n + 0.0009 + -coordinate.longitude / 360

        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarNoon).truncatingRemainder(dividingBy: 360)
        let m = radians(meanAnomaly)
        let center = 1.9148 * sin(m) + 0.0200 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let l = radians(eclipticLongitude)

        let solarTransit = 2451545.0 + meanSolarNoon + 0.0053 * sin(m) - 0.0069 * sin(2 * l)
        let declination = asin(sin(l) * sin(radians(23.4397)))

        let phi = radians(coordinate.latitude)
        // −0.833° accounts for the solar disc's radius and atmospheric refraction.
        let cosHourAngle =
            (sin(radians(-0.833)) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))

        // Outside ±1 the horizon is never crossed: the sun is up, or down, all day.
        guard cosHourAngle <= 1 else { return .polarNight }
        guard cosHourAngle >= -1 else { return .polarDay }

        let hourAngle = degrees(acos(cosHourAngle))
        let sunrise = solarTransit - hourAngle / 360
        let sunset = solarTransit + hourAngle / 360
        return .rises(sunrise: instant(fromJulianDay: sunrise), sunset: instant(fromJulianDay: sunset))
    }

    // MARK: Daylight

    /// Whether it is daylight at `instant`.
    ///
    /// With no coordinate — permission denied, not yet asked, or a Mac that has
    /// never had one — this falls back to a stable local 06:00–18:00 day rather
    /// than blocking on location. The timer and the workday never wait for this.
    public static func isDaylight(
        at instant: Date,
        coordinate: Coordinate?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let coordinate else { return isFallbackDaylight(at: instant, calendar: calendar) }
        switch events(on: instant, at: coordinate, calendar: calendar) {
        case .rises(let sunrise, let sunset):
            return instant >= sunrise && instant < sunset
        case .polarDay:
            return true
        case .polarNight:
            return false
        }
    }

    /// The next instant the day/night answer flips, so a scene can schedule one
    /// crossfade instead of polling. Nil when the whole day has one answer.
    public static func nextTransition(
        after instant: Date,
        coordinate: Coordinate?,
        calendar: Calendar = .current
    ) -> Date? {
        let boundaries: [Date]
        if let coordinate {
            switch events(on: instant, at: coordinate, calendar: calendar) {
            case .rises(let sunrise, let sunset):
                boundaries = [sunrise, sunset]
            case .polarDay, .polarNight:
                // Nothing changes today; re-evaluate at the start of the next one.
                return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: instant))
            }
        } else {
            boundaries = [fallbackSunriseHour, fallbackSunsetHour].compactMap {
                calendar.date(bySettingHour: $0, minute: 0, second: 0, of: instant)
            }
        }
        if let next = boundaries.filter({ $0 > instant }).min() { return next }
        // Past both of today's boundaries: the next one is tomorrow's sunrise.
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: instant) else { return nil }
        if let coordinate {
            if case .rises(let sunrise, _) = events(on: tomorrow, at: coordinate, calendar: calendar) {
                return sunrise
            }
            return calendar.startOfDay(for: tomorrow)
        }
        return calendar.date(bySettingHour: fallbackSunriseHour, minute: 0, second: 0, of: tomorrow)
    }

    private static func isFallbackDaylight(at instant: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: instant)
        return hour >= fallbackSunriseHour && hour < fallbackSunsetHour
    }

    // MARK: Julian conversions

    private static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    private static func instant(fromJulianDay julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// Which sky the Orbit scene shows. Only the Orbit scene follows this — Stats,
/// History, Settings, sheets and utility windows follow the system appearance,
/// so a sunset never flips the whole information UI.
public enum SkyMode: String, Codable, Sendable, CaseIterable, Hashable {
    case followSun
    case alwaysNight
    case alwaysDay
}
