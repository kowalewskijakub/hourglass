@preconcurrency import ActivityKit
import HourglassCore
import Foundation

/// Drives the Live Activity for the whole working day: a running Pomodoro, a
/// clocked-in stretch, or a break.
///
/// Every state is expressed as a date the widget counts from, so iOS keeps the
/// numbers ticking with no further updates from the app — which matters because
/// a backgrounded app gets very little time to push any.
@MainActor
final class LiveActivityController {
    private var activity: Activity<TimerActivityAttributes>?

    private var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Recomputes the activity from current state: starts, updates, or ends it.
    /// Safe to call after any timer or clock change.
    func sync(engine: PomodoroEngine, workday: WorkdayTracker) async {
        guard let state = Self.state(engine: engine, workday: workday) else {
            await end()
            return
        }
        await apply(state)
    }

    /// Builds the content state, or nil when there's nothing worth showing.
    private static func state(
        engine: PomodoroEngine,
        workday: WorkdayTracker
    ) -> TimerActivityAttributes.ContentState? {
        // A running or paused Pomodoro takes precedence — it's the thing with a
        // deadline attached.
        if engine.phase != .idle {
            let now = Date()
            let elapsed = max(0, engine.plannedDuration - engine.remaining)
            let start = now.addingTimeInterval(-elapsed)
            let end = now.addingTimeInterval(engine.remaining)
            guard end > start else { return nil }
            return .init(
                mode: .timer,
                kind: engine.kind,
                isRunning: engine.isRunning,
                timerRange: start...end,
                pausedAt: engine.isRunning ? nil : now
            )
        }

        guard let session = workday.currentSession else { return nil }

        if let activeBreak = session.activeBreak {
            return .init(
                mode: .onBreak,
                kind: engine.kind,
                isRunning: true,
                timerRange: activeBreak.startedAt...Date().addingTimeInterval(1),
                since: activeBreak.startedAt
            )
        }

        return .init(
            mode: .clockedIn,
            kind: engine.kind,
            isRunning: true,
            timerRange: session.clockedInAt...Date().addingTimeInterval(1),
            since: session.clockedInAt
        )
    }

    private func apply(_ state: TimerActivityAttributes.ContentState) async {
        guard isEnabled else { return }
        // A counting-up activity has no natural end, so don't let it go stale.
        let staleDate = state.mode == .timer ? state.timerRange.upperBound : nil
        let content = ActivityContent(state: state, staleDate: staleDate)

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

    /// End and dismiss the activity.
    func end() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
