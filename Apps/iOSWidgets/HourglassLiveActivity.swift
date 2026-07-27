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
                .activityBackgroundTint(tint(context.state).opacity(0.14))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(title(context.state), systemImage: symbol(context.state))
                        .font(.caption)
                        .foregroundStyle(tint(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context.state)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(tint(context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.mode == .timer {
                        progressBar(context.state).tint(tint(context.state))
                    } else {
                        Text(subtitle(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context.state))
                    .foregroundStyle(tint(context.state))
            } compactTrailing: {
                clock(context.state)
                    .monospacedDigit()
                    .foregroundStyle(tint(context.state))
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: symbol(context.state))
                    .foregroundStyle(tint(context.state))
            }
            .keylineTint(tint(context.state))
        }
    }

    // MARK: Per-mode presentation

    private func title(_ state: TimerActivityAttributes.ContentState) -> String {
        switch state.mode {
        case .timer: return state.kind.displayName
        case .clockedIn: return "Clocked in"
        case .onBreak: return "On break"
        }
    }

    private func subtitle(_ state: TimerActivityAttributes.ContentState) -> String {
        switch state.mode {
        case .timer: return state.kind.displayName
        case .clockedIn: return "Working — no timer running"
        case .onBreak: return "Break in progress"
        }
    }

    private func symbol(_ state: TimerActivityAttributes.ContentState) -> String {
        switch state.mode {
        case .timer: return state.kind.symbolName
        case .clockedIn: return "clock.badge.checkmark"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }

    private func tint(_ state: TimerActivityAttributes.ContentState) -> Color {
        switch state.mode {
        case .timer: return state.kind.tint
        case .clockedIn: return .green
        case .onBreak: return .orange
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
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if state.mode == .timer {
                    if state.isRunning {
                        ProgressView(timerInterval: state.timerRange, countsDown: false)
                            .labelsHidden()
                            .tint(tint)
                    } else {
                        ProgressView(value: state.pausedFraction, total: 1)
                            .labelsHidden()
                            .tint(tint)
                    }
                } else {
                    Text(state.mode == .onBreak ? "Break in progress" : "Working")
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

    private var title: String {
        switch state.mode {
        case .timer: return state.kind.displayName
        case .clockedIn: return "Clocked in"
        case .onBreak: return "On break"
        }
    }

    private var symbol: String {
        switch state.mode {
        case .timer: return state.kind.symbolName
        case .clockedIn: return "clock.badge.checkmark"
        case .onBreak: return "cup.and.saucer.fill"
        }
    }

    private var tint: Color {
        switch state.mode {
        case .timer: return state.kind.tint
        case .clockedIn: return .green
        case .onBreak: return .orange
        }
    }
}
