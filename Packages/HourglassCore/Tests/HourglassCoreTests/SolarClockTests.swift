import Testing
import Foundation
@testable import HourglassCore

/// Sunrise/sunset fixtures against published almanac times, plus the two cases
/// the Orbit scene actually has to survive: no coordinate at all, and a latitude
/// where the sun does not cross the horizon.
@Suite struct SolarClockTests {

    private func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ timeZone: String) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar(timeZone).date(from: components)!
    }

    /// Asserts an event lands within `tolerance` minutes of the almanac time.
    private func expect(
        _ instant: Date,
        toBe expected: String,
        in timeZone: String,
        tolerance: TimeInterval = 6 * 60,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(Locale(identifier: "en_GB"))
        style.timeZone = TimeZone(identifier: timeZone)!
        let formatted = instant.formatted(style)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = "HH:mm"
        guard let actual = formatter.date(from: formatted.replacingOccurrences(of: " ", with: "")),
              let target = formatter.date(from: expected) else {
            Issue.record("could not parse \(formatted)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual.timeIntervalSince(target)) <= tolerance,
                "\(formatted) is not within \(Int(tolerance / 60))m of \(expected)",
                sourceLocation: sourceLocation)
    }

    private static let london = SolarClock.Coordinate(latitude: 51.5074, longitude: -0.1278)
    private static let sydney = SolarClock.Coordinate(latitude: -33.8688, longitude: 151.2093)
    private static let tromso = SolarClock.Coordinate(latitude: 69.6492, longitude: 18.9553)

    @Test func londonMidsummer() {
        let events = SolarClock.events(
            on: date(2024, 6, 21, "Europe/London"),
            at: Self.london,
            calendar: calendar("Europe/London")
        )
        guard case .rises(let sunrise, let sunset) = events else {
            Issue.record("expected an ordinary day"); return
        }
        expect(sunrise, toBe: "04:43", in: "Europe/London")
        expect(sunset, toBe: "21:21", in: "Europe/London")
    }

    @Test func londonMidwinter() {
        let events = SolarClock.events(
            on: date(2024, 12, 21, "Europe/London"),
            at: Self.london,
            calendar: calendar("Europe/London")
        )
        guard case .rises(let sunrise, let sunset) = events else {
            Issue.record("expected an ordinary day"); return
        }
        expect(sunrise, toBe: "08:04", in: "Europe/London")
        expect(sunset, toBe: "15:53", in: "Europe/London")
    }

    /// The southern hemisphere, where June is winter — a sign error in the
    /// declination would sail through a northern-only fixture.
    @Test func sydneyInJune() {
        let events = SolarClock.events(
            on: date(2024, 6, 21, "Australia/Sydney"),
            at: Self.sydney,
            calendar: calendar("Australia/Sydney")
        )
        guard case .rises(let sunrise, let sunset) = events else {
            Issue.record("expected an ordinary day"); return
        }
        expect(sunrise, toBe: "07:00", in: "Australia/Sydney")
        expect(sunset, toBe: "16:54", in: "Australia/Sydney")
    }

    @Test func polarDayAndPolarNight() {
        let summer = SolarClock.events(
            on: date(2024, 6, 21, "Europe/Oslo"),
            at: Self.tromso,
            calendar: calendar("Europe/Oslo")
        )
        #expect(summer == .polarDay)

        let winter = SolarClock.events(
            on: date(2024, 12, 21, "Europe/Oslo"),
            at: Self.tromso,
            calendar: calendar("Europe/Oslo")
        )
        #expect(winter == .polarNight)

        // The scene still has to pick a sky, and it picks the truthful one.
        #expect(SolarClock.isDaylight(at: date(2024, 6, 21, "Europe/Oslo"),
                                      coordinate: Self.tromso,
                                      calendar: calendar("Europe/Oslo")))
        #expect(SolarClock.isDaylight(at: date(2024, 12, 21, "Europe/Oslo"),
                                      coordinate: Self.tromso,
                                      calendar: calendar("Europe/Oslo")) == false)
    }

    @Test func daylightFollowsTheCalculatedBoundaries() {
        let calendar = calendar("Europe/London")
        let day = calendar.startOfDay(for: date(2024, 6, 21, "Europe/London"))

        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(3 * 3600),
                                      coordinate: Self.london, calendar: calendar) == false)
        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(12 * 3600),
                                      coordinate: Self.london, calendar: calendar))
        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(23 * 3600),
                                      coordinate: Self.london, calendar: calendar) == false)
    }

    /// Location denied, never asked, or a Mac that has none: the scene still has
    /// a day and a night, and nothing waits on permission.
    @Test func withoutACoordinateTheDayIsSixToSix() {
        let calendar = calendar("Europe/London")
        let day = calendar.startOfDay(for: date(2024, 12, 21, "Europe/London"))

        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(5 * 3600),
                                      coordinate: nil, calendar: calendar) == false)
        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(6 * 3600),
                                      coordinate: nil, calendar: calendar))
        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(17.5 * 3600),
                                      coordinate: nil, calendar: calendar))
        #expect(SolarClock.isDaylight(at: day.addingTimeInterval(18 * 3600),
                                      coordinate: nil, calendar: calendar) == false)
    }

    @Test func theNextTransitionIsTheNextBoundary() {
        let calendar = calendar("Europe/London")
        let day = calendar.startOfDay(for: date(2024, 12, 21, "Europe/London"))

        let morning = SolarClock.nextTransition(after: day.addingTimeInterval(3 * 3600),
                                                coordinate: nil, calendar: calendar)
        #expect(morning == day.addingTimeInterval(6 * 3600))

        let evening = SolarClock.nextTransition(after: day.addingTimeInterval(12 * 3600),
                                                coordinate: nil, calendar: calendar)
        #expect(evening == day.addingTimeInterval(18 * 3600))

        // Past both boundaries, the next one belongs to tomorrow.
        let night = SolarClock.nextTransition(after: day.addingTimeInterval(22 * 3600),
                                              coordinate: nil, calendar: calendar)
        #expect(night == day.addingTimeInterval(30 * 3600))
    }

    // MARK: Position and phase

    /// The elevation angle has to agree with the rise/set times computed a
    /// completely different way, or the scene's terminator and its sky would tell
    /// two different stories about the same minute.
    @Test func elevationCrossesTheHorizonAtSunriseAndSunset() {
        let calendar = calendar("Europe/London")
        let events = SolarClock.events(on: date(2024, 6, 21, "Europe/London"),
                                       at: Self.london, calendar: calendar)
        guard case .rises(let sunrise, let sunset) = events else {
            Issue.record("expected an ordinary day"); return
        }

        func altitude(_ instant: Date) -> Double {
            SolarClock.position(at: instant, coordinate: Self.london).altitude
        }
        // Within a couple of minutes of each event, and on the right side of it.
        #expect(abs(altitude(sunrise) - SolarPhase.horizonAltitude) < 0.6)
        #expect(abs(altitude(sunset) - SolarPhase.horizonAltitude) < 0.6)
        #expect(altitude(sunrise.addingTimeInterval(-15 * 60)) < SolarPhase.horizonAltitude)
        #expect(altitude(sunrise.addingTimeInterval(15 * 60)) > SolarPhase.horizonAltitude)
        #expect(altitude(sunset.addingTimeInterval(15 * 60)) < SolarPhase.horizonAltitude)
    }

    /// London's midsummer noon sun reaches about 62°, and its midwinter noon sun
    /// about 15°. A latitude or declination sign error moves these by tens of
    /// degrees, so they pin the whole calculation down.
    @Test func noonElevationMatchesTheAlmanac() {
        let calendar = calendar("Europe/London")

        func noonAltitude(_ month: Int, _ day: Int) -> Double {
            // Solar noon, found by walking the day rather than assuming 12:00 —
            // British Summer Time and the equation of time both move it.
            let start = calendar.startOfDay(for: date(2024, month, day, "Europe/London"))
            return (0..<(24 * 12)).map {
                SolarClock.position(at: start.addingTimeInterval(Double($0) * 300),
                                    coordinate: Self.london).altitude
            }.max() ?? 0
        }

        #expect(abs(noonAltitude(6, 21) - 62.0) < 1.0)
        #expect(abs(noonAltitude(12, 21) - 15.1) < 1.0)
    }

    /// The hour angle is what places the sun east or west of the viewer, and so
    /// which side of the globe the scene lights.
    @Test func theHourAngleRunsFifteenDegreesToTheHour() {
        let calendar = calendar("Europe/London")
        let start = calendar.startOfDay(for: date(2024, 6, 21, "Europe/London"))

        let morning = SolarClock.position(at: start.addingTimeInterval(9 * 3600),
                                          coordinate: Self.london)
        let evening = SolarClock.position(at: start.addingTimeInterval(18 * 3600),
                                          coordinate: Self.london)
        #expect(morning.hourAngle < 0)
        #expect(evening.hourAngle > 0)
        // Nine hours apart is 135° of rotation, whatever the equation of time does.
        #expect(abs((evening.hourAngle - morning.hourAngle) - 135) < 1)
    }

    /// The whole point of the phases: a day is more than a switch. Walking one
    /// through has to visit dawn, sunrise, the middle of the day and dusk, in
    /// that order and each exactly once.
    @Test func aDayPassesThroughItsPhasesInOrder() {
        let calendar = calendar("Europe/London")
        let start = calendar.startOfDay(for: date(2024, 9, 21, "Europe/London"))

        var seen: [SolarPhase] = []
        for step in 0..<(24 * 6) {
            let phase = SolarClock.position(at: start.addingTimeInterval(Double(step) * 600),
                                            coordinate: Self.london).phase
            if seen.last != phase { seen.append(phase) }
        }

        let expected: [SolarPhase] = [
            .night, .astronomicalDawn, .nauticalDawn, .civilDawn, .sunrise,
            .goldenMorning, .morning, .noon, .afternoon, .goldenEvening, .sunset,
            .civilDusk, .nauticalDusk, .astronomicalDusk, .night,
        ]
        #expect(seen == expected)
    }

    /// Two named phases either side of the horizon, so a scene reading `isSunUp`
    /// cannot end up lighting a night.
    @Test func phasesKnowWhetherTheSunIsUp() {
        #expect(SolarPhase(altitude: 40, hourAngle: -60).isSunUp)
        #expect(SolarPhase(altitude: 1, hourAngle: -80).isSunUp)
        #expect(SolarPhase(altitude: -3, hourAngle: 80).isSunUp == false)
        #expect(SolarPhase(altitude: -3, hourAngle: 80).isTwilight)
        #expect(SolarPhase(altitude: -30, hourAngle: 170) == .night)
        #expect(SolarPhase(altitude: -30, hourAngle: 170).isTwilight == false)
    }

    /// Noon is the sun's own noon, not the clock's, and it exists only when the
    /// sun actually climbs. A December day in Tromsø has no noon to name.
    @Test func noonNeedsTheSunToHaveClimbed() {
        #expect(SolarPhase(altitude: 50, hourAngle: 5) == .noon)
        #expect(SolarPhase(altitude: 50, hourAngle: -40) == .morning)
        #expect(SolarPhase(altitude: 50, hourAngle: 40) == .afternoon)
        // High latitude, low winter sun: midday, but never a `noon`.
        #expect(SolarPhase(altitude: 3, hourAngle: 0) == .sunrise)
    }

    /// Without a coordinate the scene stands on the equator at the time zone's
    /// own longitude, which keeps the documented six-to-six day while giving the
    /// sun somewhere real to rise from.
    @Test func theFallbackCoordinateKeepsASixToSixDay() {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let day = calendar.startOfDay(for: date(2024, 12, 21, "Europe/Warsaw"))
        let coordinate = SolarClock.fallbackCoordinate(for: zone, at: day)
        #expect(coordinate.latitude == 0)

        func altitude(_ hours: Double) -> Double {
            SolarClock.position(at: day.addingTimeInterval(hours * 3600),
                                coordinate: coordinate).altitude
        }
        // Sunrise and sunset land within half an hour of six, in midwinter, at a
        // time zone whose longitude is nothing like its meridian.
        #expect(altitude(5.5) < 0)
        #expect(altitude(6.5) > 0)
        #expect(altitude(17.5) > 0)
        #expect(altitude(18.5) < 0)
        #expect(altitude(12) > 60)
    }

    /// The cheap terminator sample and the full solar solution have to agree, or
    /// the lit half of the globe would not line up with the sky above it.
    @Test func theTerminatorSampleAgreesWithTheFullSolution() {
        let position = SolarClock.position(at: date(2024, 3, 21, "Europe/London"),
                                           coordinate: Self.london)
        let sampled = SolarClock.altitude(latitude: Self.london.latitude,
                                          declination: position.declination,
                                          hourAngle: position.hourAngle)
        #expect(abs(sampled - position.altitude) < 0.0001)

        // 90° east of the viewer is six hours ahead: past sunset on an equinox.
        let eastward = SolarClock.altitude(latitude: Self.london.latitude,
                                           declination: position.declination,
                                           hourAngle: position.hourAngle + 90)
        #expect(eastward < position.altitude)
    }

    /// A polar day has no boundary to schedule against, so the scene re-checks
    /// tomorrow rather than never.
    @Test func aPolarDaySchedulesTheNextDayInstead() {
        let calendar = calendar("Europe/Oslo")
        let instant = date(2024, 6, 21, "Europe/Oslo")
        let next = SolarClock.nextTransition(after: instant,
                                             coordinate: Self.tromso, calendar: calendar)
        #expect(next == calendar.date(byAdding: .day, value: 1,
                                      to: calendar.startOfDay(for: instant)))
    }
}
