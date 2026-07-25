import SwiftUI
import Charts
import HourglassCore

/// Focus statistics — summary tiles plus a 7-day focus-minutes bar chart.
/// Shared by the macOS Statistics window and the iOS Stats tab.
struct StatisticsView: View {
    var model: AppModel

    private var days: [DailyStat] { model.dailyStats(lastDays: 7) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryTiles

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last 7 days")
                        .font(.headline)
                    chart
                        .frame(height: 220)
                }
            }
            .padding()
        }
    }

    private var summaryTiles: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(title: "Focus today",
                     value: "\(model.focusMinutesToday()) min",
                     systemImage: "clock.fill", tint: .indigo)
            StatTile(title: "Sessions today",
                     value: "\(model.completedToday())",
                     systemImage: "checkmark.circle.fill", tint: .green)
            StatTile(title: "Streak",
                     value: "\(model.currentStreak()) day\(model.currentStreak() == 1 ? "" : "s")",
                     systemImage: "flame.fill", tint: .orange)
            StatTile(title: "All-time",
                     value: "\(model.totalCompleted())",
                     systemImage: "trophy.fill", tint: .teal)
            StatTile(title: "Worked today",
                     value: TimeFormatting.humanDuration(model.netWorkedToday()),
                     systemImage: "briefcase.fill", tint: .blue)
            StatTile(title: "Clock-ins",
                     value: "\(model.clockInsToday())",
                     systemImage: "clock.badge.checkmark", tint: .purple)
            StatTile(title: "Break time",
                     value: TimeFormatting.humanDuration(model.breakTimeToday()),
                     systemImage: "cup.and.saucer.fill", tint: .brown)
        }
    }

    private var chart: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Focus (min)", day.focusMinutes)
            )
            .foregroundStyle(Color.indigo.gradient)
            .cornerRadius(5)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
    }
}

/// A single summary metric card.
private struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 16), tint: tint.opacity(0.22))
    }
}
