import SwiftUI
import HourglassCore

/// The single macOS surface, used both as the menu-bar popover content and as the
/// floating-window body so they look identical. The timer is laid out
/// horizontally (wider than tall) with one compact action row beneath it.
struct HourglassPanel: View {
    @Bindable var model: AppModel
    let controller: MacAppController

    var body: some View {
        VStack(spacing: 10) {
            TimerFaceView(
                engine: model.engine,
                sessionsUntilLongBreak: model.settings.sessionsUntilLongBreak,
                compact: true,
                horizontal: true
            )

            Divider()

            // One row: day info on the left, actions on the right.
            HStack(spacing: 12) {
                ClockBar(model: model, compact: true)

                Spacer(minLength: 8)

                Label("\(model.completedToday())", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("\(model.currentStreak())", systemImage: "flame")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                iconButton("chart.bar", "Statistics") { controller.openStats() }

                Menu {
                    Button("Log", systemImage: "list.bullet.rectangle") { controller.openLog() }
                    Button("Settings…", systemImage: "gearshape") { controller.openSettings() }
                    Divider()
                    Button("Quit Hourglass") { controller.quit() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    /// Sized to match the timer's prev/next arrows.
    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
