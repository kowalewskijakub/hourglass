import SwiftUI
import HourglassCore

/// One 0–24h track per day, filled from the first clock-in to the last clock-out.
///
/// The shape of the week at a glance — when days started and how long they ran —
/// not a per-break breakdown. Individual rests belong in History, where they can
/// be read exactly and edited.
struct DayStripesView: View {
    let spans: [StatisticsCalculator.DailyClockSpan]
    let now: Date
    var calendar: Calendar = .current

    @Environment(\.colorScheme) private var colorScheme

    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(spans) { span in
                HStack(spacing: 8) {
                    Text(weekdayInitial(span.date))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                        .accessibilityHidden(true)

                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(palette.ink.opacity(0.09))

                            if let start = span.startHour, let end = span.endHour, end > start {
                                let isToday = calendar.isDateInToday(span.date)
                                Capsule()
                                    .fill(palette.ember.opacity(isToday ? 1 : 0.55))
                                    .frame(width: max(2, width * (end - start) / 24))
                                    .offset(x: width * start / 24)

                                if isToday {
                                    Circle()
                                        .fill(palette.dawn)
                                        .frame(width: 5, height: 5)
                                        .offset(x: width * nowHour / 24 - 2.5)
                                }
                            }
                        }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label(for: span)))
            }
        }
    }

    private var nowHour: Double {
        let startOfDay = calendar.startOfDay(for: now)
        return now.timeIntervalSince(startOfDay) / 3600
    }

    private func weekdayInitial(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.narrow))
    }

    private func label(for span: StatisticsCalculator.DailyClockSpan) -> String {
        let day = span.date.formatted(.dateTime.weekday(.wide))
        guard let start = span.start, let end = span.end else {
            return "\(day): no time on the clock"
        }
        let from = TimeFormatting.timeOfDay(start)
        let to = TimeFormatting.timeOfDay(end)
        return "\(day): \(from) to \(to)"
    }
}
