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

/// Live Activity for a running Pomodoro session. The countdown auto-updates from
/// the device clock; while paused it's frozen with `pauseTime:` and the bar is
/// swapped to a static value.
struct HourglassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(context.state.kind.tint.opacity(0.14))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.kind.displayName, systemImage: context.state.kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(context.state.kind.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context.state)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(context.state.kind.tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    progressBar(context.state)
                        .tint(context.state.kind.tint)
                }
            } compactLeading: {
                Image(systemName: context.state.kind.symbolName)
                    .foregroundStyle(context.state.kind.tint)
            } compactTrailing: {
                timerText(context.state)
                    .monospacedDigit()
                    .foregroundStyle(context.state.kind.tint)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: context.state.kind.symbolName)
                    .foregroundStyle(context.state.kind.tint)
            }
            .keylineTint(context.state.kind.tint)
        }
    }

    @ViewBuilder
    private func timerText(_ state: TimerActivityAttributes.ContentState) -> some View {
        Text(timerInterval: state.timerRange,
             pauseTime: state.isRunning ? nil : state.pausedAt,
             countsDown: true)
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
            Image(systemName: state.kind.symbolName)
                .font(.title)
                .foregroundStyle(state.kind.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.kind.displayName).font(.headline)
                if state.isRunning {
                    ProgressView(timerInterval: state.timerRange, countsDown: false)
                        .labelsHidden()
                        .tint(state.kind.tint)
                } else {
                    ProgressView(value: state.pausedFraction, total: 1)
                        .labelsHidden()
                        .tint(state.kind.tint)
                }
            }
            Spacer()
            Text(timerInterval: state.timerRange,
                 pauseTime: state.isRunning ? nil : state.pausedAt,
                 countsDown: true)
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .frame(width: 82, alignment: .trailing)
        }
        .padding()
    }
}
