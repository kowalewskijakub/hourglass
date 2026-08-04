import SwiftUI
import Charts
import HourglassCore

/// Stats: two jobs behind one native switch. **Overview** is the shape of the
/// work — today's total, the focus inside it, the span you chose, and each day
/// in it. **History** is the record itself, filterable, selectable, still fully
/// editable and exportable.
///
/// This surface follows the *system* appearance. Only the Orbit scene follows
/// the sky, so a sunset never flips the information UI underneath the user.
struct StatisticsView: View {
    var model: AppModel

    enum Section: String, CaseIterable, Hashable {
        case overview
        case history

        var title: LocalizedStringKey {
            switch self {
            case .overview: return "Overview"
            case .history: return "History"
            }
        }
    }

    /// The iOS tab bar drives the selection so overflow → History can land on
    /// the right segment; the macOS window has no such state and keeps its own.
    init(model: AppModel, section: Binding<Section>? = nil) {
        self.model = model
        self.externalSection = section
    }

    private let externalSection: Binding<Section>?
    @State private var localSection: Section = .overview
    @State private var isAdding = false
    @Environment(\.colorScheme) private var colorScheme

    private var section: Binding<Section> { externalSection ?? $localSection }
    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 14)

            switch section.wrappedValue {
            case .overview:
                OverviewView(model: model)
            case .history:
                LogView(model: model, isAdding: $isAdding)
            }
        }
        .orbitInformationSurface()
        // The toolbar is identical in both segments on purpose: it used to gain
        // items when History appeared, and the macOS window resized itself every
        // time the user switched. Export walks the whole log either way, and
        // History's own controls — filtering, selection, exporting a subset —
        // live inside the segment rather than up here.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { isAdding = true }
            }
            ToolbarItem(placement: .automatic) {
                LogExportButton(model: model)
            }
        }
    }
}

// MARK: - Overview

/// How many days Overview looks back over. One choice drives the whole segment —
/// the totals, the chart and the day shapes — because three surfaces answering
/// about three different spans is how a screen stops being read at all.
private enum StatsRange: String, CaseIterable, Identifiable {
    case week
    case fortnight
    case month

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .week: return 7
        case .fortnight: return 14
        case .month: return 30
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .week: return "7 days"
        case .fortnight: return "14 days"
        case .month: return "30 days"
        }
    }
}

/// Today's total, the focus inside it, and the span the user chose.
private struct OverviewView: View {
    var model: AppModel

