import ActivityKit
import WidgetKit
import SwiftUI
import HourglassCore

@main
struct HourglassWidgetBundle: WidgetBundle {
    var body: some Widget {
        HourglassLiveActivity()
    }
}

/// Live Activity for the working day: a running Pomodoro counts down, while a
/// clocked-in stretch or a break counts up. Every number is derived from a date,
/// so the system keeps it ticking without the app sending updates.
struct HourglassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(context.state.tint.opacity(0.14))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: context.state.symbolName)
                        .font(.caption)
                        .foregroundStyle(context.state.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context.state)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(context.state.tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.mode == .timer {
                        progressBar(context.state).tint(context.state.tint)
                    } else {
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.tint)
            } compactTrailing: {
                clock(context.state)
                    .monospacedDigit()
                    .foregroundStyle(context.state.tint)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.tint)
            }
            .keylineTint(context.state.tint)
        }
    }

    /// Counts down for a Pomodoro, up for a clocked-in stretch or break.
    @ViewBuilder
    private func clock(_ state: TimerActivityAttributes.ContentState) -> some View {
        switch state.mode {
        case .timer:
            Text(timerInterval: state.timerRange,
                 pauseTime: state.isRunning ? nil : state.pausedAt,
                 countsDown: true)
        case .clockedIn, .onBreak:
            if let since = state.since {
                Text(since, style: .timer)
            } else {
                Text("--:--")
            }
        }
    }

    @ViewBuilder
    private func progressBar(_ state: TimerActivityAttributes.ContentState) -> some View {
        if state.isRunning {
            ProgressView(timerInterval: state.timerRange, countsDown: false)
                .labelsHidden()
        } else {
            ProgressView(value: state.pausedFraction, total: 1)
                .labelsHidden()
        }
    }
}

struct LockScreenLiveActivityView: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbolName)
                .font(.title)
                .foregroundStyle(state.tint)

            VStack(alignment: .leading, spacing: 6) {
                Text(state.title).font(.headline)
                if state.mode == .timer {
                    if state.isRunning {
                        ProgressView(timerInterval: state.timerRange, countsDown: false)
                            .labelsHidden()
                            .tint(state.tint)
                    } else {
                        ProgressView(value: state.pausedFraction, total: 1)
                            .labelsHidden()
                            .tint(state.tint)
                    }
                } else {
                    Text(state.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Group {
                if state.mode == .timer {
                    Text(timerInterval: state.timerRange,
                         pauseTime: state.isRunning ? nil : state.pausedAt,
                         countsDown: true)
                } else if let since = state.since {
                    Text(since, style: .timer)
                } else {
                    Text("--:--")
                }
            }
            .font(.system(.title2, design: .rounded).monospacedDigit())
            .frame(width: 82, alignment: .trailing)
        }
        .padding()
    }
}
