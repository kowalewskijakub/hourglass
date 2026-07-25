@preconcurrency import ActivityKit
import HourglassCore
import Foundation

/// Starts / updates / ends the Live Activity that mirrors the running timer on the
/// Lock Screen and Dynamic Island. The countdown auto-ticks off the device clock
/// (via `Text(timerInterval:)`), so we only push discrete state changes — no APNs.
@MainActor
final class LiveActivityController {
    private var activity: Activity<TimerActivityAttributes>?

    private var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Start a fresh activity, or update the existing one to a new running range
    /// (covers start, resume, and focus↔break transitions). `plannedDuration` lets
    /// a resumed session's progress bar reflect true elapsed time rather than
    /// snapping back to empty (the range's lower bound is the *virtual* session
    /// start, `now - elapsed`).
    func startOrUpdate(kind: SessionKind, secondsRemaining: TimeInterval, plannedDuration: TimeInterval) async {
        guard isEnabled, secondsRemaining >= 1 else { return }
        let now = Date()
        let elapsed = max(0, plannedDuration - secondsRemaining)
        let start = now.addingTimeInterval(-elapsed)
        let end = now.addingTimeInterval(secondsRemaining)
        let state = TimerActivityAttributes.ContentState(
            kind: kind, isRunning: true, timerRange: start...end, pausedAt: nil
        )
        let content = ActivityContent(state: state, staleDate: end)

        if let activity {
            await activity.update(content)
        } else {
            activity = try? Activity.request(
                attributes: TimerActivityAttributes(),
                content: content,
                pushType: nil
            )
        }
    }

    /// Freeze the countdown in place (paused).
    func pause() async {
        guard let activity else { return }
        var next = activity.content.state
        next.isRunning = false
        next.pausedAt = Date()
        await activity.update(ActivityContent(state: next, staleDate: nil))
    }

    /// End and dismiss the activity.
    func end() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
