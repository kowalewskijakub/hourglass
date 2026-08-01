import SwiftUI
import HourglassCore

/// Cross-platform settings form. macOS hosts it in the `Settings` scene; iOS
/// hosts it in a `NavigationStack` tab.
struct SettingsFormView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // The log is no longer reachable from here: History is a segment of
            // Stats, alongside the numbers it explains.
            Section("Durations") {
                minuteStepper("Focus", keyPath: \.focusDuration, range: 1...90)
                minuteStepper("Short break", keyPath: \.shortBreakDuration, range: 1...30)
                minuteStepper("Long break", keyPath: \.longBreakDuration, range: 1...60)
                Stepper(
                    "Long break every \(model.settings.sessionsUntilLongBreak) focus sessions",
                    value: $model.settings.sessionsUntilLongBreak,
                    in: 2...12
                )
            }

            Section("Automation") {
                Toggle("Auto-start breaks", isOn: $model.settings.autoStartBreaks)
                Toggle("Auto-start next focus", isOn: $model.settings.autoStartFocus)
            }

            Section("Alerts") {
                Toggle("Play sound when a session ends", isOn: $model.settings.soundEnabled)
                Toggle("Show a notification", isOn: $model.settings.notificationsEnabled)
            }

            Section {
                Toggle("Remind me to clock in", isOn: $model.settings.clockInReminderEnabled)
                if model.settings.clockInReminderEnabled {
                    DatePicker("Remind at", selection: reminderTime, displayedComponents: .hourAndMinute)
                }
                #if os(macOS)
                Toggle("Nudge me when I'm active but clocked out", isOn: $model.settings.activityNudgeEnabled)
                #endif

                Picker("Sky", selection: $model.settings.skyMode) {
                    Text("Follow the sun").tag(SkyMode.followSun)
                    Text("Always night").tag(SkyMode.alwaysNight)
                    Text("Always day").tag(SkyMode.alwaysDay)
                }
            } header: {
                Text("Workday")
            } footer: {
                // Said plainly, because the obvious reading of a "sky" setting
                // is that it changes the whole app's appearance. It does not.
                Text("Sky changes the Orbit scene only. Stats, History and Settings follow your system appearance. Following the sun uses your approximate location; if it isn't available, Hourglass uses a 6:00–18:00 day.\n\nEarth imagery: NASA Visible Earth — Blue Marble and Black Marble.")
            }

            if let sync = model.sync {
                SyncSettingsSection(sync: sync)
            }

            #if os(macOS)
            Section("Window") {
                Picker("Show Hourglass as", selection: $model.settings.macAppMode) {
                    Text("Menu-bar app").tag(MacAppMode.menuBar)
                    Text("Floating window").tag(MacAppMode.window)
                }
            }
            #endif
        }
        .formStyle(.grouped)
        // The same page surface as Stats and History, so the three
        // information screens plainly come from one app.
        .orbitInformationSurface()
    }

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

    private func minuteStepper(
        _ title: String,
        keyPath: WritableKeyPath<TimerSettings, TimeInterval>,
        range: ClosedRange<Int>
    ) -> some View {
        let minutes = Binding<Int>(
            get: { Int((model.settings[keyPath: keyPath] / 60).rounded()) },
            set: { model.settings[keyPath: keyPath] = TimeInterval($0 * 60) }
        )
        return Stepper("\(title): \(minutes.wrappedValue) min", value: minutes, in: range)
    }
}
