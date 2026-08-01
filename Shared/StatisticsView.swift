import SwiftUI
import Charts
import HourglassCore

/// Stats: two jobs behind one native switch. **Overview** is the shape of the
/// work — today's total, the focus inside it, the week, and the span of each
/// day. **History** is the record itself, still fully editable and exportable.
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
        // time the user switched. Export walks the whole log either way.
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

/// Today's total, the focus inside it, the week, and the shape of each day.
private struct OverviewView: View {
    var model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headline(now: now)
                    weekChart(now: now)
                    dayStripes(now: now)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            }
            Text(focusSummary(now: now))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ember)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
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

    // MARK: This week

    private func weekChart(now: Date) -> some View {
        let stats = model.dailyWorkStats(now: now)
        return card("This week") {
            Chart {
                ForEach(stats) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.focusMinutes),
                        width: .fixed(18)
                    )
                    .foregroundStyle(palette.ember)
                    .cornerRadius(3)
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.otherMinutes),
                        width: .fixed(18)
                    )
                    .foregroundStyle(palette.ember.opacity(0.23))
                    .cornerRadius(3)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.system(size: 9))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(palette.hairline)
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
            .frame(height: 118)
            .accessibilityLabel(Text("Worked minutes per day this week, with Pomodoro focus solid."))

            legend
        }
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
            DayStripesView(spans: model.dailyClockSpans(now: now), now: now)
        }
    }

    private func card(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(palette.inkSecondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.isNight ? Color.white.opacity(0.04) : Color.black.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 1)
                )
        )
    }
}
