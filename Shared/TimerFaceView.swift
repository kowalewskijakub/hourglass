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
    /// Lay the timer out side-by-side (ring left, controls right) so the whole
    /// component is wider than it is tall — used by the macOS panel.
    var horizontal: Bool = false

    var body: some View {
        if horizontal {
            horizontalBody
        } else {
            verticalBody
        }
    }

    // MARK: Landscape (macOS panel)

    private var horizontalBody: some View {
        HStack(spacing: 16) {
            ZStack {
                TimerRingView(progress: engine.progress, tint: engine.kind.tint, lineWidth: 7)
                VStack(spacing: 1) {
                    Text(engine.formattedRemaining)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(engine.kind.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(engine.kind.tint)
                }
            }
            .frame(width: 108, height: 108)

            VStack(alignment: .leading, spacing: 10) {
                controls

                CycleDots(
                    completedInCycle: engine.focusesCompletedInCycle,
                    total: sessionsUntilLongBreak,
                    tint: engine.kind.tint
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .animation(.default, value: engine.kind)
    }

    // MARK: Portrait (iOS)

    private var verticalBody: some View {
        VStack(spacing: compact ? 10 : 14) {
            ZStack {
                TimerRingView(
                    progress: engine.progress,
                    tint: engine.kind.tint,
                    lineWidth: compact ? 8 : 12
                )
                VStack(spacing: 2) {
                    Text(engine.formattedRemaining)
                        .font(.system(size: compact ? 34 : 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Label(engine.kind.displayName, systemImage: engine.kind.symbolName)
                        .font(compact ? .caption2 : .footnote.weight(.medium))
                        .foregroundStyle(engine.kind.tint)
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(width: compact ? 132 : 190, height: compact ? 132 : 190)

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
        .padding(compact ? 10 : 18)
        .animation(.default, value: engine.kind)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            arrow("chevron.backward", help: "Previous phase") { engine.goToPreviousPhase() }

            Button {
                engine.toggle()
            } label: {
                Label(engine.isRunning ? "Pause" : "Start",
                      systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                    .font(.callout)
                    .frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(engine.kind.tint)

            arrow("chevron.forward", help: "Next phase") { engine.goToNextPhase() }
        }
    }

    private func arrow(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
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
