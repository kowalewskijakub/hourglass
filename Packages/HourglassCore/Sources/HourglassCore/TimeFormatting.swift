import Foundation

/// Formatting helpers shared by every UI surface (menu bar, Orbit panel, iOS).
///
/// Durations that the user reads as prose go through `Duration.UnitsFormatStyle`
/// rather than hand-assembled suffixes, so "3h 12m" becomes whatever the user's
/// language writes instead of an English string with a translated label glued to
/// it. Clock read-outs stay hand-formatted: `24:53` is the same in every locale
/// and must line up under a fixed-width numeral.
public enum TimeFormatting {

    /// mm:ss for a countdown. Rounds up so a fresh 25:00 timer reads "25:00",
    /// and only reads "00:00" when the session is genuinely over.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.up))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// A running count *up* — `h:mm:ss` past the hour, `m:ss` below it. Used for
    /// net worked time today and for an open-ended break's elapsed time, where
    /// a bare `mm:ss` would eventually read "184:07".
    public static func elapsed(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// `h:mm` — the menu bar's open-ended reading, which only needs to change
    /// when the displayed minute does.
    public static func hoursMinutes(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    /// A compact human summary of a duration, e.g. "1h 25m", "45m", "30s".
    ///
    /// Kept hand-rolled because the CSV export and the existing log rows depend
    /// on its exact shape; user-facing prose uses ``compact(_:locale:)``.
    public static func humanDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(seconds)s"
    }

    /// Hours and minutes in the user's language: "3h 12m" in English, and the
    /// locale's own narrow unit labels elsewhere.
    public static func compact(_ interval: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(max(0, interval))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow).locale(locale))
    }

    /// How long a rest has run: seconds stay visible under an hour ("4m 12s"),
    /// and drop away above it ("1h 4m").
    public static func rest(_ interval: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> =
            interval >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(max(0, interval))
            .formatted(.units(allowed: allowed, width: .narrow).locale(locale))
    }

    /// The spoken form for VoiceOver — "24 minutes, 53 seconds".
    public static func spoken(_ interval: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let total = max(0, interval)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> =
            total >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(total.rounded())
            .formatted(.units(allowed: allowed, width: .wide).locale(locale))
    }

    /// A wall-clock time in the user's 12/24-hour preference and time zone.
    public static func timeOfDay(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
