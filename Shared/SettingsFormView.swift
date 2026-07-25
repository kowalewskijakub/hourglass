import SwiftUI
import HourglassCore

/// Cross-platform settings form. macOS hosts it in the `Settings` scene; iOS
/// hosts it in a `NavigationStack` tab.
struct SettingsFormView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            #if os(iOS)
            Section {
                NavigationLink {
                    LogView(model: model)
                } label: {
                    Label("Session Log", systemImage: "list.bullet.rectangle")
                }
            }
            #endif

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
            } header: {
                Text("Workday")
            } footer: {
                #if os(macOS)
                Text("The nudge checks only how long ago you last used the Mac — no keystrokes or clicks are recorded.")
                #else
                Text("A daily reminder to start tracking your day.")
                #endif
            }

            #if os(macOS)
            Section {
                Picker("Show Hourglass as", selection: $model.settings.macAppMode) {
                    Text("Menu-bar app").tag(MacAppMode.menuBar)
                    Text("Floating window").tag(MacAppMode.window)
                }
            } header: {
                Text("Window")
            } footer: {
                Text("All windows stay dock-less and always on top.")
            }
            #endif
        }
        .formStyle(.grouped)
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
