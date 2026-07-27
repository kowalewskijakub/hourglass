import SwiftUI
import Charts
import HourglassCore

/// Focus statistics — leads with time actually worked, then how much of it was
/// spent in Pomodoros, then the shape of the working day.
struct StatisticsView: View {
    var model: AppModel

    private var workStats: [StatisticsCalculator.DailyWorkStat] { model.dailyWorkStats() }
    private var clockSpans: [StatisticsCalculator.DailyClockSpan] { model.dailyClockSpans() }

    /// Both charts are pinned to this range. The day-shape chart only draws
    /// bars for days you actually clocked in, so without a fixed domain a
    /// single day would stretch across the whole plot and stop lining up with
    /// the week above it.
    private var dayDomain: ClosedRange<Date> {
        let days = workStats.map(\.date) + clockSpans.map(\.date)
        guard let first = days.min(), let last = days.max() else {
            return Date()...Date().addingTimeInterval(86_400)
        }
        return first...last.addingTimeInterval(86_400)
    }

    /// A normal 5:00–23:00 day, stretched only as far as the data needs — an
    /// early start, or a stretch that ran to midnight, would otherwise be
    /// drawn off the plot.
    private var hourDomain: ClosedRange<Double> {
        let starts = clockSpans.compactMap(\.startHour)
        let ends = clockSpans.compactMap(\.endHour)
        return min(5, starts.min() ?? 5)...max(23, ends.max() ?? 23)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                headline
                workChart
                dayShapeChart
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Headline — worked time, then focus underneath

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TimeFormatting.humanDuration(model.netWorkedToday()))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("worked today")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Label(focusSummary, systemImage: "brain.head.profile")
                    .foregroundStyle(.indigo)
                if model.currentStreak() > 0 {
                    Label("\(model.currentStreak()) day streak", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }

    /// "3 focus sessions (75 min)".
    private var focusSummary: String {
        let count = model.completedToday()
        let minutes = model.focusMinutesToday()
        let noun = count == 1 ? "focus session" : "focus sessions"
        return "\(count) \(noun) (\(minutes) min)"
    }

    // MARK: Worked time, with the Pomodoro share stacked inside each bar

    private var workChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worked this week")
                .font(.headline)
            Chart {
                ForEach(workStats) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.focusMinutes)
                    )
                    .foregroundStyle(by: .value("Kind", "Focus"))
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.otherMinutes)
                    )
                    .foregroundStyle(by: .value("Kind", "Other work"))
                }
            }
            .chartForegroundStyleScale([
                "Focus": Color.indigo,
                "Other work": Color.indigo.opacity(0.22),
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXScale(domain: dayDomain)
            .frame(height: 180)

            Text("Full bar is time worked; the solid part is Pomodoro focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: When the day started and ended

    private var dayShapeChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Day starts and ends")
                .font(.headline)
            Chart {
                ForEach(clockSpans) { span in
                    if let start = span.startHour, let end = span.endHour {
                        BarMark(
                            x: .value("Day", span.date, unit: .day),
                            yStart: .value("From", start),
                            yEnd: .value("To", end)
                        )
                        .foregroundStyle(Color.blue.gradient)
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 3) {
                            // A day carried over from the night before has a
                            // bar but no clock-in of its own to count.
                            if span.clockInCount > 0 {
                                Text("\(span.clockInCount)×")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [6, 9, 12, 15, 18, 21]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Double.self) {
                            Text("\(Int(hour)):00")
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYScale(domain: hourDomain)
            .chartXScale(domain: dayDomain)
            .frame(height: 180)

            Text("Bar spans first clock-in to last clock-out — or to now, while you're still on the clock; the number is how many times you clocked in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
