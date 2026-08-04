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
    /// Thirty rows at the seven-day rhythm is a scroll, not a shape. Compact
    /// tightens the rows so a month still reads as one block.
    var compact: Bool = false
    var calendar: Calendar = .current

    @Environment(\.colorScheme) private var colorScheme

    private var palette: OrbitPalette { .system(colorScheme) }

    private var rowSpacing: CGFloat { compact ? 3 : 8 }
    private var trackHeight: CGFloat { compact ? 5 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(spans) { span in
                HStack(spacing: 8) {
                    Text(weekdayInitial(span.date))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                        .opacity(compact && !startsWeek(span.date) ? 0.45 : 1)
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
                    .frame(height: trackHeight)
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

    /// The first day of the user's week, whichever day that is for them — the
    /// only marker a month of narrow initials has to break it into weeks.
    private func startsWeek(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == calendar.firstWeekday
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
