import SwiftUI
import Charts
import HourglassCore

/// Focus statistics — leads with today's headline, then a week chart, then a
/// short "all time" footer. Deliberately sparse: one thing to look at first.
struct StatisticsView: View {
    var model: AppModel

    private var days: [DailyStat] { model.dailyStats(lastDays: 7) }
    private var focusMinutes: Int { model.focusMinutesToday() }
    private var streak: Int { model.currentStreak() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                weekChart
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Headline — the single number that matters today

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(encouragement)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(focusMinutes)")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("min focused today")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                inlineStat("\(model.completedToday())", "sessions", "checkmark.circle.fill", .green)
                if streak > 0 {
                    inlineStat("\(streak)", streak == 1 ? "day streak" : "day streak", "flame.fill", .orange)
                }
                if model.netWorkedToday() > 0 {
                    inlineStat(TimeFormatting.humanDuration(model.netWorkedToday()), "worked", "briefcase.fill", .blue)
                }
            }
            .padding(.top, 4)
        }
    }

    /// A nudge that reflects how the day is actually going.
    private var encouragement: String {
        switch (focusMinutes, streak) {
        case (0, _): return "A fresh start — one session is all it takes."
        case (1...25, _): return "You're underway. Keep the momentum."
        case (26...60, _): return "Solid focus today."
        case (_, let s) where s >= 3: return "Strong day, and a streak to match."
        default: return "Excellent focus today."
        }
    }

    private func inlineStat(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Week

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This week")
                .font(.headline)
            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Focus (min)", day.focusMinutes)
                )
                .foregroundStyle(Color.indigo.gradient)
                .cornerRadius(5)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
    }

    // MARK: All time

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "trophy.fill").foregroundStyle(.teal)
            Text("\(model.totalCompleted()) sessions all time")
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
