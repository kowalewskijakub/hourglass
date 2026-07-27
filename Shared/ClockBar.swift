import SwiftUI
import HourglassCore

/// Shows whether you're clocked in and lets you clock in/out and take a
/// non-Pomodoro break. Shared by the macOS panel and the iOS timer screen.
///
/// The durations tick with the wall clock, so the view refreshes on a timeline
/// rather than waiting for observable state to change.
struct ClockBar: View {
    @Bindable var model: AppModel
    var compact: Bool = false

    private var workday: WorkdayTracker { model.workday }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Button(action: workday.toggleClock) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText(asOf: context.date))
                            .font(compact ? .caption : .callout)
                            .monospacedDigit()
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
        }
        .animation(.default, value: workday.isClockedIn)
        .animation(.default, value: workday.isOnBreak)
    }

    private var statusColor: Color {
        guard workday.isClockedIn else { return .secondary.opacity(0.5) }
        return workday.isOnBreak ? .orange : .green
    }

    /// On a break, the useful number is how long the break has run. Otherwise
    /// it's when you started, plus how long you've gone since the last one.
    private func statusText(asOf now: Date) -> String {
        guard let session = workday.currentSession else { return "Clocked out" }

        if session.isOnBreak {
            let elapsed = TimeFormatting.humanDuration(session.activeBreakDuration(asOf: now))
            return "On break · \(elapsed)"
        }

        let startedAt = session.clockedInAt.formatted(date: .omitted, time: .shortened)
        let sinceBreak = TimeFormatting.humanDuration(session.timeSinceLastBreak(asOf: now))
        return compact
            ? "\(startedAt) · \(sinceBreak)"
            : "Clocked in \(startedAt) · \(sinceBreak) since break"
    }
}
