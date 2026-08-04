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

    /// The place the scene stands in when no coordinate is known: the equator, at
    /// the longitude the time zone implies.
    ///
    /// Chosen so the fallback still means what it has always meant — on the
    /// equator the sun rises near six and sets near six all year — while giving
    /// the scene a *real* sun to raise, lower and cast a terminator with, instead
    /// of a switch that flips at two fixed hours.
    public static func fallbackCoordinate(
        for timeZone: TimeZone,
        at instant: Date = Date()
    ) -> Coordinate {
        // 15° of longitude per hour, so 240 seconds of offset per degree.
        Coordinate(latitude: 0, longitude: Double(timeZone.secondsFromGMT(for: instant)) / 240)
    }

    // MARK: Position

    /// Where the sun stands at one instant, seen from one place.
    ///
    /// The scene needs more than "is it up". The elevation angle is what makes a
    /// dawn look like a dawn rather than a switch being thrown, and the
    /// declination and hour angle are what let it sweep a terminator across a
    /// globe the user can spin — the sun's height at a *neighbouring* longitude
    /// is the same formula with the hour angle shifted, and nothing else.
    public struct Position: Sendable, Equatable {
        /// Elevation above the horizon in degrees; negative below it.
        public let altitude: Double
        /// The sun's declination in degrees — how far the terminator leans.
        public let declination: Double
        /// Degrees turned past local solar noon, 15° to the hour: negative in the
        /// morning, positive in the afternoon, wrapped to −180…180.
        public let hourAngle: Double

        /// Hours from local solar noon, for the reader who thinks in time.
        public var hoursFromNoon: Double { hourAngle / 15 }

        /// The named stretch of the day this position falls in.
        public var phase: SolarPhase { SolarPhase(altitude: altitude, hourAngle: hourAngle) }
    }

    /// The sun's position at `instant`, seen from `coordinate`.
    ///
    /// The low-precision solar coordinates from the Astronomical Almanac: good to
    /// about an arcminute for a century either side of 2000, which is orders of
    /// magnitude finer than an ambient scene can show.
    public static func position(at instant: Date, coordinate: Coordinate) -> Position {
        let d = julianDay(instant) - 2_451_545.0

        let meanAnomaly = radians(357.529 + 0.98560028 * d)
        let meanLongitude = 280.459 + 0.98564736 * d
        let eclipticLongitude = radians(
            meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)
        )
        let obliquity = radians(23.439 - 0.00000036 * d)

        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = degrees(
            atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        )

        // Greenwich mean sidereal time: which meridian is facing the stars, and
        // so — once the sun's right ascension is subtracted — the sun.
        let greenwichSidereal = (18.697374558 + 24.06570982441908 * d)
            .truncatingRemainder(dividingBy: 24) * 15
        let hourAngle = wrapped(greenwichSidereal + coordinate.longitude - rightAscension)

        return Position(
            altitude: altitude(
                latitude: coordinate.latitude,
                declination: degrees(declination),
                hourAngle: hourAngle
            ),
            declination: degrees(declination),
            hourAngle: hourAngle
        )
    }

    /// The sun's elevation at a place whose solar noon is `hourAngle` degrees
    /// away, in degrees.
    ///
    /// Split out from `position` because the scene calls it once per sample
    /// across the visible face: the terminator is this curve read left to right,
    /// and paying for a full solar solution at every sample would be waste.
    public static func altitude(latitude: Double, declination: Double, hourAngle: Double) -> Double {
        let phi = radians(latitude)
        let delta = radians(declination)
        let h = radians(hourAngle)
        return degrees(asin(sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(h)))
    }

    /// Folds an angle into −180…180.
    private static func wrapped(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
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

/// A named stretch of the day, read off the sun's elevation.
///
/// Fourteen of them rather than two, because day and night are the only parts of
/// a day a scene *cannot* make anything of: everything worth looking at — the
/// blue hour, the rose of a sunrise, the long gold of an evening — happens in
/// between. The boundaries are the conventional twilight angles, so each name
/// means what an almanac means by it, and a phase is never a matter of taste.
public enum SolarPhase: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// Sun below −18°: no trace of it left in the sky.
    case night
    case astronomicalDawn, nauticalDawn, civilDawn
    case sunrise, goldenMorning, morning
    case noon
    case afternoon, goldenEvening, sunset
    case civilDusk, nauticalDusk, astronomicalDusk

    /// The horizon, allowing for the sun's own width and for refraction — the
    /// same −0.833° that decides sunrise and sunset above.
    public static let horizonAltitude = -0.833

    public init(altitude: Double, hourAngle: Double) {
        // Solar noon exactly is the top of the climb, so it belongs to the
        // rising half — a sun at its highest must never be called a sunset.
        let rising = hourAngle <= 0
        switch altitude {
        case ..<(-18):
            self = .night
        case ..<(-12):
            self = rising ? .astronomicalDawn : .astronomicalDusk
        case ..<(-6):
            self = rising ? .nauticalDawn : .nauticalDusk
        case ..<Self.horizonAltitude:
            self = rising ? .civilDawn : .civilDusk
        case ..<6:
            self = rising ? .sunrise : .sunset
        case ..<12:
            self = rising ? .goldenMorning : .goldenEvening
        default:
            // Only an hour either side of the sun's own noon, which in winter at
            // a high latitude never arrives at all — and shouldn't.
            self = abs(hourAngle) <= 15 ? .noon : (rising ? .morning : .afternoon)
        }
    }

    /// Whether the sun is above the horizon in this phase.
    public var isSunUp: Bool {
        switch self {
        case .sunrise, .goldenMorning, .morning, .noon, .afternoon, .goldenEvening, .sunset:
            return true
        default:
            return false
        }
    }

    /// Whether the sun is below the horizon but still lighting the sky.
    public var isTwilight: Bool {
        switch self {
        case .astronomicalDawn, .nauticalDawn, .civilDawn,
             .civilDusk, .nauticalDusk, .astronomicalDusk:
            return true
        default:
            return false
        }
    }
}

/// Which sky the Orbit scene shows. Only the Orbit scene follows this — Stats,
/// History, Settings, sheets and utility windows follow the system appearance,
/// so a sunset never flips the whole information UI.
public enum SkyMode: String, Codable, Sendable, CaseIterable, Hashable {
    case followSun
    case alwaysNight
    case alwaysDay
}
