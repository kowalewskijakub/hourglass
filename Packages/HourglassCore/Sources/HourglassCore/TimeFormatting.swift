import Foundation

/// Formatting helpers shared by every UI surface (menu bar, window, iOS).
public enum TimeFormatting {

    /// mm:ss for a countdown. Rounds up so a fresh 25:00 timer reads "25:00",
    /// and only reads "00:00" when the session is genuinely over.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.up))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// A compact human summary of a duration, e.g. "1h 25m", "45m", "30s".
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
}
