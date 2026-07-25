import SwiftUI
import HourglassCore

/// The iOS tab bar: Timer, Stats, Settings (the log lives inside Settings).
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            TimerScreen(model: model)
                .tabItem { Label("Timer", systemImage: "timer") }

            NavigationStack {
                StatisticsView(model: model)
                    .navigationTitle("Statistics")
            }
            .tabItem { Label("Stats", systemImage: "chart.bar.fill") }

            NavigationStack {
                SettingsFormView(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// The full-screen timer. The engine ticks drive per-second updates while in the
/// foreground; `refresh()` on `scenePhase == .active` reconciles anything that
/// elapsed while the app was suspended (the scheduled notification already
/// alerted the user).
struct TimerScreen: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ClockBar(model: model)
                .padding(.top, 8)
            Spacer(minLength: 0)
            TimerFaceView(
                engine: model.engine,
                sessionsUntilLongBreak: model.settings.sessionsUntilLongBreak
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.engine.kind.tint.opacity(0.06).ignoresSafeArea())
        .keepAwake(model.engine.isRunning)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.engine.refresh() }
        }
    }
}