    /// Remembered, because a range is a way of looking at the data rather than
    /// a question asked once — someone who works in fortnights should not have
    /// to re-choose one every time they open Stats.
    @AppStorage("hourglass.stats.range") private var rangeRaw = StatsRange.week.rawValue
    @State private var selectedDay: Date?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: OrbitPalette { .system(colorScheme) }
    private var range: StatsRange { StatsRange(rawValue: rangeRaw) ?? .week }
    private var calculator: StatisticsCalculator { StatisticsCalculator() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let stats = model.dailyWorkStats(lastDays: range.days, now: now)
            let summary = calculator.summary(of: stats)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline(now: now)
                    rangePicker
                    tiles(summary: summary)
                    workChart(stats: stats, summary: summary)
                    dayStripes(now: now)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A range the user changed should not leave a callout pinned to a
            // day that is no longer on the chart.
            .onChange(of: rangeRaw) { _, _ in selectedDay = nil }
        }
    }

    // MARK: Headline

    private func headline(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(TimeFormatting.compact(model.netWorkedToday(now: now)))
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(palette.ink)
                Text("worked today")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.inkSecondary)
                Spacer(minLength: 8)
                yesterdayDelta(now: now)
            }
            Text(focusSummary(now: now))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ember)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    /// Today against yesterday, and only when yesterday is worth comparing to:
    /// "12m more than yesterday" against a yesterday of four minutes is noise
    /// dressed up as a fact.
    @ViewBuilder
    private func yesterdayDelta(now: Date) -> some View {
        let yesterday = model.netWorkedYesterday(now: now)
        let today = model.netWorkedToday(now: now)
        let delta = today - yesterday

        if yesterday > 15 * 60, abs(delta) > 5 * 60 {
            let up = delta > 0
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 8, weight: .heavy))
                Text(TimeFormatting.compact(abs(delta)))
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(up ? palette.ember : palette.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((up ? palette.ember : palette.inkSecondary).opacity(0.12))
            )
            .accessibilityLabel(
                up ? Text("\(TimeFormatting.spoken(abs(delta))) more than yesterday")
                   : Text("\(TimeFormatting.spoken(abs(delta))) less than yesterday")
            )
        }
    }

    /// "3 focus sessions · 75 min · 5-day streak" — one ember line, no icons
    /// competing with the headline above it.
    private func focusSummary(now: Date) -> String {
        let count = model.completedToday(now: now)
        let minutes = model.focusMinutesToday(now: now)
        let streak = model.currentStreak(now: now)

        var parts = [
            count == 1 ? String(localized: "1 focus session")
                       : String(localized: "\(count) focus sessions"),
            String(localized: "\(minutes) min"),
        ]
        if streak > 0 { parts.append(String(localized: "\(streak)-day streak")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Range

    private var rangePicker: some View {
        Picker("Range", selection: $rangeRaw) {
            ForEach(StatsRange.allCases) { range in
                Text(range.title).tag(range.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("How far back Stats looks")
    }

    // MARK: Totals

    private func tiles(summary: StatisticsCalculator.RangeSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 124), spacing: 10)],
            spacing: 10
        ) {
            tile(
                "Worked",
                value: TimeFormatting.compact(summary.totalWorked),
                caption: summary.daysWorked == 1
                    ? String(localized: "over 1 day")
                    : String(localized: "over \(summary.daysWorked) days")
            )
            tile(
                "Daily average",
                value: TimeFormatting.compact(summary.averagePerWorkedDay),
                caption: String(localized: "on days worked")
            )
            tile(
                "Focus",
                value: summary.focusShare.formatted(.percent.precision(.fractionLength(0))),
                caption: String(localized: "of worked time"),
                tint: palette.ember
            )
            tile(
                "Best day",
                value: summary.best.map { TimeFormatting.compact($0.workedMinutes * 60) } ?? "—",
                caption: summary.best?.date.formatted(.dateTime.weekday(.abbreviated).day())
                    ?? String(localized: "nothing yet")
            )
        }
    }

    private func tile(
        _ title: LocalizedStringKey,
        value: String,
        caption: String,
        tint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.inkSecondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint ?? palette.ink)
            Text(caption)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.isNight ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Per-day chart

    private func workChart(
        stats: [StatisticsCalculator.DailyWorkStat],
        summary: StatisticsCalculator.RangeSummary
    ) -> some View {
        card("Worked per day", accessory: selectionCallout(stats: stats)) {
            Chart {
                ForEach(stats) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.focusedWorkMinutes),
                        width: .fixed(barWidth)
                    )
                    .foregroundStyle(palette.ember.opacity(dimmed(day) ? 0.35 : 1))
                    .cornerRadius(3)
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.otherMinutes),
                        width: .fixed(barWidth)
                    )
                    .foregroundStyle(palette.ember.opacity(dimmed(day) ? 0.10 : 0.23))
                    .cornerRadius(3)
                }
                if let day = resolvedSelection(in: stats) {
                    RuleMark(x: .value("Day", day.date, unit: .day))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(palette.inkSecondary.opacity(0.45))
                        .zIndex(-1)
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $selectedDay)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: axisStride)) { _ in
                    AxisValueLabel(format: axisFormat)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: hourTicks(in: stats)) { value in
                    AxisGridLine().foregroundStyle(palette.hairline)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(axisDuration(minutes))
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(palette.inkSecondary)
                }
            }
            .frame(height: 130)
            .overlay {
                if summary.isEmpty {
                    Text("Nothing recorded in this range")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
            .accessibilityLabel(Text("Worked minutes per day, with Pomodoro focus solid."))

            legend
        }
    }

    /// The bars a selection pushes into the background, so the chosen day reads
    /// as the subject rather than as one bar among thirty.
    private func dimmed(_ day: StatisticsCalculator.DailyWorkStat) -> Bool {
        guard let selected = selectedDay else { return false }
        return !Calendar.current.isDate(day.date, inSameDayAs: selected)
    }

    /// A scrub lands on an instant; the chart is built of days. Snapping to the
    /// nearest one is what keeps the callout from blinking out between bars.
    private func resolvedSelection(
        in stats: [StatisticsCalculator.DailyWorkStat]
    ) -> StatisticsCalculator.DailyWorkStat? {
        guard let selected = selectedDay else { return nil }
        return stats.min {
            abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
        }
    }

    /// The selected day's numbers, in the card's own header rather than in a
    /// floating annotation — a callout on a 30-bar chart covers the bars either
    /// side of the one being read.
    @ViewBuilder
    private func selectionCallout(stats: [StatisticsCalculator.DailyWorkStat]) -> some View {
        if let day = resolvedSelection(in: stats) {
            HStack(spacing: 6) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .foregroundStyle(palette.inkSecondary)
                Text(TimeFormatting.compact(day.workedMinutes * 60))
                    .foregroundStyle(palette.ink)
                    .monospacedDigit()
                if day.focusedWorkMinutes > 0 {
                    Text(TimeFormatting.compact(day.focusedWorkMinutes * 60))
                        .foregroundStyle(palette.ember)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .transition(.opacity)
        }
    }

    private var barWidth: CGFloat {
        switch range {
        case .week: return 18
        case .fortnight: return 10
        case .month: return 5
        }
    }

    private var axisStride: Int {
        switch range {
        case .week: return 1
        case .fortnight: return 2
        case .month: return 7
        }
    }

    private var axisFormat: Date.FormatStyle {
        range == .week ? .dateTime.weekday(.narrow) : .dateTime.day().month(.narrow)
    }

    /// Gridlines on whole hours. Letting the axis choose gave "4.2h" and
    /// "8.3h" — ticks derived from the tallest bar rather than from anything
    /// the reader counts in, which makes every other bar an estimate against a
    /// meaningless line.
    private func hourTicks(in stats: [StatisticsCalculator.DailyWorkStat]) -> [Double] {
        let peak = stats.map(\.workedMinutes).max() ?? 0
        let step: Double = peak <= 180 ? 60 : (peak <= 480 ? 120 : 180)
        let top = max(step, (peak / step).rounded(.up) * step)
        return stride(from: 0, through: top, by: step).map { $0 }
    }

    /// Minutes on the axis stop being readable as minutes somewhere around the
    /// second hour: "120" is arithmetic the reader has to do, "2h" is not.
    private func axisDuration(_ minutes: Double) -> String {
        guard minutes >= 60 else { return "\(Int(minutes))m" }
        return "\(Int((minutes / 60).rounded()))h"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(palette.ember, "Focus")
            swatch(palette.ember.opacity(0.23), "Other work")
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private func swatch(_ colour: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(palette.inkSecondary)
        }
    }

    // MARK: Day span

    private func dayStripes(now: Date) -> some View {
        card("Day span · first in to last out") {
            DayStripesView(
                spans: model.dailyClockSpans(lastDays: range.days, now: now),
                now: now,
                compact: range == .month
            )
        }
    }

    /// The same card Settings and History are built from — see `OrbitCard`. It
    /// used to be a private copy here, which is how the three screens drifted
    /// into three slightly different panels in the first place.
    private func card(
        _ title: LocalizedStringKey,
        accessory: some View = EmptyView(),
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        OrbitCard(title, accessory: accessory, content: content)
    }
}
