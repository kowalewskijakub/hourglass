import SwiftUI
import HourglassCore

/// The iOS tab bar: Orbit, Stats (Overview / History) and Settings.
///
/// The Orbit tab is full bleed and follows the sky; everything else is a normal
/// system surface following the system appearance.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .orbit
    @State private var statsSection: StatisticsView.Section = .overview

    enum Tab: Hashable { case orbit, stats, settings }

    var body: some View {
        TabView(selection: $tab) {
            OrbitFaceView(
                model: model,
                openHistory: {
                    statsSection = .history
                    tab = .stats
                },
                openSettings: { tab = .settings }
            )
            .keepAwake(model.engine.isRunning)
            .toolbarBackground(.visible, for: .tabBar)
            .tabItem { Label("Orbit", systemImage: OrbitIcon.focus.symbolName) }
            .tag(Tab.orbit)

            NavigationStack {
                StatisticsView(model: model, section: $statsSection)
                    .navigationTitle("Stats")
            }
            .tabItem { Label("Stats", systemImage: OrbitIcon.stats.symbolName) }
            .tag(Tab.stats)

            NavigationStack {
                SettingsFormView(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: OrbitIcon.settings.symbolName) }
            .tag(Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Reconcile anything that elapsed while suspended: the engine
            // against the wall clock, the linked break against the stores, and
            // the server against both.
            model.engine.refresh()
            model.refreshLinkedBreak()
            Task { await model.sync?.refresh() }
        }
    }
}
