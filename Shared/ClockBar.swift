import SwiftUI
import HourglassCore

/// Shows whether you're clocked in and lets you clock in/out and take a
/// non-Pomodoro break. Shared by the macOS panel and the iOS timer screen.
struct ClockBar: View {
    @Bindable var model: AppModel
    var compact: Bool = false

    private var workday: WorkdayTracker { model.workday }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: workday.toggleClock) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(compact ? .caption : .callout)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workday.isClockedIn ? "Clock out" : "Clock in")

            if workday.isClockedIn {
                Button(action: workday.toggleBreak) {
                    Image(systemName: workday.isOnBreak ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(compact ? .callout : .body)
                        .foregroundStyle(workday.isOnBreak ? .orange : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(workday.isOnBreak ? "End break" : "Start a break")
            }
        }
        .animation(.default, value: workday.isClockedIn)
        .animation(.default, value: workday.isOnBreak)
    }

    private var statusColor: Color {
        guard workday.isClockedIn else { return .secondary.opacity(0.5) }
        return workday.isOnBreak ? .orange : .green
    }

    private var statusText: String {
        guard workday.isClockedIn else { return "Clocked out" }
        return workday.isOnBreak ? "On break" : "Clocked in"
    }
}
