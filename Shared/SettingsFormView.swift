import SwiftUI
import HourglassCore

/// Cross-platform settings, built from the same cards Stats and History are made
/// of rather than from a stock grouped `Form`.
///
/// The three information screens are reached from the same footer within a click
/// of each other, and the Mac's grouped form was plainly a different app from
/// the cards next door — inset rounded panels in system grey, system label
/// sizes, its own idea of spacing. Same surface, same cards, same micro-caps
/// titles here; the controls themselves stay stock, because a hand-drawn stepper
/// is a worse stepper.
struct SettingsFormView: View {
    @Bindable var model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    private var palette: OrbitPalette { .system(colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                durations
                automation
                alerts
                workday
                if let sync = model.sync {
                    OrbitCard("Sync") { SyncSettingsSection(sync: sync) }
                }
                #if os(macOS)
                window
                #endif
                credits
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .orbitInformationSurface()
    }

    // MARK: Cards

    private var durations: some View {
        OrbitCard("Durations") {
            VStack(spacing: 12) {
                minuteRow("Focus", keyPath: \.focusDuration, range: 1...90)
                OrbitRowDivider()
                minuteRow("Focus break (short)", keyPath: \.shortBreakDuration, range: 1...30)
                OrbitRowDivider()
                minuteRow("Focus break (long)", keyPath: \.longBreakDuration, range: 1...60)
                OrbitRowDivider()
                OrbitFieldRow(
                    "Long focus break every",
                    detail: "\(model.settings.sessionsUntilLongBreak) focus sessions"
                ) {
                    Stepper(
                        "Focus sessions before a long break",
                        value: $model.settings.sessionsUntilLongBreak,
                        in: 2...12
                    )
                }
            }
        }
    }

    private var automation: some View {
        OrbitCard("Automation") {
            VStack(spacing: 12) {
                OrbitFieldRow("Auto-start breaks") {
                    Toggle("Auto-start breaks", isOn: $model.settings.autoStartBreaks)
                }
                OrbitRowDivider()
                OrbitFieldRow("Auto-start next focus") {
                    Toggle("Auto-start next focus", isOn: $model.settings.autoStartFocus)
                }
            }
        }
    }

    private var alerts: some View {
        OrbitCard("Alerts") {
            VStack(spacing: 12) {
                OrbitFieldRow("Play a sound when a session ends") {
                    Toggle("Play a sound when a session ends", isOn: $model.settings.soundEnabled)
                }
                OrbitRowDivider()
                OrbitFieldRow("Show a notification") {
                    Toggle("Show a notification", isOn: $model.settings.notificationsEnabled)
                }
            }
        }
    }

    private var workday: some View {
        OrbitCard(
            "Workday",
            footnote: "Sky changes the Orbit scene only. Stats, History and Settings follow your system appearance. Following the sun uses your approximate location; if it isn't available, Hourglass uses a 6:00–18:00 day."
        ) {
            VStack(spacing: 12) {
                OrbitFieldRow("Remind me to clock in") {
                    Toggle("Remind me to clock in", isOn: $model.settings.clockInReminderEnabled)
                }
                if model.settings.clockInReminderEnabled {
                    OrbitRowDivider()
                    OrbitFieldRow("Remind at") {
                        DatePicker("Remind at", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                }
                #if os(macOS)
                OrbitRowDivider()
                OrbitFieldRow(
                    "Nudge me when I'm active but clocked out",
                    detail: "Only while you're using the Mac"
                ) {
                    Toggle("Nudge me when I'm active but clocked out",
                           isOn: $model.settings.activityNudgeEnabled)
                }
                #endif
                OrbitRowDivider()
                OrbitFieldRow("Sky") {
                    Picker("Sky", selection: $model.settings.skyMode) {
                        Text("Follow the sun").tag(SkyMode.followSun)
                        Text("Always night").tag(SkyMode.alwaysNight)
                        Text("Always day").tag(SkyMode.alwaysDay)
                    }
                    .fixedSize()
                }
            }
        }
    }

    #if os(macOS)
    private var window: some View {
        OrbitCard("Window") {
            OrbitFieldRow("Show Hourglass as") {
                Picker("Show Hourglass as", selection: $model.settings.macAppMode) {
                    Text("Menu-bar app").tag(MacAppMode.menuBar)
                    Text("Floating window").tag(MacAppMode.window)
                }
                .fixedSize()
            }
        }
    }
    #endif

    /// The attribution the imagery is used under. It was buried in the middle of
    /// the sky footnote, where it read as part of a setting.
    private var credits: some View {
        Text("Earth imagery: NASA Visible Earth — Blue Marble and Black Marble.")
            .font(.system(size: 10))
            .foregroundStyle(palette.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: Pieces

    /// Bridges the stored hour/minute to a `DatePicker`.
    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = model.settings.clockInReminderHour
                comps.minute = model.settings.clockInReminderMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                model.settings.clockInReminderHour = comps.hour ?? 9
                model.settings.clockInReminderMinute = comps.minute ?? 0
            }
        )
    }

    private func minuteRow(
        _ title: LocalizedStringKey,
        keyPath: WritableKeyPath<TimerSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> some View {
        let minutes = Binding<Int>(
            get: { Int((model.settings[keyPath: keyPath] / 60).rounded()) },
            set: { model.settings[keyPath: keyPath] = TimeInterval($0 * 60) }
        )
        return OrbitFieldRow(title, detail: "\(minutes.wrappedValue) min") {
            Stepper(title, value: minutes, in: range)
        }
    }
}
