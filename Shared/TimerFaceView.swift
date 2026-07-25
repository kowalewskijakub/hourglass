import SwiftUI
import HourglassCore

/// The central timer face — ring, remaining time, cycle dots, and controls.
/// Shared by the macOS main window / popover and the iOS timer tab. `compact`
/// shrinks it for tighter contexts. Navigation is bidirectional: the ◀ / ▶
/// arrows scrub freely backward/forward through the Pomodoro cycle.
struct TimerFaceView: View {
    @Bindable var engine: PomodoroEngine
    var sessionsUntilLongBreak: Int
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 14 : 24) {
            Label(engine.kind.displayName, systemImage: engine.kind.symbolName)
                .font(compact ? .headline : .title3.weight(.semibold))
                .foregroundStyle(engine.kind.tint)
                .labelStyle(.titleAndIcon)

            ZStack {
                TimerRingView(
                    progress: engine.progress,
                    tint: engine.kind.tint,
                    lineWidth: compact ? 10 : 16
                )
                Text(engine.formattedRemaining)
                    .font(.system(size: compact ? 46 : 76, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: compact ? 168 : 264, height: compact ? 168 : 264)

            CycleDots(
                completedInCycle: engine.focusesCompletedInCycle,
                total: sessionsUntilLongBreak,
                tint: engine.kind.tint
            )

            controls

            if !compact {
                resetButton
            }
        }
        .padding(compact ? 14 : 28)
        .animation(.default, value: engine.kind)
    }

    private var controls: some View {
        HStack(spacing: 20) {
            arrow("chevron.backward", help: "Previous phase") { engine.goToPreviousPhase() }

            Button {
                engine.toggle()
            } label: {
                Label(engine.isRunning ? "Pause" : "Start",
                      systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.kind.tint)

            arrow("chevron.forward", help: "Next phase") { engine.goToNextPhase() }
        }
    }

    private func arrow(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button {
            engine.reset()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(engine.progress > 0 || engine.phase != .idle ? 1 : 0.35)
    }
}
