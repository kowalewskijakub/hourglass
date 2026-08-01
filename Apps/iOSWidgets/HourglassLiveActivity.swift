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

/// Live Activity for the working day, in the same state grammar as everything
/// else: a bounded phase counts down, a clocked-in stretch or a work break counts
/// up, ember is work and stone is rest. Every number is derived from a date, so
/// the system keeps it ticking with no updates from the app.
///
/// There is deliberately no separate Break control while a Pomodoro phase exists
/// — a break already *is* the work break, and the action out of it is Back to
/// work.
struct HourglassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(Color(hex: 0x0E1420).opacity(0.9))
                .activitySystemActionForegroundColor(context.state.tint)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: context.state.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context.state)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(context.state.tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Label, numeral, and one clear thing this state is doing.
                    if context.state.mode == .timer {
                        progressBar(context.state).tint(context.state.tint)
                    } else {
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                CompactMark(mark: context.state.compactMark)
            } compactTrailing: {
                clock(context.state)
                    .monospacedDigit()
                    .foregroundStyle(context.state.tint)
                    .frame(maxWidth: 46)
            } minimal: {
                CompactMark(mark: context.state.compactMark)
            }
            .keylineTint(context.state.tint)
        }
    }

    /// Counts down for a bounded phase, up for a clocked-in stretch or a break.
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

/// The compact mark, drawn to the menu-bar grammar: fill says bounded versus
/// open-ended, colour says work versus rest, and pause has its own shape.
private struct CompactMark: View {
    let mark: MenuBarMark

    var body: some View {
        switch mark {
        case .solidEmber:
            Circle().fill(Color.orbitEmber).frame(width: 8, height: 8)
        case .hollowEmber:
            Circle().stroke(Color.orbitEmber, lineWidth: 1.6).frame(width: 8, height: 8)
        case .solidStone:
            Circle().fill(Color.orbitStone).frame(width: 8, height: 8)
        case .hollowStone:
            Circle().stroke(Color.orbitStone, lineWidth: 1.6).frame(width: 8, height: 8)
        case .pause:
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.orbitStone)
        case .dim:
            Circle().stroke(.secondary, lineWidth: 1.6).frame(width: 8, height: 8)
        }
    }
}

/// The Lock Screen presentation: a static Orbit crop, the state, the numeral,
/// and one state-appropriate action.
struct LockScreenLiveActivityView: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 13) {
            OrbitCrop(tint: state.tint)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(state.tint)

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
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)

            Image(systemName: state.mode == .timer && state.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hex: 0x211303))
                .frame(width: 42, height: 42)
                .background(Circle().fill(state.tint))
                .accessibilityHidden(true)
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Says the mode, whether the time is remaining or elapsed, and how the
    /// workday relates to it.
    private var accessibilityLabel: String {
        switch state.mode {
        case .timer:
            return state.isRunning
                ? "\(state.title), counting down."
                : "\(state.title), paused."
        case .clockedIn:
            return "Clocked in, counting worked time."
        case .onBreak:
            return "Work break, counting elapsed time. Excluded from your work total."
        }
    }
}

/// A static Orbit crop: planet, track and the now marker. Decorative only.
private struct OrbitCrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x09111E))

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x101B2E), Color(hex: 0x06101B)],
                        center: .top,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 94, height: 94)
                .offset(y: 44)

            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [1.5, 4]))
                .foregroundStyle(.white.opacity(0.2))
                .frame(width: 63, height: 63)
                .offset(y: 27)

            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .offset(y: -21)
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
