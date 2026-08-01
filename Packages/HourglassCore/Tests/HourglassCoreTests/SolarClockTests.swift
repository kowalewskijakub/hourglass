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
