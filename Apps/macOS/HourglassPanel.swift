import SwiftUI
import HourglassCore

/// The single macOS surface, used both as the menu-bar popover content and as the
/// floating-window body so they look identical. Minimalist icon-only actions in
/// one row, with Quit tucked behind a ••• menu.
struct HourglassPanel: View {
    @Bindable var model: AppModel
    let controller: MacAppController

    var body: some View {
        VStack(spacing: 12) {
            TimerFaceView(
                engine: model.engine,
                sessionsUntilLongBreak: model.settings.sessionsUntilLongBreak,
                compact: true
            )

            HStack {
                Label("\(model.completedToday())", systemImage: "checkmark.circle")
                Spacer()
                Label("\(model.currentStreak())", systemImage: "flame")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)

            Divider()

            HStack(spacing: 16) {
                iconButton("chart.bar", "Statistics") { controller.openStats() }
                iconButton("list.bullet.rectangle", "Log") { controller.openLog() }
                iconButton("gearshape", "Settings") { controller.openSettings() }
                Spacer()
                Menu {
                    Button("Quit Hourglass") { controller.quit() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 264)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
